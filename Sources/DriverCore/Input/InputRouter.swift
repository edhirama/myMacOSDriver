import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// The one place that decides *how* pointer input reaches a background app, and delivers it.
///
/// Both callers go through it: the driver's tools (the agent) and the mirror window's forwarder
/// (the human during takeover). They differ only in what they wrap around it: tools pass hooks
/// that pause on takeover and record evidence, the forwarder passes none.
///
/// The ladder, gentlest first. Each gesture uses exactly one rung, so nothing acts twice:
/// 1. `element`: the caller named an element (a snapshot ref) that can be pressed: AXPress.
/// 2. `text` / `control`: text and standard controls ignore a "first click" in an inactive app,
///    so they are driven through accessibility (see SemanticPointer).
/// 3. `events`: per-process mouse events, after making the window key inside its app.
///
/// The target app is never activated on any rung.
public final class InputRouter: Sendable {
    private let poster: EventPoster
    private let ledger: InputLedger
    private let windows: WindowService

    public init(poster: EventPoster, ledger: InputLedger, windows: WindowService) {
        self.poster = poster; self.ledger = ledger; self.windows = windows
    }

    public struct Target: Sendable {
        public let pid: pid_t
        public let windowID: CGWindowID
        /// Global (all-displays) coordinates.
        public let point: CGPoint
        public init(pid: pid_t, windowID: CGWindowID, point: CGPoint) { self.pid = pid; self.windowID = windowID; self.point = point }
        func at(_ p: CGPoint) -> Target { Target(pid: pid, windowID: windowID, point: p) }
    }

    public enum Route {
        case element(AXUIElement)
        case text(AXUIElement)
        case control(AXUIElement, role: String)
        case events
    }

    /// What the caller wants to happen around each step. The defaults do nothing, except
    /// `owner`, which every caller must name.
    public struct Hooks: Sendable {
        /// Called before every piece of input; may suspend (takeover) or throw (cancelled).
        public var gate: @Sendable () async throws -> Void = {}
        public var dispatched: @Sendable (Int) -> Void = { _ in }
        public var evidence: @Sendable (String) -> Void = { _ in }
        public var confirm: @Sendable (String) -> Void = { _ in }
        public var warn: @Sendable (String) -> Void = { _ in }
        /// Who holds the buttons this gesture presses: one tool call, or the human in the mirror.
        public var owner: InputOwner
        public init(owner: InputOwner) { self.owner = owner }
        /// The human in the mirror: no gate, nothing recorded.
        public static let mirror = Hooks(owner: .mirror)
    }

    public struct ClickOutcome {
        public let method: String
        public var selection: CFRange?
    }

    public struct ScrollOutcome {
        public let method: String
        public let before: Double?
        public let after: Double?
        public let atLimit: Bool
    }

    // MARK: Deciding

    /// How a press at this target must be delivered. The single source of truth for both callers.
    public func route(_ t: Target, button: MouseButton, count: Int, flags: CGEventFlags, element: AXUIElement? = nil) -> Route {
        let command = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        let shift = flags.contains(.maskShift)
        guard button == .left, !command else { return .events }
        // A web page only notices input that runs its own handlers, and sites watch for clicks
        // that arrive without them: pressing a link through accessibility navigates, but the
        // page sees no pointer at all (one shop answered such a press with an "are you human"
        // check). Inside web content every click is a real pointer click.
        if Self.isWebContent(element ?? Self.elementAt(t.point, pid: t.pid)) { return .events }
        if let element, count == 1, !shift, AX.actions(element).contains(kAXPressAction) { return .element(element) }
        if let el = AXText.editableText(at: t.point, pid: t.pid) { return .text(el) }
        if count == 1, !shift, let c = SemanticPointer.pressable(at: t.point, pid: t.pid) { return .control(c.element, role: c.role) }
        return .events
    }

