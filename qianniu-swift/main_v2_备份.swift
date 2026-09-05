import Cocoa
import Darwin
import ApplicationServices

// =========================================================================
//  千牛新消息提醒 - 原生 Swift/AppKit 版 V2（优化版）
//
//  监控千牛消息库 im.sqlite-wal 的写入（消息到达的真实信号），右上角弹出
//  浅色卡片弹窗；点击弹窗 → 直接打开千牛【主聊天窗口】（而不是只激活应用、
//  被自带悬浮提醒抢占）；按住拖动可移动并记住位置；多条自动堆叠。
//
//  V2 相对 V1 的改进:
//   1. 点击弹窗 = 发送 reopen 事件（等同点 Dock 图标，千牛会恢复主窗口），
//      再尝试用辅助功能把主窗口 AXRaise 顶到最前（未授权时静默降级为激活应用）
//   2. 修复: 记住位置后多条弹窗全部叠在同一点的 bug（现在从记住的位置向上堆叠）
//   3. 修复: 换显示器后记住的位置可能在屏幕外（现在钳制到当前可见区域）
//   4. 修复: 开机自启 plist 残留旧内容时自动重写（换机/迁移后不会启动失效路径）
//   5. 菜单栏新增"打开千牛窗口"，点击弹窗的行为与之一致
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

    // 智能打开：激活 + reopen(等同点Dock图标，恢复主窗口) + AXRaise 主窗口
    static func open() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                log("点击 → 启动千牛(未运行)")
            }
            return
        }
        // 1) 激活应用
        app.activate(options: [.activateIgnoringOtherApps])
        // 2) reopen 事件：与点击 Dock 图标等效，促使千牛恢复主窗口
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", bundle]
        try? p.run()
        log("点击 → activate + reopen")
        // 3) 稍后确保在前台，并尝试把主窗口顶到最前（AX 未授权时静默跳过）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundle {
                app.activate(options: [.activateIgnoringOtherApps])
            }
            _ = raiseMainWindow(pid: app.processIdentifier)
        }
    }

    // 用辅助功能把千牛主窗口顶到本应用所有窗口最前。
    // 未授予辅助功能权限时返回 false（静默，不影响主流程）。
    @discardableResult
    static func raiseMainWindow(pid: pid_t) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        // 优先: 应用声明的主窗口
        var mainRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXMainWindowAttribute as CFString, &mainRef) == .success,
           let w = mainRef {
            let res = AXUIElementPerformAction(w as! AXUIElement, kAXRaiseAction as CFString)
            if res == .success { log("点击 → AXRaise 主窗口成功"); return true }
        }
        // 兜底: 面积最大的窗口（聊天主窗口通常最大）
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let windows = winsRef as? [AXUIElement], !windows.isEmpty else {
            log("AXRaise 不可用（如需更强切窗效果，可在 系统设置→隐私与安全性→辅助功能 中添加本应用）")
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
            log("点击 → AXRaise 最大窗口成功")
            return true
        }
        return false
    }
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
    var dragging = false
    var moved = false

    init(frame: NSRect, popup: Popup) {
        self.popup = popup
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func build() {
        let b = bounds
        // 浅色圆角卡片（千牛原生通知是白底浅色卡）
        let card = NSView(frame: b)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.96).cgColor
        card.layer?.cornerRadius = 14
        addSubview(card)

        // 左侧：千牛图标（圆角白底蓝标，贴合千牛）
        let icon = popup?.qianniuIcon
        let iv = NSImageView(frame: NSRect(x: 16, y: 22, width: 40, height: 40))
        iv.image = icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 10
        iv.layer?.masksToBounds = true
        addSubview(iv)

        // 标题（深色加粗）
        let title = NSTextField(labelWithString: popup?.title ?? "")
        title.frame = NSRect(x: 68, y: 45, width: b.width - 104, height: 26)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = NSColor(white: 0.08, alpha: 1)
        addSubview(title)

        // 正文（深灰）
        let body = NSTextField(labelWithString: popup?.body ?? "")
        body.frame = NSRect(x: 68, y: 15, width: b.width - 104, height: 24)
        body.font = .systemFont(ofSize: 13)
        body.textColor = NSColor(white: 0.38, alpha: 1)
        body.lineBreakMode = .byTruncatingTail
        addSubview(body)

        // 右侧箭头 ›（提示可点击）
        let chevron = NSTextField(labelWithString: "›")
        chevron.frame = NSRect(x: b.width - 24, y: (b.height - 20) / 2 - 2, width: 14, height: 22)
        chevron.font = .systemFont(ofSize: 19, weight: .semibold)
        chevron.textColor = NSColor(red: 0.0, green: 0.45, blue: 0.85, alpha: 0.9)
        addSubview(chevron)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        log("弹窗收到点击(mouseDown)")
        dragging = true; moved = false
        pressStart = event.locationInWindow
        popup?.onPress()
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, let win = window else { return }
        let loc = event.locationInWindow
        let dx = loc.x - pressStart.x
        let dy = loc.y - pressStart.y
        if abs(dx) > Popup.dragThreshold || abs(dy) > Popup.dragThreshold { moved = true }
        if moved {
            var f = win.frame
            f.origin.x += dx
            f.origin.y += dy
            win.setFrameOrigin(f.origin)
        }
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        if moved { popup?.releaseAfterDrag() } else { popup?.qianniuOpenAndFade() }
    }
}

