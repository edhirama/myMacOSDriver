import Foundation
import ApplicationServices
import CoreGraphics
import DriverProtocol

/// Forwards the human's input from the mirror window to the virtual display while they hold
/// control. Delivery goes through the same InputRouter as the driver's tools, so even during
/// takeover the user's real cursor stays on the physical displays, and a click behaves the same
/// whether a script or a person made it.
///
/// What this class adds is the live gesture: a press, drags and a release arrive as separate
/// events, so it remembers which route the press took until the release.
public final class UserInputForwarder: Sendable {
    private let driver: Driver
    /// A left-button gesture handled through accessibility instead of mouse events.
    private enum Semantic { case text(start: InputRouter.Target), press(AXUIElement, frame: CGRect?) }
    private struct State {
        /// Where typed keys go: the last window clicked.
        var keyTarget: (pid: pid_t, windowID: CGWindowID)?
        /// The window and button held down, for gestures sent as mouse events.
        var dragTarget: (target: InputRouter.Target, button: MouseButton)?
        var semantic: Semantic?
        var onFeedback: (@Sendable (String) -> Void)?
    }
    private let state = Locked(State())

    /// Short human-readable feedback for the mirror's status line (e.g. what was clicked).
    public var onFeedback: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onFeedback } }
        set { state.withLock { $0.onFeedback = newValue } }
    }

    public init(driver: Driver) { self.driver = driver }

    private var enabled: Bool { driver.arbiter.owner == .user }

    private func target(at local: CGPoint) -> (global: CGPoint, pid: pid_t, windowID: CGWindowID, owner: String)? {
        guard let geo = driver.display.geometry else { return nil }
        let g = geo.toGlobal(local)
        do {
            let hit = try driver.hitTest(g, on: geo.displayID)
            return (g, hit.pid, hit.windowID, hit.owner)
        } catch let e as DriverError {
            onFeedback?(e.code == .outOfBounds ? "Desktop: no window under the pointer" : e.message)
            return nil
        } catch { return nil }
    }

    private var router: InputRouter { driver.router }

    /// `local` is in virtual-display points (top-left origin).
    public func mouseDown(_ local: CGPoint, button: MouseButton, clickCount: Int, flags: CGEventFlags) {
        guard enabled, let t = target(at: local) else { return }
        let tgt = InputRouter.Target(pid: t.pid, windowID: t.windowID, point: t.global)
        let count = max(1, clickCount)
        if count == 1 { router.makeKey(tgt, hooks: .mirror) }
        state.withLock { $0.keyTarget = (t.pid, t.windowID); $0.semantic = nil }
        switch router.route(tgt, button: button, count: count, flags: flags) {
        case .text(let el):
            if let r = router.clickText(el, at: t.global, count: count, extend: flags.contains(.maskShift)) {
                state.withLock { $0.semantic = .text(start: tgt) }
                onFeedback?(r.length > 0 ? "Selected \(r.length) characters in \(t.owner)" : "Caret placed in \(t.owner)")
                return
            }
        case .control(let el, _):
            // Like a real button: it fires on release, if the pointer is still on it.
            let frame = AX.frame(el)
            state.withLock { $0.semantic = .press(el, frame: frame) }
            return
        case .element, .events: break
        }
        state.withLock { $0.dragTarget = (tgt, button) }
        try? router.mouseDown(tgt, button: button, clickState: count, flags: flags, owner: .mirror)
        onFeedback?("\(button.rawValue.capitalized) click → \(t.owner)")
    }

    public func mouseDragged(_ local: CGPoint, flags: CGEventFlags) {
        guard enabled, let geo = driver.display.geometry else { return }
        let (t, sem) = state.withLock { ($0.dragTarget, $0.semantic) }
        if case .text(let start)? = sem {
            _ = router.selectText(start, to: geo.toGlobal(local))
            return
        }
        guard let t else { return }
        try? router.mouseDragged(t.target.at(geo.toGlobal(local)), button: t.button, flags: flags)
    }

    public func mouseUp(_ local: CGPoint, clickCount: Int, flags: CGEventFlags) {
        // No `enabled` check: a button pressed before Give Back must still be released.
        guard let geo = driver.display.geometry else { return }
        let (t, sem) = state.withLock { s in
            let held = (s.dragTarget, s.semantic)
            s.dragTarget = nil; s.semantic = nil
            return held
        }
        if case .press(let el, let frame)? = sem {
            if frame.map({ $0.contains(geo.toGlobal(local)) }) ?? true {
                let ok = router.press(el) == .success
                let name = AX.string(el, kAXTitleAttribute) ?? AX.string(el, kAXDescriptionAttribute) ?? AX.string(el, kAXRoleAttribute) ?? "control"
                onFeedback?(ok ? "Pressed \(name)" : "\(name) did not respond")
            }
            return
        }
        guard let t else { return }
        try? router.mouseUp(t.target.at(geo.toGlobal(local)), button: t.button, clickState: max(1, clickCount), flags: flags, owner: .mirror)
    }

    public func mouseMoved(_ local: CGPoint) {
        guard enabled, let geo = driver.display.geometry else { return }
        let g = geo.toGlobal(local)
        // Hover only: no feedback, and silently nothing over the desktop.
        guard let hit = try? driver.hitTest(g, on: geo.displayID) else { return }
        try? driver.poster.mouse(.mouseMoved, at: g, button: .left, clickState: 0, flags: [], windowID: hit.windowID, pid: hit.pid)
    }

    public func scroll(_ local: CGPoint, dx: Int32, dy: Int32, flags: CGEventFlags) {
        guard enabled, dx != 0 || dy != 0, let t = target(at: local) else { return }
        let tgt = InputRouter.Target(pid: t.pid, windowID: t.windowID, point: t.global)
        let router = self.router
        // Scrolling does not change which window is key, as with a real mouse.
        Task.detached(priority: .userInitiated) {
            _ = try? await router.scroll(tgt, dx: dx, dy: dy, flags: flags, hooks: .mirror) { try? await sleepMs(60) }
        }
    }

    public func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard enabled else { return }
        let t = state.withLock { $0.keyTarget }
        guard let t else {
            if down { onFeedback?("Click a window in the mirror first; keys go to the window you clicked") }
            return
        }
        try? driver.poster.key(code, down: down, flags: flags, pid: t.pid)
        if down { driver.inputLedger.pressed(key: code, pid: t.pid, owner: .mirror) } else { driver.inputLedger.released(key: code, pid: t.pid, owner: .mirror) }
    }

    /// Called on Give Back: anything the user still holds is released.
    public func reset() {
        state.withLock { $0.keyTarget = nil; $0.dragTarget = nil; $0.semantic = nil }
        driver.inputLedger.releaseAll(owner: .mirror)
    }
}
