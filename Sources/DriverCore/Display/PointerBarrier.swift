import Foundation
import CoreGraphics
import DriverProtocol

/// Keeps the user's hardware pointer out of the virtual display.
///
/// The virtual display touches the physical layout only at one corner, but a fast diagonal
/// motion could still cross that point. A session-level event tap watches pointer motion; if
/// the cursor would land inside the virtual display, it is warped back to the last physical
/// position, kept a little inside the display so it stays visible. The driver's own input is
/// posted per-process and never moves the cursor, so it never meets this tap.
public final class PointerBarrier: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let blocked = Locked<CGRect>(.null)
    private let lastGood = Locked<CGPoint>(.zero)
    private let runLoop = Locked<CFRunLoop?>(nil)
    public private(set) var interventions = 0
    private struct Stop { let at: Date; let from: CGPoint; let to: CGPoint }
    private let recent = Locked<[Stop]>([])
    public var onIntervention: (@Sendable (CGPoint) -> Void)?

    public init() {}

    public var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Called at start and after every change to the display layout.
    public func setBlockedRegion(_ r: CGRect) {
        blocked.withLock { $0 = r }
        rescueIfTrapped()
    }

    /// Puts the pointer back on a real display if it is on the virtual one. A layout change can
    /// leave it there without any mouse movement: when a monitor is unplugged, the displays are
    /// rearranged under a pointer that stays where it was.
    public func rescueIfTrapped() {
        let region = blocked.get
        guard !region.isNull, let at = CGEvent(source: nil)?.location, region.contains(at),
              let back = Self.returnPoint(wanted: lastGood.get, displays: Self.activeDisplayBounds(), blocked: region) else { return }
        lastGood.withLock { $0 = back }
        CGWarpMouseCursorPosition(back)
        CGAssociateMouseAndMouseCursorPosition(1)
        interventions += 1
        recent.withLock { $0.append(Stop(at: Date(), from: at, to: back)); if $0.count > 8 { $0.removeFirst() } }
    }

    static func activeDisplayBounds() -> [CGRect] {
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &ids, &n)
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
    }

    /// Where a stopped pointer goes: the point nearest `wanted` that is on a real display, kept
    /// in from that display's edges. Nil when there is no real display to return it to.
    ///
    /// `wanted` is the last position seen on a real display, but it cannot be trusted to still
    /// be on one: after a monitor is unplugged the remaining displays move, and the remembered
    /// point can lie inside the virtual display. Returning the pointer there would hold it on a
    /// screen the user cannot see, however they moved the mouse.
    static func returnPoint(wanted: CGPoint, displays: [CGRect], blocked: CGRect, inset: CGFloat = 16) -> CGPoint? {
        displays.filter { !$0.intersects(blocked) && !$0.isEmpty }
            .map { visibleReturnPoint(wanted, displayBounds: $0, inset: inset) }
            .min { hypot($0.x - wanted.x, $0.y - wanted.y) < hypot($1.x - wanted.x, $1.y - wanted.y) }
    }

    /// Installs the tap on a thread of its own. Returns false if the tap could not be created
    /// (missing Accessibility permission).
    ///
    /// The tap sits in the path of every pointer movement the user makes, and the system waits
    /// for its answer before the movement goes on to apps. On the main thread, any work the host
    /// does there would be felt as pointer lag; on its own thread the answer never waits for
    /// anything else.
    @discardableResult
    public func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: pointerBarrierCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        tap = t
        nonisolated(unsafe) let port = t
        nonisolated(unsafe) let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        source = src
        if let p = CGEvent(source: nil)?.location { lastGood.withLock { $0 = p } }
        let ready = DispatchSemaphore(value: 0)
        let loopBox = runLoop
        let thread = Thread {
            let rl = CFRunLoopGetCurrent()
            loopBox.withLock { $0 = rl }
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "dev.macdriver.pointer-barrier"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    public func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let rl = runLoop.withLock({ r -> CFRunLoop? in defer { r = nil }; return r }) {
            if let s = source { CFRunLoopRemoveSource(rl, s, .commonModes) }
            CFRunLoopStop(rl)
        }
        tap = nil; source = nil
    }

    /// Where to put the pointer after it was stopped: its last position on a real display, moved
    /// in from the display's edges. The virtual display touches the real ones at a corner, and a
    /// pointer left exactly in a bottom or right corner is drawn almost entirely off screen, so
    /// to the user it would look as if the pointer had disappeared.
    static func visibleReturnPoint(_ p: CGPoint, displayBounds b: CGRect, inset: CGFloat = 16) -> CGPoint {
        guard b.width > inset * 2, b.height > inset * 2 else { return p }
        return CGPoint(x: min(max(p.x, b.minX + inset), b.maxX - inset), y: min(max(p.y, b.minY + inset), b.maxY - inset))
    }

    /// The pointer as the system reports it, for diagnosing "my cursor disappeared": where it is,
    /// whether the system considers it shown, when the mouse last really moved, and what the
    /// barrier last did to it.
    public func report() -> JSONValue {
        typealias IsVisible = @convention(c) () -> Int32
        let visible: JSONValue = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible")
            .map { .bool(unsafeBitCast($0, to: IsVisible.self)() != 0) } ?? .null
        let at = CGEvent(source: nil)?.location ?? .zero
        func point(_ p: CGPoint) -> JSONValue { ["x": .number(p.x.rounded()), "y": .number(p.y.rounded())] }
        let now = Date()
        return [
            "location": point(at),
            "on_virtual_monitor": .bool(blocked.get.contains(at)),
            "visible": visible,
            "seconds_since_mouse_moved": .number(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved).rounded()),
            "barrier_active": .bool(isActive),
            "barrier_stops": .number(Double(interventions)),
            "recent_stops": .array(recent.get.map { ["seconds_ago": .number(now.timeIntervalSince($0.at).rounded()), "from": point($0.from), "to": point($0.to)] }),
        ]
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let p = event.location
        let region = blocked.get
        if !region.isNull, region.contains(p) {
            // With no real display to return to, holding the pointer back would only trap it.
            guard let back = Self.returnPoint(wanted: lastGood.get, displays: Self.activeDisplayBounds(), blocked: region) else {
                return Unmanaged.passUnretained(event)
            }
            lastGood.withLock { $0 = back }
            CGWarpMouseCursorPosition(back)
            CGAssociateMouseAndMouseCursorPosition(1)
            interventions += 1
            recent.withLock { $0.append(Stop(at: Date(), from: p, to: back)); if $0.count > 8 { $0.removeFirst() } }
            onIntervention?(p)
            return nil
        }
        lastGood.withLock { $0 = p }
        return Unmanaged.passUnretained(event)
    }
}

private func pointerBarrierCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<PointerBarrier>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
