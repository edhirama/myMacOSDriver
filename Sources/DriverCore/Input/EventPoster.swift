import Foundation
import AppKit
import CoreGraphics
import DriverProtocol

/// Tag written into every synthetic event's source user-data field, so our own events are
/// recognisable (e.g. by the pointer barrier) and never confused with the user's input.
public let driverEventTag: Int64 = 0x4D44_5256 // "MDRV"

public enum MouseButton: String, Sendable {
    case left, right, middle

    var cg: CGMouseButton { switch self { case .left: return .left; case .right: return .right; case .middle: return .center } }
    var down: CGEventType { switch self { case .left: return .leftMouseDown; case .right: return .rightMouseDown; case .middle: return .otherMouseDown } }
    var up: CGEventType { switch self { case .left: return .leftMouseUp; case .right: return .rightMouseUp; case .middle: return .otherMouseUp } }
    var dragged: CGEventType { switch self { case .left: return .leftMouseDragged; case .right: return .rightMouseDragged; case .middle: return .otherMouseDragged } }
}

/// Builds and delivers synthetic events directly to a target process (`CGEvent.postToPid`).
/// Events never pass through the HID system, so the user's cursor does not move and the
/// user's own keyboard/mouse state is untouched.
public final class EventPoster: @unchecked Sendable {
    private let source: CGEventSource?

    public init() {
        source = CGEventSource(stateID: .privateState)
        source?.userData = driverEventTag
        source?.localEventsSuppressionInterval = 0
    }

    public static var canPost: Bool { CGPreflightPostEventAccess() }

    // An event that goes through the window server is stamped there with the window it hits and
    // its position inside that window; AppKit reads both to find the view. An event posted
    // straight to a process skips the window server, so both are unset and AppKit finds no view:
    // the event arrives and is dropped. We stamp them ourselves: the window number is event
    // field 51 (undocumented, found by experiment against the fixture app; the public
    // "window under mouse pointer" fields alone are not enough), the position a private call.
    private static let windowNumberField = CGEventField(rawValue: 51)
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(s, to: SetWindowLocation.self)
    }()
    public static var canSetWindowLocation: Bool { setWindowLocation != nil }

    /// Stamps the event with its window and its position inside it (top-left origin, in points).
    private func stampWindowLocation(_ e: CGEvent, at p: CGPoint, windowID: CGWindowID) {
        if let f = Self.windowNumberField { e.setIntegerValueField(f, value: Int64(windowID)) }
        guard let set = Self.setWindowLocation,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: b) else { return }
        set(e, CGPoint(x: p.x - frame.minX, y: p.y - frame.minY))
    }

    public func mouse(_ type: CGEventType, at p: CGPoint, button: MouseButton, clickState: Int, flags: CGEventFlags,
                      windowID: CGWindowID, pid: pid_t) throws {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button.cg) else {
            throw DriverError(.internalError, "Could not create mouse event")
        }
        e.flags = flags
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        e.setIntegerValueField(.eventSourceUserData, value: driverEventTag)
        if button == .middle { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
        stampWindowLocation(e, at: p, windowID: windowID)
        e.postToPid(pid)
    }

    public func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, pid: pid_t) throws {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            throw DriverError(.internalError, "Could not create key event")
        }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: driverEventTag)
        e.postToPid(pid)
    }

    /// Posts a key-down/up pair carrying literal text (layout independent).
    public func text(_ s: String, pid: pid_t) throws {
        let utf16 = Array(s.utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
                throw DriverError(.internalError, "Could not create text event")
            }
            e.flags = []
            utf16.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: $0.baseAddress) }
            e.setIntegerValueField(.eventSourceUserData, value: driverEventTag)
            e.postToPid(pid)
        }
    }

    public func scroll(at p: CGPoint, dx: Int32, dy: Int32, flags: CGEventFlags, windowID: CGWindowID, pid: pid_t) throws {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            throw DriverError(.internalError, "Could not create scroll event")
        }
        e.location = p
        e.flags = flags
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        e.setIntegerValueField(.eventSourceUserData, value: driverEventTag)
        stampWindowLocation(e, at: p, windowID: windowID)
        e.postToPid(pid)
    }
}

/// Who is holding a button or key down: one tool call, or the human (the mirror window's
/// forwarder, and actions started from the host UI). Each owner's input is released on its own,
/// so one call ending, or a takeover, never lets go of something another owner is holding.
public struct InputOwner: Hashable, Sendable {
    public let id: String
    /// The human's input. A takeover releases only scripts' input, never the user's.
    public let isUser: Bool
    public init(id: String, isUser: Bool) { self.id = id; self.isUser = isUser }

