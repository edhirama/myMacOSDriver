import AppKit
import AVFoundation
import DriverCore

/// The mirror preview. Closing it only stops the stream: the display, the windows on it and the
/// current control owner are untouched (in particular, closing never gives control back).
@MainActor
final class MirrorWindowController: NSObject, NSWindowDelegate {
    private unowned let app: AppDelegate
    private let window: NSWindow
    private let stream = MirrorStream()
    private let videoView: MirrorView
    private let statusLabel = NSTextField(labelWithString: "")
    private let controlButton = NSButton(title: "Take Control", target: nil, action: nil)
    private var feedback = ""

    init(app: AppDelegate) {
        self.app = app
        videoView = MirrorView(stream: stream)
        let size = app.display.geometry?.bounds.size ?? CGSize(width: 1920, height: 1080)
        let contentW: CGFloat = 960
        let contentH = contentW * size.height / size.width + 44
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "MacDriver — Virtual Monitor"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 480, height: 300)
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]

        controlButton.target = self
        controlButton.action = #selector(toggleControl)
        controlButton.bezelStyle = .rounded
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let windowsButton = NSButton(title: "Windows ▾", target: self, action: #selector(showWindowsMenu(_:)))
        windowsButton.bezelStyle = .rounded
        windowsButton.toolTip = "Open an app or file on the virtual monitor, or move a window there and back"
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [controlButton, windowsButton, statusLabel])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        bar.spacing = 12

        let root = NSStackView(views: [bar, videoView])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        bar.setContentHuggingPriority(.required, for: .vertical)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        videoView.forwarder = app.forwarder
        app.forwarder.onFeedback = { [weak self] msg in
            Task { @MainActor in guard let self else { return }; self.feedback = msg; self.refreshStatus(self.app.state.label) }
        }
        videoView.displaySize = size
        stream.onError = { [weak self] msg in Task { @MainActor in self?.statusLabel.stringValue = "Stream stopped: \(msg)" } }
        ownerChanged(app.driver.arbiter.owner)
        window.center()
    }

    @objc private func showWindowsMenu(_ sender: NSButton) {
        let menu = NSMenu()
        app.windowMenuItems().forEach { menu.addItem($0) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func showFeedback(_ msg: String) {
        feedback = msg
        refreshStatus(app.state.label)
    }

    /// `activate` is false when the host shows the mirror on its own (at launch): a window that
    /// appears must not take the user's keyboard away from the app they are working in.
    func present(activate: Bool = true) {
        // A minimized mirror must be restored, not just ordered front.
        if window.isMiniaturized { window.deminiaturize(nil) }
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFrontRegardless()
        }
        syncStream()
    }

    // MARK: Stream lifecycle

    private var streamWork: Task<Void, Never>?

    /// The picture is captured only while someone can see it: not while the mirror is closed,
    /// minimized or completely covered by other windows.
    private var mirrorIsVisible: Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// Pixels the picture is shown at, never more than the display has points (the capture size before).
    private var captureSize: CGSize {
        let display = app.display.geometry?.bounds.size ?? CGSize(width: 1920, height: 1080)
        let shown = videoView.bounds.width * (window.backingScaleFactor)
        let w = max(320, min(display.width, shown.rounded()))
        return CGSize(width: w, height: (w * display.height / display.width).rounded())
    }

    private var frameRate: Int {
        app.driver.arbiter.owner == .user ? MirrorStream.interactiveFPS : MirrorStream.previewFPS
    }

    /// Starts or stops the stream to match whether the mirror can be seen. Changes are applied
    /// one after another, each against the state at the time it runs.
    private func syncStream() {
        let previous = streamWork
        streamWork = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if self.mirrorIsVisible {
                guard !self.stream.isRunning, let geo = self.app.display.geometry else { return }
                do {
                    try await self.stream.start(displayID: geo.displayID, size: self.captureSize, fps: self.frameRate)
                    self.refreshStatus(self.app.state.label)
                } catch {
                    self.statusLabel.stringValue = "Mirror unavailable: \(error.localizedDescription) (Screen Recording permission?)"
                }
            } else if self.stream.isRunning {
                await self.stream.stop()
            }
        }
    }

    func stopStream() async {
        await streamWork?.value
        await stream.stop()
    }

    func windowWillClose(_ notification: Notification) {
        // Only the preview goes away. Control ownership is intentionally left as it is.
        Task { await stream.stop() }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { syncStream() }
    func windowDidMiniaturize(_ notification: Notification) { syncStream() }
    func windowDidDeminiaturize(_ notification: Notification) { syncStream() }
    func windowDidEndLiveResize(_ notification: Notification) {
        let size = captureSize
        Task { await stream.update(size: size) }
    }
    func windowDidChangeBackingProperties(_ notification: Notification) {
        let size = captureSize
        Task { await stream.update(size: size) }
    }

    func displayChanged() {
        if let s = app.display.geometry?.bounds.size { videoView.displaySize = s }
    }

    func ownerChanged(_ owner: ControlOwner) {
        let user = owner == .user
        feedback = ""
        controlButton.title = user ? "Give Back" : "Take Control"
        videoView.interactive = user
        videoView.layer?.borderWidth = user ? 3 : 0
        videoView.layer?.borderColor = NSColor.systemOrange.cgColor
        refreshStatus(app.state.label)
        if user { window.makeFirstResponder(videoView) }
        let fps = frameRate
        Task { await stream.update(fps: fps) }
    }

    func refreshStatus(_ s: String) {
        let user = app.driver.arbiter.owner == .user
        let hint: String
        if !feedback.isEmpty { hint = "  ·  \(feedback)" }
        else if user { hint = "  ·  Click a window in this view; keys go to the window you clicked." }
        else { hint = "  ·  Use Windows ▾ to put an app or window on this monitor." }
        statusLabel.stringValue = s + hint
    }

    @objc private func toggleControl() {
        if app.driver.arbiter.owner == .agent { app.takeControl() } else { app.giveBack() }
    }
}

