import Cocoa
import Darwin
import ApplicationServices

// =========================================================================
//  千牛新消息提醒 - 原生 Swift/AppKit 版 V3（点击可靠性 + 事件驱动监控）
//
//  V3 相对 V2 的改进:
//   1. 修复"点击有几率不弹千牛"主因之一: 单击时鼠标轻微抖动超过 4px 被误判为
//      拖动 → 不打开千牛且弹窗淡出。现在以"窗口实际位移 < 10px"判定为点击,
//      即使中途瞬间超过阈值, 松手仍按"点击"处理
//   2. 点击切千牛改为"确认-重试"机制: 最多 6 轮校验前台状态, 未到前台则交替
//      使用 activate / reopen 重试, 直到确认成功; 每轮结果写日志, 可排查
//   3. 首次启动检测辅助功能权限: 未授权时弹一次提示(一键跳转系统设置)。
//      授权后 AXRaise 可把千牛主聊天窗口精确顶到最前, 点击必达
//   4. 消息监控从 0.3 秒轮询改为 FSEvents 事件驱动(文件一写入立即感知,
//      近乎零 CPU); FSEvents 创建失败时自动回退到旧的轮询模式
//   5. activate 适配 macOS 14+: 先激活自身获得上下文, 再用新 API 激活千牛
// =========================================================================

func log(_ msg: String) {
    let p = NSHomeDirectory() + "/Library/Logs/qianniu_notify.log"
    if !FileManager.default.fileExists(atPath: p) {
        FileManager.default.createFile(atPath: p, contents: nil)
    }
    guard let f = FileHandle(forWritingAtPath: p) else { return }
    defer { try? f.close() }
    f.seekToEndOfFile()
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(df.string(from: Date()))] \(msg)\n"
    try? f.write(contentsOf: line.data(using: .utf8)!)
}

// ---------- 打开千牛 ----------
enum QianniuOpener {
    static let bundle = "com.taobao.Aliworkbench"

    // 入口: 千牛在跑则走确认-重试流程; 未运行则启动后再接管
    static func open() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            log("点击 → 切换流程开始")
            beginSwitch(app, pass: 1)
        } else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
                log("未找到千牛(com.taobao.Aliworkbench)")
                return
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            log("点击 → 启动千牛(未运行)")
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
                if let app = app {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        beginSwitch(app, pass: 1)
                    }
                } else {
                    log("启动千牛失败: \(err?.localizedDescription ?? "?")")
                }
            }
        }
    }

    // 核心: 每轮先校验千牛是否已在前台; 没有则按轮次交替激活/reopen, 最多 6 轮
    static func beginSwitch(_ app: NSRunningApplication, pass: Int) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
            log("切换成功(第\(pass)轮确认)")
            raiseMainWindow(pid: app.processIdentifier)
            return
        }
        switch pass {
        case 1:
            activate(app)
            reopen()                    // reopen = 点 Dock 图标, 促使恢复主窗口
        case 2:
            activate(app)
        case 3:
            reopen()
            activate(app)
        default:
            activate(app)
        }
        if pass >= 6 {
            log("重试 6 轮仍未确认前台, 停止(AX 未授权时无窗可顶)")
            raiseMainWindow(pid: app.processIdentifier)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            beginSwitch(app, pass: pass + 1)
        }
    }

    // macOS 14+ 对后台应用激活有限制: 先激活自己获得"激活上下文", 再激活千牛
    static func activate(_ app: NSRunningApplication) {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            _ = app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // 发 reopen 事件(等同点 Dock 图标)
    static func reopen() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", bundle]
        do { try p.run() } catch { log("open -b 失败: \(error.localizedDescription)") }
    }

    // 辅助功能可用时, 把千牛主窗口精确顶到最前(确定性最强的一步)
    @discardableResult
    static func raiseMainWindow(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else {
            log("AXRaise 跳过(未授权辅助功能; 系统设置→隐私与安全性→辅助功能 中勾选本应用可提升点击可靠性)")
            return false
        }
        let appEl = AXUIElementCreateApplication(pid)
        var mainRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXMainWindowAttribute as CFString, &mainRef) == .success,
           let w = mainRef {
            let res = AXUIElementPerformAction(w as! AXUIElement, kAXRaiseAction as CFString)
            if res == .success { log("AXRaise 主窗口成功"); return true }
        }
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let windows = winsRef as? [AXUIElement], !windows.isEmpty else {
            log("AXRaise 未取得窗口列表")
            return false
        }
        var best: AXUIElement?
        var bestArea = CGFloat(0)
        for w in windows {
            var sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let size = sizeRef as? CGSize {
                let area = size.width * size.height
                if area > bestArea { bestArea = area; best = w }
            }
        }
        if let b = best, AXUIElementPerformAction(b, kAXRaiseAction as CFString) == .success {
            log("AXRaise 最大窗口成功")
            return true
        }
        return false
    }
}

