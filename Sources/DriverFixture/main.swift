import AppKit

// A small app with known controls, used by Tests/E2E/fixture.py to check the driver against
// more than TextEdit. Every piece of state the tests need is shown in a label ("counter: 3"),
// so it can be read back through a snapshot.
//
// The two canvases are plain custom views with no accessibility actions: input can only reach
// them as real mouse and key events. "easy" accepts a first click while its app is inactive,
// "strict" does not (the AppKit default), which is the hard case for a background driver.

@MainActor
final class CanvasView: NSView {
    let name: String
    let acceptsFirst: Bool
    let report: (String) -> Void
    private var clicks = 0, rightClicks = 0, lastCount = 0, wheel = 0.0
    private var downAt: NSPoint?, drag = NSPoint.zero
    private var keys = ""

    init(frame: NSRect, name: String, acceptsFirst: Bool, report: @escaping (String) -> Void) {
        self.name = name; self.acceptsFirst = acceptsFirst; self.report = report
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(name)-canvas")
        publish()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirst }

    private func publish() {
        report("\(name): clicks=\(clicks) count=\(lastCount) right=\(rightClicks) drag=\(Int(drag.x)),\(Int(drag.y)) wheel=\(Int(wheel)) keys=\(keys)")
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        clicks += 1; lastCount = e.clickCount
        downAt = convert(e.locationInWindow, from: nil); drag = .zero
        publish()
    }
    override func mouseDragged(with e: NSEvent) {
        guard let d = downAt else { return }
        let p = convert(e.locationInWindow, from: nil)
        drag = NSPoint(x: p.x - d.x, y: p.y - d.y)
        publish()
    }
    override func mouseUp(with e: NSEvent) { downAt = nil }
    override func rightMouseDown(with e: NSEvent) { rightClicks += 1; publish() }
    override func scrollWheel(with e: NSEvent) { wheel += e.scrollingDeltaY; publish() }
    override func keyDown(with e: NSEvent) { keys += e.charactersIgnoringModifiers ?? ""; publish() }

    override func draw(_ dirtyRect: NSRect) {
        (acceptsFirst ? NSColor.systemTeal : NSColor.systemOrange).withAlphaComponent(0.25).setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke(); NSBezierPath(rect: bounds).stroke()
        ("\(name) canvas  clicks: \(clicks)" as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
    }
}

@MainActor
final class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var counter = 0
    let counterLabel = NSTextField(labelWithString: "counter: 0")
    let checkLabel = NSTextField(labelWithString: "checkbox: off")
    let strictLabel = NSTextField(labelWithString: "")
    let easyLabel = NSTextField(labelWithString: "")
    let scrollLabel = NSTextField(labelWithString: "scroll: 0")
    var scrollView: NSScrollView!

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Driver Fixture"
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
        window.contentView = root

        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 300, height: 24))
        field.placeholderString = "name"
        field.setAccessibilityLabel("name-field")
        root.addSubview(field)

        let button = NSButton(title: "Increment", target: self, action: #selector(increment))
        button.frame = NSRect(x: 20, y: 58, width: 120, height: 32)
        root.addSubview(button)
        counterLabel.frame = NSRect(x: 160, y: 64, width: 300, height: 20)
        root.addSubview(counterLabel)

        let check = NSButton(checkboxWithTitle: "Option", target: self, action: #selector(toggled(_:)))
        check.frame = NSRect(x: 20, y: 100, width: 120, height: 22)
        root.addSubview(check)
        checkLabel.frame = NSRect(x: 160, y: 101, width: 300, height: 20)
        root.addSubview(checkLabel)

        let strict = CanvasView(frame: NSRect(x: 20, y: 140, width: 250, height: 110), name: "strict", acceptsFirst: false) { [weak self] s in self?.strictLabel.stringValue = s }
        let easy = CanvasView(frame: NSRect(x: 290, y: 140, width: 250, height: 110), name: "easy", acceptsFirst: true) { [weak self] s in self?.easyLabel.stringValue = s }
        root.addSubview(strict); root.addSubview(easy)
        strictLabel.frame = NSRect(x: 20, y: 256, width: 520, height: 18)
        easyLabel.frame = NSRect(x: 20, y: 278, width: 520, height: 18)
        for l in [strictLabel, easyLabel] { l.font = .monospacedSystemFont(ofSize: 11, weight: .regular); root.addSubview(l) }

        scrollView = NSScrollView(frame: NSRect(x: 20, y: 306, width: 520, height: 160))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 3000))
        for i in 0..<100 {
            let l = NSTextField(labelWithString: "row \(i)")
            l.frame = NSRect(x: 8, y: CGFloat(i) * 30 + 6, width: 300, height: 18)
            doc.addSubview(l)
        }
        scrollView.documentView = doc
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        root.addSubview(scrollView)
        scrollLabel.frame = NSRect(x: 20, y: 474, width: 300, height: 18)
        root.addSubview(scrollLabel)

        window.center()
        window.makeKeyAndOrderFront(nil)
        installEventLog()
    }

    /// Debugging aid: `defaults write dev.macdriver.fixture eventLog -bool true` makes the app
    /// append every event AppKit hands it to $TMPDIR/driverfixture-events.log, which shows
    /// whether synthetic input arrived at all and in what state the app was.
    private func installEventLog() {
        guard UserDefaults.standard.bool(forKey: "eventLog") else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("driverfixture-events.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        NSEvent.addLocalMonitorForEvents(matching: .any) { e in
            var line = "type=\(e.type.rawValue) win=\(e.windowNumber) active=\(NSApp.isActive) key=\(e.window?.isKeyWindow ?? false)"
            if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .leftMouseDragged, .scrollWheel, .mouseMoved].contains(e.type) {
                line += " loc=\(e.locationInWindow.x),\(e.locationInWindow.y) clicks=\(e.type == .scrollWheel || e.type == .mouseMoved ? 0 : e.clickCount)"
            }
            if e.type == .appKitDefined || e.type == .systemDefined { line += " subtype=\(e.subtype.rawValue)" }
            h.write(Data((line + "\n").utf8))
            return e
        }
    }

    @objc func increment() { counter += 1; counterLabel.stringValue = "counter: \(counter)" }
    @objc func toggled(_ b: NSButton) { checkLabel.stringValue = "checkbox: \(b.state == .on ? "on" : "off")" }
    @objc func scrolled() { scrollLabel.stringValue = "scroll: \(Int(scrollView.contentView.bounds.origin.y))" }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