    /// The human working in the mirror window.
    public static let mirror = InputOwner(id: "mirror", isUser: true)
    /// A new owner for one tool call.
    public static func call(asUser: Bool) -> InputOwner { InputOwner(id: UUID().uuidString, isUser: asUser) }
}

/// Tracks every button and key currently held down, and by whom, so they can always be
/// released: on success, error, cancellation, takeover, and shutdown. Nothing is ever left pressed.
public final class InputLedger: Sendable {
    struct HeldButton: Hashable { let owner: InputOwner; let button: String; let pid: pid_t; let windowID: CGWindowID; let x: Double; let y: Double }
    struct HeldKey: Hashable { let owner: InputOwner; let code: CGKeyCode; let pid: pid_t }
    private struct State {
        var buttons: Set<HeldButton> = []
        var keys: [HeldKey] = []
        /// Script owners whose held input a takeover released: their gesture cannot be continued.
        var interrupted: Set<InputOwner> = []
    }

    private let state = Locked(State())
    private let poster: EventPoster

    public init(poster: EventPoster) { self.poster = poster }

    func pressed(button: MouseButton, at p: CGPoint, windowID: CGWindowID, pid: pid_t, owner: InputOwner) {
        state.withLock { _ = $0.buttons.insert(HeldButton(owner: owner, button: button.rawValue, pid: pid, windowID: windowID, x: p.x, y: p.y)) }
    }
    func released(button: MouseButton, pid: pid_t, owner: InputOwner) {
        state.withLock { s in s.buttons = s.buttons.filter { !($0.owner == owner && $0.button == button.rawValue && $0.pid == pid) } }
    }
    func pressed(key: CGKeyCode, pid: pid_t, owner: InputOwner) { state.withLock { $0.keys.append(HeldKey(owner: owner, code: key, pid: pid)) } }
    func released(key: CGKeyCode, pid: pid_t, owner: InputOwner) {
        state.withLock { s in if let i = s.keys.lastIndex(of: HeldKey(owner: owner, code: key, pid: pid)) { s.keys.remove(at: i) } }
    }

    public var heldCount: Int { state.withLock { $0.buttons.count + $0.keys.count } }

    /// True when a takeover released input this owner was holding (a drag in progress), so its
    /// gesture was broken off and cannot be resumed.
    public func wasInterrupted(_ owner: InputOwner) -> Bool { state.withLock { $0.interrupted.contains(owner) } }

    /// Drops what is remembered about an owner whose call has ended.
    public func forget(_ owner: InputOwner) { state.withLock { _ = $0.interrupted.remove(owner) } }

    /// Releases scripts' held input because the user took control. The user's own input (a drag
    /// in the mirror) is left alone. Returns how many were released.
    @discardableResult
    public func releaseForTakeover() -> Int {
        release { s in
            let owners = Set(s.buttons.map(\.owner) + s.keys.map(\.owner)).filter { !$0.isUser }
            s.interrupted.formUnion(owners)
            return { !$0.isUser }
        }
    }

    /// Releases what one owner still holds, keys in reverse press order. Returns how many were released.
    @discardableResult
    public func releaseAll(owner: InputOwner) -> Int { release { _ in { $0 == owner } } }

    /// Releases everything anyone holds. Only for shutdown.
    @discardableResult
    public func releaseEverything() -> Int { release { _ in { _ in true } } }

    private func release(_ select: (inout State) -> (InputOwner) -> Bool) -> Int {
        let (bs, ks) = state.withLock { s in
            let match = select(&s)
            let bs = s.buttons.filter { match($0.owner) }, ks = s.keys.filter { match($0.owner) }
            s.buttons.subtract(bs); s.keys.removeAll { match($0.owner) }
            return (bs, ks)
        }
        for b in bs {
            let mb = MouseButton(rawValue: b.button) ?? .left
            try? poster.mouse(mb.up, at: CGPoint(x: b.x, y: b.y), button: mb, clickState: 1, flags: [], windowID: b.windowID, pid: b.pid)
        }
        for k in ks.reversed() { try? poster.key(k.code, down: false, flags: [], pid: k.pid) }
        if !bs.isEmpty || !ks.isEmpty { Log.input.info("Released \(bs.count) buttons and \(ks.count) keys") }
        return bs.count + ks.count
    }
}