final class Popup {
    static let width: CGFloat = 340
    static let height: CGFloat = 82
    static let marginTop: CGFloat = 12
    static let marginRight: CGFloat = 12
    static let gap: CGFloat = 10
    static let maxStack = 4              // 堆叠上限，超出后从头再叠（防溢出屏幕）
    static let autoFade: TimeInterval = 6.0
    static let releaseFade: TimeInterval = 3.0
    static let fadeDuration: TimeInterval = 0.35
    static let dragThreshold: CGFloat = 4.0
    static var active = [Popup]()

    let title: String
    let body: String
    var panel: NSPanel!
    var fadeTimer: Timer?
    var cleanupTimer: Timer?
    var didOpen = false
    let qianniuIcon: NSImage?

    init(title: String, body: String) {
        self.title = title
        self.body = body
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

    // 基准位置: 用户拖动记住的位置；否则默认右上角。
    // V2修复: 1) 记住的位置也要向上堆叠（原来全部叠在同一点）
    //         2) 位置钳制到当前屏幕可见区域（换显示器后不会跑出屏幕）
    static func frameFor(next: Int) -> NSRect {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var base = NSPoint(x: vf.maxX - width - marginRight,
                           y: vf.maxY - height - marginTop)
        if let s = UserDefaults.standard.object(forKey: "popupPos") as? [String: Double],
           let x = s["x"], let y = s["y"] {
            base = NSPoint(x: x, y: y)
        }
        // 钳制到可见区域
        base.x = min(max(base.x, vf.minX + 8), vf.maxX - width - 8)
        base.y = min(max(base.y, vf.minY + 8), vf.maxY - height - 8)
        // 从基准位置向上堆叠，超过上限后循环
        let stack = CGFloat(next % maxStack) * (height + gap)
        let y = base.y - stack <= vf.minY + 8 ? base.y : base.y - stack
        return NSRect(x: base.x, y: y, width: width, height: height)
    }

    func show() {
        guard panel != nil else { return }
        panel.alphaValue = 0
        // 不强制激活、不强制 key（避免误触发点击/抢焦点）。窗口悬浮显示，
        // 首次真正点击时由 acceptsFirstMouse 直接送达给内容视图。
        panel.orderFrontRegardless()
        Popup.active.append(self)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
        scheduleFade(after: Popup.autoFade)
        log("弹窗已显示：点击切千牛主窗口，按住可拖动")
    }

    func scheduleFade(after delay: TimeInterval) {
        cancelFade()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.startFade()
        }
    }
    func cancelFade() {
        fadeTimer?.invalidate(); fadeTimer = nil
    }

    func onPress() {
        // 按住：取消淡出，弹窗不消失（用于拖动）
        cancelFade()
    }

    func releaseAfterDrag() {
        savePosition()
        scheduleFade(after: Popup.releaseFade)
        log("拖动结束 → 保存位置，3 秒后淡出")
    }

    func qianniuOpenAndFade() {
        guard !didOpen else { return }
        didOpen = true
        savePosition()
        AppDelegate.openQianniu()
        startFade()
    }

    func savePosition() {
        let o = panel.frame.origin
        UserDefaults.standard.set(["x": Double(o.x), "y": Double(o.y)], forKey: "popupPos")
    }

    func startFade() {
        guard panel != nil else { return }
        cancelFade()
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
        savePosition()
        panel.orderOut(nil)
        panel = nil
    }
}