// ---------- FSEvents 事件驱动监控 ----------
final class FSWatcher {
    private var stream: FSEventStreamRef?
    // 事件回调(主线程): 传入发生变化的文件路径列表
    var onEvents: ([String]) -> Void = { _ in }

    func start(paths: [String]) -> Bool {
        stop()
        guard !paths.isEmpty else { return false }
        var watched = paths
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passRetained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info = info else { return }
            let me = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            // 安全转换: C 字符串数组逐个取值(不能桥接为 NSArray, 会段错误)
            let p = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var arr: [String] = []
            for i in 0..<count {
                if let s = p[i] { arr.append(String(cString: s)) }
            }
            me.onEvents(arr)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx,
                                          watched as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.15, flags) else {
            log("FSEvents 创建失败, 回退轮询模式")
            return false
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            log("FSEvents 启动失败, 回退轮询模式")
            return false
        }
        stream = s
        log("FSEvents 监控已启动: \(paths.joined(separator: ", "))")
        return true
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
    }
    deinit { stop() }
}

// ---------- 弹窗 ----------
final class PopupWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    required init?(coder: NSCoder) { fatalError() }
}

final class PopupView: NSView {
    weak var popup: Popup?
    var pressStart = NSPoint.zero
    var startOrigin = NSPoint.zero
    var dragging = false

    init(frame: NSRect, popup: Popup) {
        self.popup = popup
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func build() {
        let b = bounds
        let card = NSView(frame: b)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.96).cgColor
        card.layer?.cornerRadius = 14
        addSubview(card)

        let icon = popup?.qianniuIcon
        let iv = NSImageView(frame: NSRect(x: 16, y: 22, width: 40, height: 40))
        iv.image = icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 10
        iv.layer?.masksToBounds = true
        addSubview(iv)

        let title = NSTextField(labelWithString: popup?.title ?? "")
        title.frame = NSRect(x: 68, y: 45, width: b.width - 104, height: 26)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = NSColor(white: 0.08, alpha: 1)
        addSubview(title)

        let body = NSTextField(labelWithString: popup?.body ?? "")
        body.frame = NSRect(x: 68, y: 15, width: b.width - 104, height: 24)
        body.font = .systemFont(ofSize: 13)
        body.textColor = NSColor(white: 0.38, alpha: 1)
        body.lineBreakMode = .byTruncatingTail
        addSubview(body)

        let chevron = NSTextField(labelWithString: "›")
        chevron.frame = NSRect(x: b.width - 24, y: (b.height - 20) / 2 - 2, width: 14, height: 22)
        chevron.font = .systemFont(ofSize: 19, weight: .semibold)
        chevron.textColor = NSColor(red: 0.0, green: 0.45, blue: 0.85, alpha: 0.9)
        addSubview(chevron)

        // 右上角未读红点徽章（显示未读消息数）
        if let n = popup?.count, n > 0 {
            let text = n > 99 ? "99+" : "\(n)"
            let bw = CGFloat(20 + 7 * (text.count - 1))
            let badge = NSTextField(labelWithString: text)
            badge.frame = NSRect(x: b.width - bw - 10, y: b.height - 28, width: bw, height: 20)
            badge.alignment = .center
            badge.font = .systemFont(ofSize: 12, weight: .bold)
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1).cgColor
            badge.layer?.cornerRadius = 10
            badge.layer?.masksToBounds = true
            addSubview(badge)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        log("弹窗收到点击(mouseDown)")
        dragging = true
        pressStart = event.locationInWindow
        if let o = window?.frame.origin { startOrigin = o }
        popup?.onPress()
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, let win = window else { return }
        let loc = event.locationInWindow
        let dx = loc.x - pressStart.x
        let dy = loc.y - pressStart.y
        // 只有窗口真实位移超过 12px 才算拖动(轻微抖动不算)
        let disp = hypot(win.frame.origin.x - startOrigin.x, win.frame.origin.y - startOrigin.y)
        if disp > 12 {
            var f = win.frame
            f.origin.x += dx
            f.origin.y += dy
            win.setFrameOrigin(f.origin)
        }
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        guard let win = window else { return }
        // 以"窗口实际位移"判定: <10px 一律视为点击 → 打开千牛(修复误判吃点击)
        let disp = hypot(win.frame.origin.x - startOrigin.x, win.frame.origin.y - startOrigin.y)
        if disp < 10 {
            popup?.qianniuOpenAndFade()
        } else {
            popup?.releaseAfterDrag()
        }
    }
}