    static func elementAt(_ p: CGPoint, pid: pid_t) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AX.app(pid), Float(p.x), Float(p.y), &el) == .success else { return nil }
        return el
    }

    /// Whether the element lies inside a web page (has a web area among its ancestors).
    static func isWebContent(_ el: AXUIElement?) -> Bool {
        var cur = el, depth = 0
        while let e = cur, depth < 80 {
            if AX.string(e, kAXRoleAttribute) == "AXWebArea" { return true }
            cur = AX.element(e, kAXParentAttribute); depth += 1
        }
        return false
    }

    // MARK: Primitives

    /// Makes the target's window key inside its app and has the app consider itself active, so
    /// AppKit delivers input to the view instead of treating it as an activation click. Neither
    /// step activates the app as far as the system or the user is concerned. Returns nil for
    /// popups and menus, which are left alone.
    @discardableResult
    public func makeKey(_ t: Target, hooks: Hooks) -> Bool? {
        guard let w = try? windows.resolve(t.windowID), AX.string(w.ax, kAXRoleAttribute) == kAXWindowRole else { return nil }
        // The app is told it is active first: an app that processes "you became active" after
        // the key-window change restores the window that was key before, undoing the change.
        WindowFocuser.ensureBelievesActive(pid: t.pid)
        noteLender(t, hooks: hooks)
        // Sent, then checked with the app itself. Keys posted to an app go to whatever window
        // it considers key, so "probably key" is not good enough for keyboard input.
        var sent = false, key = WindowFocuser.isKey(pid: t.pid, windowID: t.windowID)
        var attempt = 0
        while !key && attempt < 3 {
            attempt += 1
            sent = WindowFocuser.ensureKey(pid: t.pid, windowID: t.windowID, axWindow: w.ax) || sent
            let until = monotonicMs() + 90
            repeat {
                usleep(8_000)
                key = WindowFocuser.isKey(pid: t.pid, windowID: t.windowID)
            } while !key && monotonicMs() < until
        }
        if key { hooks.evidence("window_made_key") }
        else if sent { hooks.warn("win:\(t.windowID) did not become its app's key window; input may be ignored") }
        else { hooks.warn("Could not make win:\(t.windowID) key without activating its app; input may be ignored") }
        return key
    }

    // MARK: Key window borrowed from the user

    /// An app has one key window. When the driver works in a window of an app the user also has
    /// windows of (a second browser window, say), making the driver's window key takes key
    /// status from the user's. Their window is remembered here and made key again:
    ///
    /// - at the end of the action, when the user is in that app right now, so their typing is
    ///   only misdirected for the length of one action;
    /// - the moment the user switches to that app, when they were elsewhere.
    ///
    /// It is not returned after every action regardless: a page that loses key status closes
    /// its menus and suggestion lists, which would undo what a click has just opened.
    private struct Loan { var userWindow: CGWindowID; var driverWindow: CGWindowID }
    private let loans = Locked<[pid_t: Loan]>([:])
    private let activationToken = Locked<Int?>(nil)

    private func noteLender(_ t: Target, hooks: Hooks) {
        guard let fw = AX.element(AX.app(t.pid), kAXFocusedWindowAttribute), let cur = AX.windowID(fw), cur != t.windowID,
              let theirs = windows.cgWindow(cur), let ours = windows.cgWindow(t.windowID),
              WindowService.display(for: theirs.bounds) != WindowService.display(for: ours.bounds) else {
            loans.withLock { if $0[t.pid] != nil { $0[t.pid]?.driverWindow = t.windowID } }
            return
        }
        loans.withLock { $0[t.pid] = Loan(userWindow: cur, driverWindow: t.windowID) }
        watchActivations()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid {
            hooks.warn("The user is working in another window of this app; keyboard focus inside the app is borrowed for this action and returned to their window afterwards")
        }
    }

    /// Returns key status to the user's window in the app they are working in. Called when an action ends.
    public func returnKeyWindowsToUser() {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let loan = loans.withLock({ $0.removeValue(forKey: front) }) else { return }
        giveBack(pid: front, loan)
    }

    private func giveBack(pid: pid_t, _ loan: Loan) {
        guard let w = try? windows.resolve(loan.userWindow) else { return }
        _ = WindowFocuser.ensureKey(pid: pid, windowID: loan.userWindow, axWindow: w.ax)
    }

    private func watchActivations() {
        activationToken.withLock { token in
            guard token == nil else { return }
            token = ActivationMonitor.shared.add { [weak self] app in self?.userArrived(in: app.processIdentifier) }
        }
    }

    private func userArrived(in pid: pid_t) {
        guard loans.get[pid] != nil else { return }
        // If they arrived by clicking one of the app's windows, that window is becoming key on
        // its own and must not be overridden; a moment later the app's answer tells which case this is.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.06) { [self] in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let loan = loans.withLock({ $0.removeValue(forKey: pid) }) else { return }
            if WindowFocuser.isKey(pid: pid, windowID: loan.driverWindow) { giveBack(pid: pid, loan) }
        }
    }

    public func press(_ el: AXUIElement) -> AXError { AX.perform(el, kAXPressAction) }

    public func clickText(_ el: AXUIElement, at p: CGPoint, count: Int, extend: Bool) -> CFRange? {
        SemanticPointer.clickText(el, at: p, count: count, extend: extend)
    }

    /// Drag-selection of text from `t.point` to `end`. Returns nil when the start is not on text.
    public func selectText(_ t: Target, to end: CGPoint) -> CFRange? {
        SemanticPointer.selectText(from: t.point, to: end, pid: t.pid)
    }

    public func mouseDown(_ t: Target, button: MouseButton, clickState: Int, flags: CGEventFlags, owner: InputOwner) throws {
        try poster.mouse(button.down, at: t.point, button: button, clickState: clickState, flags: flags, windowID: t.windowID, pid: t.pid)
        ledger.pressed(button: button, at: t.point, windowID: t.windowID, pid: t.pid, owner: owner)
    }

    public func mouseDragged(_ t: Target, button: MouseButton, flags: CGEventFlags) throws {
        try poster.mouse(button.dragged, at: t.point, button: button, clickState: 1, flags: flags, windowID: t.windowID, pid: t.pid)
    }

    public func mouseUp(_ t: Target, button: MouseButton, clickState: Int, flags: CGEventFlags, owner: InputOwner) throws {
        try poster.mouse(button.up, at: t.point, button: button, clickState: clickState, flags: flags, windowID: t.windowID, pid: t.pid)
        ledger.released(button: button, pid: t.pid, owner: owner)
    }

    // MARK: Whole gestures

    /// A complete click (`count` presses and releases at one point).
    public func click(_ t: Target, button: MouseButton, count: Int, flags: CGEventFlags, element: AXUIElement? = nil,
                      hooks: Hooks) async throws -> ClickOutcome {
        var route = self.route(t, button: button, count: count, flags: flags, element: element)
        if case .element(let el) = route {
            try await hooks.gate()
            let err = press(el)
            if err == .success {
                hooks.dispatched(1); hooks.confirm("ax_action_accepted")
                return ClickOutcome(method: "ax_press")
            }
            hooks.warn("AXPress failed (\(AX.describe(err))); falling back to a click at the element's position")
            route = self.route(t, button: button, count: count, flags: flags)
        }
        try await hooks.gate()
        makeKey(t, hooks: hooks)
        switch route {
        case .text(let el):
            if let r = clickText(el, at: t.point, count: count, extend: flags.contains(.maskShift)) {
                hooks.dispatched(1); hooks.confirm("ax_selection_set")
                return ClickOutcome(method: "ax_text_selection", selection: r)
            }
        case .control(let el, _):
            if press(el) == .success {
                hooks.dispatched(1); hooks.confirm("ax_action_accepted")
                return ClickOutcome(method: "ax_press_at_point")
            }
        case .element, .events: break
        }
        // The pointer arrives before it presses, as a real one does: hover styles and handlers
        // that react to the pointer entering run first.
        try await hooks.gate()
        try poster.mouse(.mouseMoved, at: t.point, button: button, clickState: 0, flags: flags, windowID: t.windowID, pid: t.pid)
        try? await sleepMs(20)
        for i in 1...max(1, count) {
            try await hooks.gate()
            try mouseDown(t, button: button, clickState: i, flags: flags, owner: hooks.owner)
            hooks.dispatched(1)
            try? await sleepMs(35)
            try mouseUp(t, button: button, clickState: i, flags: flags, owner: hooks.owner)
            hooks.dispatched(1)
            if i < count { try? await sleepMs(40) }
        }
        return ClickOutcome(method: "events")
    }

    /// Scrolls with wheel events. Some apps (AppKit text views among them) ignore wheel events
    /// sent to a background process: only when the scroll position provably did not move, the
    /// same distance is applied through the scroll bar, so the scroll still happens exactly once.
    /// `dx`/`dy` are wheel lines per event, sent `repeats` times; `settle` waits for the app to react.
    ///
    /// Scrolling never changes which window is key. A wheel event goes to the view under the
    /// pointer position it carries, whichever window has the keyboard, so there is nothing to
    /// take from a window the user may be typing in. The app only has to consider itself active.
    public func scroll(_ t: Target, dx: Int32, dy: Int32, repeats: Int = 1, flags: CGEventFlags,
                       hooks: Hooks, settle: @Sendable () async -> Void) async throws -> ScrollOutcome {
        let vertical = dy != 0
        let delta = vertical ? dy : dx
        let area = ScrollArea.at(pid: t.pid, t.point)
        let before = area?.position(vertical: vertical)
        try await hooks.gate()
        WindowFocuser.ensureBelievesActive(pid: t.pid)
        for i in 0..<max(1, repeats) {
            try await hooks.gate()
            try poster.scroll(at: t.point, dx: dx, dy: dy, flags: flags, windowID: t.windowID, pid: t.pid)
            hooks.dispatched(1)
            if i < repeats - 1 { try? await sleepMs(16) }
        }
        await settle()
        var after = area?.position(vertical: vertical)
        // Positive wheel deltas scroll towards the start (up/left).
        let atLimit = before.map { delta > 0 ? $0 <= 0.0001 : $0 >= 0.9999 } ?? false
        var method = "events"
        if let area, let p0 = before, after == p0, !atLimit {
            try await hooks.gate()
            let lineHeight = 16.0, linesPerTick = 3.0
            if let p = area.scroll(vertical: vertical, points: -Double(delta) * Double(max(1, repeats)) * linesPerTick * lineHeight) {
                hooks.dispatched(1); method = "events+ax_scrollbar"; after = p
                hooks.warn("The app ignored wheel events; scrolled the same distance through its scroll bar")
                await settle()
            }
        }
        return ScrollOutcome(method: method, before: before, after: after, atLimit: atLimit)
    }
}