// ---------- 主逻辑 ----------
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appBundle = "com.taobao.Aliworkbench"
    let appName = "Aliworkbench"
    let settle: TimeInterval = 0.6
    let cooldown: TimeInterval = 15

    var monitor: Timer?
    var lastStates: [String: (Double, UInt64)] = [:]
    var pendingSince: Date?
    var lastWrite: Date?
    var lastNotify: Date = .distantPast
    var burstAccounts = Set<String>()
    var lastTrigger = ""
    var paused = false
    var statusItem: NSStatusItem?
    var soundOn = UserDefaults.standard.bool(forKey: "soundOn")
    var soundName = UserDefaults.standard.string(forKey: "soundName") ?? "Glass"
    let soundList = ["Glass", "Ping", "Purr", "Pop", "Submarine", "Funk", "Sosumi", "Tink", "Basso", "Blow", "Bottle", "Frog", "Hero", "Morse"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("---------- 千牛提醒 V2 启动 ----------")
        // 实测触发文件已有内容时不重复弹；只有内容变化才触发
        lastTrigger = (try? String(contentsOfFile: NSHomeDirectory() + "/.qn_test", encoding: .utf8)) ?? ""
        setupStatusItem()
        registerAutoStartIfNeeded()
        startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("应用退出")
    }

    // ---- 菜单栏 ----
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        rebuildMenu()
    }

    func updateStatusIcon() {
        guard let b = statusItem?.button else { return }
        // 用系统 SF 符号（黑白模板图，能随菜单栏亮/暗自适应），与其它菜单栏图标一致
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
        let auto = NSMenuItem(title: autoStartEnabled ? "关闭开机自启" : "开启开机自启",
                              action: #selector(toggleAutoStart), keyEquivalent: "")
        auto.target = self
        m.addItem(auto)
        m.addItem(.separator())
        // 通知声音开关
        let soundToggle = NSMenuItem(title: "播放提醒声音", action: #selector(toggleSound), keyEquivalent: "")
        soundToggle.target = self
        soundToggle.state = soundOn ? .on : .off
        m.addItem(soundToggle)
        // 选择系统铃声
        let soundSel = NSMenuItem(title: "提醒铃声：\(soundName)", action: nil, keyEquivalent: "")
        let sMenu = NSMenu()
        for s in soundList {
            let it = NSMenuItem(title: s, action: #selector(selectSound(_:)), keyEquivalent: "")
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

    // ---- 通知声音 ----
    @objc func toggleSound() {
        soundOn.toggle()
        UserDefaults.standard.set(soundOn, forKey: "soundOn")
        log("提醒声音：\(soundOn ? "开" : "关") (\(soundName))")
        if soundOn {
            playNotificationSound()   // 开启时立即播一声让用户听
        }
        rebuildMenu()
    }

    @objc func selectSound(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String {
            soundName = s
            UserDefaults.standard.set(s, forKey: "soundName")
            log("铃声已切换为：\(s)")
            if soundOn {
                playNotificationSound()
            }
            rebuildMenu()
        }
    }

    func playNotificationSound() {
        guard soundOn else { return }
        if let s = NSSound(named: soundName) {
            s.play()
        }
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
        // V2: plist 存在但内容指向别的路径/旧程序时（迁移、旧版残留）自动重写
        if autoStartEnabled {
            if let content = try? String(contentsOfFile: autoStartPlist, encoding: .utf8),
               content.contains(Bundle.main.bundleURL.path) {
                return   // 已是本应用，无需处理
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
        lastStates = snapshot()
        log("监控 \(lastStates.count) 个账号: \(Array(lastStates.keys).map { accountLabel(path: $0) })")
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        monitor = t
    }

    func cancelMonitoring() {
        monitor?.invalidate()
        monitor = nil
    }

    func walPaths() -> [String] {
        let base = NSHomeDirectory() + "/Library/Application Support/Aliworkbench/IMServiceDir/MessageSDK/libaim"
        let fm = FileManager.default
        guard let accs = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        return accs.compactMap { acc in
            let db = base + "/" + acc + "/database/im.sqlite-wal"
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

    func accountLabel(path: String) -> String {
        let db = (path as NSString).deletingLastPathComponent
        let accDir = (db as NSString).deletingLastPathComponent
        let name = (accDir as NSString).lastPathComponent
        let account = name.components(separatedBy: "@")[0]
        return "尾号" + String(account.suffix(3))
    }

    func tick() {
        checkTestTrigger()
        let cur = snapshot()
        var changed = Set<String>()
        for (p, v) in cur {
            if let prev = lastStates[p], prev != v { changed.insert(accountLabel(path: p)) }
        }
        let now = Date()
        if !changed.isEmpty {
            lastWrite = now
            if pendingSince == nil { pendingSince = now }
            burstAccounts.formUnion(changed)
        } else if let ps = pendingSince, let lw = lastWrite,
                  now.timeIntervalSince(lw) >= settle {
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
        lastStates = cur
    }

    func qianniuFrontmost() -> Bool {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == appBundle
    }

    func checkTestTrigger() {
        // 手动测试：向 ~/.qn_test 写入新内容(如 echo hi > ~/.qn_test)即可弹一条测试窗
        let trig = NSHomeDirectory() + "/.qn_test"
        guard let tc = try? String(contentsOfFile: trig, encoding: .utf8), !tc.isEmpty else { return }
        if tc != lastTrigger {
            lastTrigger = tc
            log("手动触发测试弹窗")
            showPopup(accounts: ["测试"])
        }
    }

    func showPopup(accounts: [String]) {
        let body = accounts.joined(separator: "、") + " 有客户来消息，点击打开千牛"
        let popup = Popup(title: "千牛新消息", body: body)
        popup.show()
        playNotificationSound()
        log("千牛在后台 → 弹窗")
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