final class Popup {
    static let width: CGFloat = 340
    static let height: CGFloat = 82
    static let marginTop: CGFloat = 12
    static let marginRight: CGFloat = 12
    static let gap: CGFloat = 10
    static let maxStack = 4
    static let fadeDuration: TimeInterval = 0.35
    static var active = [Popup]()
    // 当前常驻弹窗（不点击不消失；新消息更新红点计数）
    static var current: Popup?

    var title: String
    var body: String
    var count: Int = 0
    var accounts: [String] = []
    var panel: NSPanel!
    var cleanupTimer: Timer?
    var didOpen = false
    let qianniuIcon: NSImage?

    init(title: String, body: String, count: Int, accounts: [String] = []) {
        self.title = title
        self.body = body
        self.count = count
        self.accounts = accounts
        var ic: NSImage? = nil
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.taobao.Aliworkbench") {
            ic = NSWorkspace.shared.icon(forFile: url.path)
        }
        self.qianniuIcon = ic

        let rect = Popup.frameFor(next: Popup.active.count)
        let win = PopupWindow(contentRect: rect)
        self.panel = win
        let pv = PopupView(frame: NSRect(origin: .zero, size: rect.size), popup: self)
        win.contentView = pv
    }

    static func frameFor(next: Int) -> NSRect {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var base = NSPoint(x: vf.maxX - width - marginRight,
                           y: vf.maxY - height - marginTop)
        if let s = UserDefaults.standard.object(forKey: "popupPos") as? [String: Double],
           let x = s["x"], let y = s["y"] {
            base = NSPoint(x: x, y: y)
        }
        base.x = min(max(base.x, vf.minX + 8), vf.maxX - width - 8)
        base.y = min(max(base.y, vf.minY + 8), vf.maxY - height - 8)
        let stack = CGFloat(next % maxStack) * (height + gap)
        let y = base.y - stack <= vf.minY + 8 ? base.y : base.y - stack
        return NSRect(x: base.x, y: y, width: width, height: height)
    }

    func show() {
        guard panel != nil else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        Popup.active.append(self)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
        // V4: 不再自动淡出，弹窗常驻，直到点击
        log("弹窗已显示(常驻)：点击切千牛主窗口，按住可拖动")
    }

    // 新消息到达且弹窗已在屏: 更新未读计数与文案, 不新建弹窗
    func updateContent(accounts: [String], count: Int) {
        self.accounts = Array(Set(self.accounts + accounts)).sorted()
        self.count = count
        self.body = self.accounts.joined(separator: "、") + " 有客户来消息，点击打开千牛"
        guard panel != nil else { return }
        let size = panel.frame.size
        let pv = PopupView(frame: NSRect(origin: .zero, size: size), popup: self)
        panel.contentView = pv
        panel.orderFrontRegardless()
    }

    func onPress() {
    }

    func releaseAfterDrag() {
        savePosition()
        log("拖动结束 → 保存位置(弹窗保留)")
    }

    func qianniuOpenAndFade() {
        guard !didOpen else { return }
        didOpen = true
        savePosition()
        delegate.unreadCount = 0          // 点击即清零未读
        AppDelegate.openQianniu()
        startFade()
    }

    func savePosition() {
        let o = panel.frame.origin
        UserDefaults.standard.set(["x": Double(o.x), "y": Double(o.y)], forKey: "popupPos")
    }

    func startFade() {
        guard panel != nil else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Popup.fadeDuration
            panel.animator().alphaValue = 0
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: Popup.fadeDuration + 0.1, repeats: false) { [weak self] _ in
            self?.cleanup()
        }
    }

    func cleanup() {
        Popup.active.removeAll { $0 === self }
        Popup.current = nil
        savePosition()
        panel.orderOut(nil)
        panel = nil
    }
}

