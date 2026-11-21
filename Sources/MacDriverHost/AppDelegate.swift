import AppKit
import ApplicationServices
import DriverCore
import DriverProtocol

/// Host lifecycle: starting → ready ⇄ user_control → stopping → stopped, or failed(reason).
enum HostState: Equatable {
    case starting, ready, userControl, stopping, stopped, failed(String)

    var label: String {
        switch self {
        case .starting: return "Starting…"
        case .ready: return "Ready — scripts in control"
        case .userControl: return "You have control (scripts paused)"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped"
        case .failed(let r): return "Failed: \(r)"
        }
    }
}

// Main-actor isolated: the compiler checks that every callback from another thread hops to the
// main actor before touching state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let display = VirtualDisplayManager()
    lazy var driver = Driver(display: display, journalURL: URL(fileURLWithPath: DriverProtocol.defaultSocketPath).deletingLastPathComponent().appendingPathComponent("requests.journal"))
    lazy var server = SocketServer(driver: driver)
    lazy var forwarder = UserInputForwarder(driver: driver)
    let barrier = PointerBarrier()
    var mirror: MirrorWindowController?
    var statusItem: NSStatusItem!
    var signalSources: [DispatchSourceSignal] = []
    private(set) var state: HostState = .starting { didSet { refreshUI() } }
    var lastActivity = "—"

    // MARK: Startup

    func applicationDidFinishLaunching(_ n: Notification) {
        setupStatusItem()
        installSignalHandlers()
        start()
    }

    private func start() {
        state = .starting
        // One host per user: a second instance must not create a second virtual display.
        if SocketServer.canConnect(server.path) {
            state = .failed("another MacDriver host is already running (it owns \(server.path)); quit it first")
            NSLog("[MacDriver] Another MacDriver host is already running; this instance did not create a display or socket")
            return
        }
        let perms = checkPermissions()

        do {
            try display.start()
        } catch {
            state = .failed("virtual display: \(error)")
            return
        }
        display.onGuardEvent = { msg in NSLog("[MacDriver] %@", msg) }
        if let vid = display.displayID { barrier.setBlockedRegion(CGDisplayBounds(vid)) }
        display.onStateChange = { [weak self] s in
            Task { @MainActor in
                if case .ready(let id) = s { self?.barrier.setBlockedRegion(CGDisplayBounds(id)) }
                if case .failed(let r) = s { self?.state = .failed(r) }
            }
        }
        // Keep the barrier region in sync with the display's position after any reconfiguration.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // Delivered on the main queue (queue: .main above).
            MainActor.assumeIsolated {
                guard let self, let vid = self.display.displayID else { return }
                self.barrier.setBlockedRegion(CGDisplayBounds(vid))
                self.mirror?.displayChanged()
            }
        }
        if !barrier.start() {
            NSLog("[MacDriver] Pointer barrier unavailable until Accessibility permission is granted")
        }
        let barrier = self.barrier
        driver.hostStatus.withLock { $0 = { [barrier] in ["pointer": barrier.report()] } }
        driver.hostCapabilities.withLock {
            $0.append {
                Capability(name: "pointer_barrier", available: barrier.isActive,
                           purpose: "Keeps the user's real pointer off the virtual monitor (event tap)",
                           withoutIt: "The pointer can wander onto the virtual monitor; grant Accessibility to MacDriver and relaunch")
            }
        }
        for c in Capabilities.all() where !c.available {
            NSLog("[MacDriver] Unavailable on this system: %@. %@", c.name, c.withoutIt)
        }

        do {
            if ProcessInfo.processInfo.arguments.contains("--test-ops") {
                server.testControl = { [weak self] take in
                    Task { @MainActor in if take { self?.takeControl() } else { self?.giveBack() } }
                }
                // Drives the same forwarder the mirror view uses, as if the user acted in it.
                let f = forwarder, driver = self.driver
                server.testUserInput = { o in
                    let p = CGPoint(x: o["x"]?.doubleValue ?? 0, y: o["y"]?.doubleValue ?? 0)
                    let wid = o["window"]?.stringValue.flatMap { try? WindowService.parseWindowId($0) }
                    @Sendable func list(_ items: [UserWindowItem]) -> JSONValue {
                        .array(items.map { ["window": .string(WindowService.idString($0.windowID)), "label": .string($0.label)] })
                    }
                    switch o["kind"]?.stringValue {
                    case "click":
                        let n = o["count"]?.intValue ?? 1
                        for i in 1...max(1, n) { f.mouseDown(p, button: .left, clickCount: i, flags: []); f.mouseUp(p, clickCount: i, flags: []) }
                    case "scroll": f.scroll(p, dx: 0, dy: Int32(o["dy"]?.intValue ?? -3), flags: [])
                    case "drag":
                        let q = CGPoint(x: o["x2"]?.doubleValue ?? p.x, y: o["y2"]?.doubleValue ?? p.y)
                        f.mouseDown(p, button: .left, clickCount: 1, flags: [])
                        for i in 1...8 { let t = CGFloat(i) / 8; f.mouseDragged(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t), flags: []) }
                        f.mouseUp(q, clickCount: 1, flags: [])
                    case "key":
                        guard let code = o["code"]?.intValue else { return ["error": "key needs code"] }
                        let flags = CGEventFlags(rawValue: UInt64(o["flags"]?.intValue ?? 0))
                        f.key(CGKeyCode(code), down: true, flags: flags); f.key(CGKeyCode(code), down: false, flags: flags)
                    // The host-UI actions behind "Windows ▾" / the menu-bar menu.
                    case "list":
                        return await MainActor.run { ["physical": list(driver.windowsOnPhysicalDisplays()), "virtual": list(driver.windowsOnVirtualMonitor())] }
                    case "move_here", "send_back":
                        guard let wid else { return ["error": "needs window"] }
                        let move = o["kind"]?.stringValue == "move_here"
                        return await MainActor.run {
                            do { if move { try driver.userMoveToVirtual(wid) } else { try driver.userSendBack(wid) }; return ["done": true] }
                            catch { return ["error": .string(String(describing: error))] }
                        }
                    case "open_app", "open_file":
                        guard let path = o["path"]?.stringValue else { return ["error": "needs path"] }
                        let url = URL(fileURLWithPath: path)
                        let msg = o["kind"]?.stringValue == "open_app" ? await driver.userOpen(appURL: url) : await driver.userOpen(fileURL: url)
                        return ["message": .string(msg)]
                    default: return ["error": "unknown kind"]
                    }
                    return ["done": true]
                }
            }
            server.onActivity = { [weak self] s in Task { @MainActor in self?.lastActivity = s; self?.refreshUI() } }
            try server.start()
        } catch {
            state = .failed("socket: \(error)")
            return
        }

        driver.arbiter.observe { [weak self] owner in
            Task { @MainActor in
                guard let self, self.state == .ready || self.state == .userControl else { return }
                self.state = owner == .user ? .userControl : .ready
                self.mirror?.ownerChanged(owner)
            }
        }
        state = .ready
        if !perms.isEmpty {
            NSLog("[MacDriver] Missing permissions: %@", perms.joined(separator: ", "))
            // macOS grants these per signed program; say which program this is.
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            if let id = Bundle.main.bundleIdentifier {
                NSLog("[MacDriver] Running as %@ (%@). Grant both permissions to this app in System Settings > Privacy & Security, then relaunch.",
                      id, Bundle.main.bundlePath)
            } else {
                NSLog("[MacDriver] Running as a bare executable (%@), not MacDriver.app. Grants given to MacDriver.app do not apply to it, and an ad-hoc signed build gets a new identity every build. From Xcode, run scripts/install_xcode_scheme.sh and use the \"MacDriver (app)\" scheme; from a terminal, use scripts/bundle.sh and open build/MacDriver.app.", exe)
            }
        }
        if !ProcessInfo.processInfo.arguments.contains("--no-mirror") { presentMirror(activate: false) }
    }

    /// Requests what is missing and reports it; the app still starts so status is observable.
    private func checkPermissions() -> [String] {
        var missing: [String] = []
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { missing.append("Accessibility") }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess(); missing.append("Screen Recording") }
        return missing
    }

    // MARK: Shutdown

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            // Not NSApp.terminate directly: this handler runs as a main-queue block, and the
            // shutdown (terminateLater) needs the main queue while AppKit waits in a nested run
            // loop, which would deadlock. A run-loop perform runs outside the main queue.
            s.setEventHandler { RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { NSApp.terminate(nil) } } }
            s.resume()
            signalSources.append(s)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state != .stopping && state != .stopped else { return .terminateNow }
        state = .stopping
        Task { @MainActor in
            await mirror?.stopStream()
            server.stop()
            barrier.stop()
            await driver.shutdown()   // cancels calls, releases input, returns windows, releases display
            state = .stopped
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Control

    @objc func takeControl() { driver.arbiter.takeControl() }

    @objc func giveBack() {
        forwarder.reset()
        driver.arbiter.giveBack()
    }

    @objc func showMirror() { presentMirror(activate: true) }

    func presentMirror(activate: Bool) {
        guard display.displayID != nil else { return }
        if mirror == nil { mirror = MirrorWindowController(app: self) }
        mirror?.present(activate: activate)
    }

    // MARK: Putting windows on the virtual monitor (explicit user actions)

    /// Shows a short result in the mirror's status line (opening the mirror if needed) and the log.
    func report(_ msg: String) {
        NSLog("[MacDriver] %@", msg)
        if mirror == nil { showMirror() }
        mirror?.showFeedback(msg)
    }

    @objc func openAppHere() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Open an App on the Virtual Monitor"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        report("Opening \(url.deletingPathExtension().lastPathComponent)…")
        Task { let msg = await driver.userOpen(appURL: url); await MainActor.run { self.report(msg) } }
    }

    @objc func openFileHere() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Open a File on the Virtual Monitor"
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        report("Opening \(url.lastPathComponent)…")
        Task { let msg = await driver.userOpen(fileURL: url); await MainActor.run { self.report(msg) } }
    }

    @objc func moveWindowHere(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGWindowID else { return }
        do { try driver.userMoveToVirtual(id); report("Moved \(sender.title) to the virtual monitor") }
        catch { report("Could not move \(sender.title): \(error)") }
    }

    @objc func sendWindowBack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGWindowID else { return }
        do { try driver.userSendBack(id); report("Sent \(sender.title) back") }
        catch { report("Could not send \(sender.title) back: \(error)") }
    }

    /// "Move Window Here" and "Send Window Back" submenus, built fresh each time they open.
    func windowMenuItems() -> [NSMenuItem] {
        func submenu(_ title: String, _ items: [UserWindowItem], _ action: Selector, empty: String) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu()
            if items.isEmpty { let e = NSMenuItem(title: empty, action: nil, keyEquivalent: ""); e.isEnabled = false; m.addItem(e) }
            for it in items {
                let mi = NSMenuItem(title: it.label, action: action, keyEquivalent: "")
                mi.target = self; mi.representedObject = it.windowID
                m.addItem(mi)
            }
            parent.submenu = m
            return parent
        }
        let open = NSMenuItem(title: "Open App Here…", action: #selector(openAppHere), keyEquivalent: ""); open.target = self
        let file = NSMenuItem(title: "Open File Here…", action: #selector(openFileHere), keyEquivalent: ""); file.target = self
        return [open, file,
                submenu("Move Window Here", driver.windowsOnPhysicalDisplays(), #selector(moveWindowHere(_:)), empty: "No windows on your displays"),
                submenu("Send Window Back", driver.windowsOnVirtualMonitor(), #selector(sendWindowBack(_:)), empty: "No windows on the virtual monitor")]
    }

    @objc func copySocketPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.path, forType: .string)
    }

    @objc func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "MacDriver")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshUI()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu(menu) }

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        info(state.label)
        if let vid = display.displayID {
            let b = CGDisplayBounds(vid)
            info("Virtual display \(vid): \(Int(b.width))×\(Int(b.height)) at (\(Int(b.minX)), \(Int(b.minY)))")
        }
        let dev = display.arrangementDeviations()
        info(dev.isEmpty ? "Physical arrangement unchanged" : "Arrangement: \(dev.joined(separator: "; "))")
        info("Permissions — Accessibility: \(AXIsProcessTrusted() ? "yes" : "NO"), Screen Recording: \(CGPreflightScreenCaptureAccess() ? "yes" : "NO")")
        info("Last call: \(lastActivity)")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Mirror", action: #selector(showMirror), keyEquivalent: "m").target = self
        if display.displayID != nil { windowMenuItems().forEach { menu.addItem($0) } }
        if driver.arbiter.owner == .agent {
            menu.addItem(withTitle: "Take Control", action: #selector(takeControl), keyEquivalent: "t").target = self
        } else {
            menu.addItem(withTitle: "Give Back", action: #selector(giveBack), keyEquivalent: "g").target = self
        }
        menu.addItem(withTitle: "Copy Socket Path", action: #selector(copySocketPath), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Privacy Settings…", action: #selector(openPrivacySettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacDriver", action: #selector(quit), keyEquivalent: "q").target = self
    }

    func refreshUI() {
        let symbol: String
        switch state {
        case .userControl: symbol = "hand.raised.fill"
        case .failed: symbol = "exclamationmark.triangle"
        default: symbol = "display.2"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacDriver")
        mirror?.refreshStatus(state.label)
    }
}