/// Displays the stream and, while the user holds control, converts their input in this view to
/// virtual-display coordinates.
final class MirrorView: NSView {
    let stream: MirrorStream
    weak var forwarder: UserInputForwarder?
    var interactive = false
    var displaySize = CGSize(width: 1920, height: 1080)
    private var tracking: NSTrackingArea?

    init(stream: MirrorStream) {
        self.stream = stream
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(stream.layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stream.layer.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
        super.updateTrackingAreas()
    }

    /// Aspect-fit rectangle of the video inside the view.
    private var videoRect: CGRect {
        let s = min(bounds.width / displaySize.width, bounds.height / displaySize.height)
        let w = displaySize.width * s, h = displaySize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// View point -> virtual display point (top-left origin), or nil outside the video.
    private func displayPoint(_ e: NSEvent) -> CGPoint? {
        let p = convert(e.locationInWindow, from: nil)
        let r = videoRect
        guard r.contains(p) else { return nil }
        let x = (p.x - r.minX) / r.width * displaySize.width
        let y = (r.maxY - p.y) / r.height * displaySize.height
        return CGPoint(x: x, y: y)
    }

    private func flags(_ e: NSEvent) -> CGEventFlags { CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue)) }

    override func mouseDown(with e: NSEvent) { press(e, .left) }
    override func rightMouseDown(with e: NSEvent) { press(e, .right) }
    override func otherMouseDown(with e: NSEvent) { press(e, .middle) }
    private func press(_ e: NSEvent, _ b: MouseButton) {
        window?.makeFirstResponder(self)
        guard interactive, let p = displayPoint(e) else { return }
        forwarder?.mouseDown(p, button: b, clickCount: e.clickCount, flags: flags(e))
    }
    override func mouseDragged(with e: NSEvent) { drag(e) }
    override func rightMouseDragged(with e: NSEvent) { drag(e) }
    override func otherMouseDragged(with e: NSEvent) { drag(e) }
    private func drag(_ e: NSEvent) {
        guard interactive, let p = displayPoint(e) else { return }
        forwarder?.mouseDragged(p, flags: flags(e))
    }
    override func mouseUp(with e: NSEvent) { release(e) }
    override func rightMouseUp(with e: NSEvent) { release(e) }
    override func otherMouseUp(with e: NSEvent) { release(e) }
    private func release(_ e: NSEvent) {
        guard let p = displayPoint(e) ?? displayPoint(e) else { forwarder?.mouseUp(.zero, clickCount: e.clickCount, flags: []); return }
        forwarder?.mouseUp(p, clickCount: e.clickCount, flags: flags(e))
    }
    override func mouseMoved(with e: NSEvent) {
        guard interactive, let p = displayPoint(e) else { return }
        forwarder?.mouseMoved(p)
    }
    override func scrollWheel(with e: NSEvent) {
        guard interactive, let p = displayPoint(e) else { return }
        let scale: CGFloat = e.hasPreciseScrollingDeltas ? 0.1 : 1
        let dy = Int32((e.scrollingDeltaY * scale).rounded()), dx = Int32((e.scrollingDeltaX * scale).rounded())
        if dx != 0 || dy != 0 { forwarder?.scroll(p, dx: dx, dy: dy, flags: flags(e)) }
    }
    override func keyDown(with e: NSEvent) { if interactive { forwarder?.key(CGKeyCode(e.keyCode), down: true, flags: flags(e)) } }
    override func keyUp(with e: NSEvent) { if interactive { forwarder?.key(CGKeyCode(e.keyCode), down: false, flags: flags(e)) } }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        // While in control, Command shortcuts belong to the virtual monitor, not to this app.
        guard interactive, window?.firstResponder === self else { return super.performKeyEquivalent(with: e) }
        forwarder?.key(CGKeyCode(e.keyCode), down: true, flags: flags(e))
        forwarder?.key(CGKeyCode(e.keyCode), down: false, flags: flags(e))
        return true
    }
}