/// The one listener for "an application became active", shared by everything in the driver that
/// needs to know.
///
/// The workspace's notification center is registered with once, on the main thread, and never
/// again. Adding and removing observers on it from the driver's own threads for every call
/// (as an earlier version did) races with the main thread delivering a notification, and that
/// crashed the host. Handlers are kept in a lock-protected table instead, which any thread may
/// change at any time. They are called on the main thread and must return quickly.
public final class ActivationMonitor: @unchecked Sendable {
    public static let shared = ActivationMonitor()
    public typealias Handler = @Sendable (NSRunningApplication) -> Void
    private struct State { var handlers: [Int: Handler] = [:]; var next = 1; var installed = false }
    private let state = Locked(State())

    public func add(_ handler: @escaping Handler) -> Int {
        let (id, install) = state.withLock { s -> (Int, Bool) in
            let id = s.next; s.next += 1; s.handlers[id] = handler
            let first = !s.installed; s.installed = true
            return (id, first)
        }
        if install {
            let register: @Sendable () -> Void = {
                NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    ActivationMonitor.shared.deliver(app)
                }
            }
            if Thread.isMainThread { register() } else { DispatchQueue.main.async(execute: register) }
        }
        return id
    }

    public func remove(_ id: Int) { state.withLock { _ = $0.handlers.removeValue(forKey: id) } }

    private func deliver(_ app: NSRunningApplication) {
        // Called outside the lock, so a handler may add or remove handlers.
        for h in state.withLock({ Array($0.handlers.values) }) { h(app) }
    }
}

/// Watches the system's frontmost application across an action. Some apps ask the system for
/// activation themselves when they show a window (Chrome does on "New Window"), and nothing
/// outside the app can refuse that request. So the guard listens for the activation and hands
/// focus back to the previously frontmost app as soon as it is announced, instead of at the end
/// of the action, and the incident is reported in the response.
///
/// Only the watched app is acted on: if the user switches apps themself during the action, that
/// is their choice and is left alone.
public final class FocusGuard: @unchecked Sendable {
    let previous: NSRunningApplication?
    private struct State { var watched: pid_t?; var taken = 0; var name: String?; var token: Int? }
    private let state = Locked(State())

    public init(watching pid: pid_t? = nil) {
        previous = NSWorkspace.shared.frontmostApplication
        state.withLock { $0.watched = pid }
        let token = ActivationMonitor.shared.add { [weak self] app in self?.activated(app) }
        state.withLock { $0.token = token }
    }

    deinit { stop() }

    /// Names the app to watch once its process is known (after a launch).
    public func watch(_ pid: pid_t) { state.withLock { $0.watched = pid } }

    private func stop() {
        if let t = state.withLock({ s -> Int? in defer { s.token = nil }; return s.token }) {
            ActivationMonitor.shared.remove(t)
        }
    }

    private func activated(_ app: NSRunningApplication) {
        guard let prev = previous, app.processIdentifier != prev.processIdentifier else { return }
        let ours = state.withLock { s -> Bool in
            guard s.watched == app.processIdentifier else { return false }
            s.taken += 1; s.name = app.localizedName
            return true
        }
        if ours { Self.giveBack(prev) }
    }

    private static func giveBack(_ prev: NSRunningApplication) {
        if prev.processIdentifier == getpid() {
            // The host itself was in front: an app activates itself more reliably than it is activated.
            Task { @MainActor in NSApplication.shared.activate(ignoringOtherApps: true) }
        } else {
            prev.activate(options: [])
        }
    }

    /// Ends the watch. Returns a warning when the target app took focus during the action.
    public func restore(targetPid: pid_t) -> String? {
        defer { stop() }
        guard let prev = previous, prev.processIdentifier != targetPid else { return nil }
        watch(targetPid)
        // Give AppKit a moment to process any activation.
        Thread.sleep(forTimeInterval: 0.03)
        func targetInFront() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid }
        if targetInFront() {
            state.withLock { $0.taken += 1 }
            Self.giveBack(prev)
            let until = monotonicMs() + 400
            while targetInFront() && monotonicMs() < until { Thread.sleep(forTimeInterval: 0.02) }
        }
        let s = state.get
        guard s.taken > 0 else { return nil }
        let target = s.name ?? NSRunningApplication(processIdentifier: targetPid)?.localizedName ?? String(targetPid)
        let back = prev.localizedName ?? "the previous app"
        return targetInFront()
            ? "Target app \(target) activated itself and focus could not be returned to \(back)"
            : "Target app \(target) activated itself; focus was returned to \(back)"
    }
}