// ---------- 主逻辑 ----------
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appBundle = "com.taobao.Aliworkbench"
    let settle: TimeInterval = 0.6
    let cooldown: TimeInterval = 15

    var monitor: Timer?
    var watcher = FSWatcher()
    var watcherActive = false
    var fallbackStates: [String: (Double, UInt64)] = [:]
    var pendingSince: Date?
    var lastWrite: Date?
    var lastNotify: Date = .distantPast
    var burstAccounts = Set<String>()
    var paused = false
    var unreadCount = 0                 // 未读消息数（弹窗红点显示，点击清零）
    var statusItem: NSStatusItem?
    var soundOn = UserDefaults.standard.bool(forKey: "soundOn")
    var soundName = UserDefaults.standard.string(forKey: "soundName") ?? "dingdong"
    let soundList = ["dingdong", "Glass", "Ping", "Purr", "Pop", "Submarine", "Funk", "Sosumi", "Tink", "Basso", "Blow", "Bottle", "Frog", "Hero", "Morse"]

    var libaimBase: String {
        NSHomeDirectory() + "/Library/Application Support/Aliworkbench/IMServiceDir/MessageSDK/libaim"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("---------- 千牛提醒 V3 启动 ----------")
        // 记录已有测试触发内容, 避免启动即弹测试窗
        lastTriggerContent = (try? String(contentsOfFile: NSHomeDirectory() + "/.qn_test", encoding: .utf8)) ?? ""
        lastWriteFallbackInit()
        setupStatusItem()
        registerAutoStartIfNeeded()
        promptAccessibilityIfNeeded()
        startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        log("应用退出")
    }

    // ---- 辅助功能授权提示(一次性) ----
    func promptAccessibilityIfNeeded() {
        if AXIsProcessTrusted() {
            log("辅助功能已授权, AXRaise 可用")
            return
        }
        guard !UserDefaults.standard.bool(forKey: "axPromptDone") else { return }
        UserDefaults.standard.set(true, forKey: "axPromptDone")
        let a = NSAlert()
        a.messageText = "提升“点击弹窗直达千牛”的成功率"
        a.informativeText = "未授权辅助功能时，点击弹窗只能尽力激活千牛，个别情况需要点第二次。\n\n一次性授权（约 30 秒）：\n1. 点“打开系统设置”\n2. 在 隐私与安全性 → 辅助功能 中勾选“千牛提醒”\n3. 重启本应用即可"
        a.addButton(withTitle: "打开系统设置")
        a.addButton(withTitle: "暂不")
        if a.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // ---- 菜单栏 ----
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        rebuildMenu()
    }

    func updateStatusIcon() {
        guard let b = statusItem?.button else { return }
        let name = paused ? "bell.slash.fill" : "bell.fill"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "千牛提醒") {
            img.isTemplate = true
            b.image = img
        } else {
            b.title = "千牛"
        }
    }

    func rebuildMenu() {
        guard let statusItem else { return }
        let m = NSMenu()
        let header = NSMenuItem(title: "千牛提醒（\(paused ? "已暂停" : "监控中")）", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())
        let open = NSMenuItem(title: "打开千牛窗口", action: #selector(openQianniuMenu), keyEquivalent: "")
        open.target = self
        m.addItem(open)
        let toggle = NSMenuItem(title: paused ? "开始提醒" : "暂停提醒",
                                action: #selector(togglePause), keyEquivalent: "")
        toggle.target = self
        m.addItem(toggle)
        let test = NSMenuItem(title: "立即测试弹窗", action: #selector(doTest), keyEquivalent: "")
        test.target = self
        m.addItem(test)
        let ax = NSMenuItem(title: AXIsProcessTrusted() ? "辅助功能：已授权" : "辅助功能授权（提升点击可靠性）",
                            action: #selector(openAXSettings), keyEquivalent: "")
        ax.target = self
        ax.isEnabled = !AXIsProcessTrusted()
        m.addItem(ax)
        let auto = NSMenuItem(title: autoStartEnabled ? "关闭开机自启" : "开启开机自启",
                              action: #selector(toggleAutoStart), keyEquivalent: "")
        auto.target = self
        m.addItem(auto)
        m.addItem(.separator())
        let soundToggle = NSMenuItem(title: "播放提醒声音", action: #selector(toggleSound), keyEquivalent: "")
        soundToggle.target = self
        soundToggle.state = soundOn ? .on : .off
        m.addItem(soundToggle)
        let soundSel = NSMenuItem(title: "提醒铃声：\(soundName == "dingdong" ? "千牛叮咚" : soundName)", action: nil, keyEquivalent: "")
        let sMenu = NSMenu()
        for s in soundList {
            let it = NSMenuItem(title: s == "dingdong" ? "千牛叮咚（默认）" : s, action: #selector(selectSound(_:)), keyEquivalent: "")
            it.target = self
            it.state = (s == soundName) ? .on : .off
            it.representedObject = s
            sMenu.addItem(it)
        }
        soundSel.submenu = sMenu
        m.addItem(soundSel)
        m.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        m.addItem(quit)
        statusItem.menu = m
    }

    @objc func openQianniuMenu() {
        log("菜单 → 打开千牛窗口")
        AppDelegate.openQianniu()
    }

    @objc func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // ---- 通知声音 ----
    @objc func toggleSound() {
        soundOn.toggle()
        UserDefaults.standard.set(soundOn, forKey: "soundOn")
        log("提醒声音：\(soundOn ? "开" : "关") (\(soundName))")
        if soundOn { playNotificationSound() }
        rebuildMenu()
    }

    @objc func selectSound(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String {
            soundName = s
            UserDefaults.standard.set(s, forKey: "soundName")
            log("铃声已切换为：\(s)")
            if soundOn { playNotificationSound() }
            rebuildMenu()
        }
    }

    func playNotificationSound() {
        guard soundOn else { return }
        // "dingdong" 为千牛内置来消息铃声, 已复制进本 App Resources
        if let s = NSSound(named: soundName) { s.play(); return }
        NSSound(named: "Glass")?.play()
    }

    @objc func togglePause() {
        paused.toggle()
        if paused {
            log("已暂停提醒")
            for p in Popup.active { p.startFade() }
            cancelMonitoring()
        } else {
            log("已开始提醒")
            startMonitoring()
        }
        updateStatusIcon()
        rebuildMenu()
    }

    @objc func doTest() {
        log("菜单触发测试弹窗")
        showPopup(accounts: ["测试"])
    }

    // ---- 开机自启 ----
    let autoStartLabel = "com.user.qianniu-notify"
    var autoStartPlist: String {
        return NSHomeDirectory() + "/Library/LaunchAgents/" + autoStartLabel + ".plist"
    }

    var autoStartEnabled: Bool {
        return FileManager.default.fileExists(atPath: autoStartPlist)
    }

    @objc func toggleAutoStart() {
        if autoStartEnabled {
            uninstallAutoStart()
            log("开机自启：已关闭")
        } else {
            installAutoStart()
            log("开机自启：已开启")
        }
        rebuildMenu()
    }

    func registerAutoStartIfNeeded() {
        if autoStartEnabled {
            if let content = try? String(contentsOfFile: autoStartPlist, encoding: .utf8),
               content.contains(Bundle.main.bundleURL.path) {
                return
            }
            log("检测到旧的开机自启配置，更新为本应用路径")
            uninstallAutoStart()
        }
        installAutoStart()
        log("已注册开机自启")
    }

    func installAutoStart() {
        let appPath = Bundle.main.bundleURL.path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(autoStartLabel)</string>
        <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>\(appPath)</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><false/>
        </dict></plist>
        """
        do {
            try plist.data(using: .utf8)?.write(to: URL(fileURLWithPath: autoStartPlist), options: .atomic)
            _ = runLaunchctl(["bootstrap", "gui/\(getuid())", autoStartPlist])
        } catch {
            log("写入自启 plist 失败: \(error)")
        }
    }

    func uninstallAutoStart() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(autoStartLabel)"])
        try? FileManager.default.removeItem(atPath: autoStartPlist)
    }

    @discardableResult
    func runLaunchctl(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // ---- 监控 ----
    func startMonitoring() {
        cancelMonitoring()
        burstAccounts.removeAll()
        pendingSince = nil
        // 关键: 绑定事件回调(缺失会导致回调触发但事件被丢弃)
        watcher.onEvents = { [weak self] paths in self?.handleEvents(paths) }
        watcherActive = watcher.start(paths: [libaimBase])
        if !watcherActive { lastWriteFallbackInit() }
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        monitor = t
    }

    func cancelMonitoring() {
        watcher.stop()
        monitor?.invalidate()
        monitor = nil
    }

    // FSEvents 不可用时的轮询兜底: 初始化快照
    func lastWriteFallbackInit() {
        fallbackStates = snapshot()
        log("轮询兜底快照 \(fallbackStates.count) 个账号")
    }

    func walPaths() -> [String] {
        let fm = FileManager.default
        guard let accs = try? fm.contentsOfDirectory(atPath: libaimBase) else { return [] }
        return accs.compactMap { acc in
            let db = libaimBase + "/" + acc + "/database/im.sqlite-wal"
            return fm.fileExists(atPath: db) ? db : nil
        }
    }

    func snapshot() -> [String: (Double, UInt64)] {
        var out: [String: (Double, UInt64)] = [:]
        let fm = FileManager.default
        for p in walPaths() {
            guard let st = try? fm.attributesOfItem(atPath: p) else { continue }
            let mtime = (st[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (st[.size] as? NSNumber)?.uint64Value ?? 0
            out[p] = (mtime, size)
        }
        return out
    }

    // 从事件路径提取账号目录名(xxx@cntaobao)
    func accountFromPath(_ path: String) -> String? {
        guard let r = path.range(of: "/libaim/") else { return nil }
        return path[r.upperBound...].components(separatedBy: "/").first
    }

    func accountLabel(path: String) -> String {
        let db = (path as NSString).deletingLastPathComponent
        let accDir = (db as NSString).deletingLastPathComponent
        let name = (accDir as NSString).lastPathComponent
        let account = name.components(separatedBy: "@")[0]
        return "尾号" + String(account.suffix(4))
    }

    func label(forAccount acc: String) -> String {
        let account = acc.components(separatedBy: "@")[0]
        return "尾号" + String(account.suffix(4))
    }

    // FSEvents 回调(主线程)
    func handleEvents(_ paths: [String]) {
        var labels = Set<String>()
        for p in paths {
            if let acc = accountFromPath(p) { labels.insert(label(forAccount: acc)) }
        }
        guard !labels.isEmpty else { return }
        let now = Date()
        lastWrite = now
        if pendingSince == nil { pendingSince = now }
        burstAccounts.formUnion(labels)
    }

    func tick() {
        checkTestTrigger()
        // 轮询兜底模式: 主动比对快照
        if !watcherActive {
            let cur = snapshot()
            var changed = Set<String>()
            for (p, v) in cur {
                if let prev = fallbackStates[p], prev != v { changed.insert(accountLabel(path: p)) }
            }
            if !changed.isEmpty { handleEvents(Array(changed)) }  // 复用事件入口(路径仅作日志)
            fallbackStates = cur
        }
        // 消息写入停止 settle 秒后决策(必须有未决突发, 否则会用空列表无限重复决策)
        guard pendingSince != nil, let lw = lastWrite else { return }
        let now = Date()
        guard now.timeIntervalSince(lw) >= settle else { return }
        let accounts = burstAccounts.sorted()
        if qianniuFrontmost() {
            log("写入结束(\(accounts)) 千牛在前台→静默")
        } else if now.timeIntervalSince(lastNotify) < cooldown {
            log("写入结束(\(accounts)) 冷却期→跳过")
        } else {
            showPopup(accounts: accounts)
            lastNotify = now
        }
        pendingSince = nil
        burstAccounts.removeAll()
    }

    func qianniuFrontmost() -> Bool {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == appBundle
    }

    func checkTestTrigger() {
        let trig = NSHomeDirectory() + "/.qn_test"
        guard let tc = try? String(contentsOfFile: trig, encoding: .utf8), !tc.isEmpty else { return }
        if tc != lastTriggerContent {
            lastTriggerContent = tc
            log("手动触发测试弹窗")
            showPopup(accounts: ["测试"])
        }
    }
    var lastTriggerContent = ""

    func showPopup(accounts: [String]) {
        unreadCount += accounts.count
        let body = accounts.joined(separator: "、") + " 有客户来消息，点击打开千牛"
        if let p = Popup.current, p.panel != nil {
            p.updateContent(accounts: accounts, count: unreadCount)
            log("弹窗已在屏 → 更新未读数 \(unreadCount)")
        } else {
            let popup = Popup(title: "千牛新消息", body: body, count: unreadCount, accounts: accounts)
            Popup.current = popup
            popup.show()
        }
        playNotificationSound()
        log("千牛在后台 → 弹窗(未读 \(unreadCount))")
    }

    static func openQianniu() {
        QianniuOpener.open()
    }
}

// 启动
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
