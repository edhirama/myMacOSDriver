import Foundation
import ApplicationServices
import CoreGraphics
import DriverProtocol

/// Where an action will land, after every validity check the driver owns.
public struct ResolvedPoint {
    public let global: CGPoint
    public let local: CGPoint
    public let pid: pid_t
    public let windowID: CGWindowID
    /// Set when the position came from a snapshot ref.
    public let element: AXUIElement?
    public let ref: String?
}

/// Processes that own system chrome. Synthetic input aimed at them cannot be delivered per-process
/// and is rejected instead of being sent somewhere else.
let systemUIOwners: Set<String> = ["Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center",
                                   "WindowManager", "loginwindow", "Spotlight", "TextInputMenuAgent"]

extension Driver {
    func requireWindowOnTarget(_ idString: String, _ ctx: CallContext, allowMinimized: Bool = true) throws -> ResolvedWindow {
        let w = try windows.resolve(try WindowService.parseWindowId(idString))
        guard windows.displayOf(w) == ctx.target.displayID else {
            throw DriverError(.windowNotOnTarget, "Window \(w.idString) is not on target '\(ctx.target.id)'",
                              details: ["window": .string(w.idString), "target": .string(ctx.target.id)])
        }
        if !allowMinimized, windows.isMinimized(w) {
            throw DriverError(.invalidArgument, "Window \(w.idString) is minimized; restore it with computer_window state=normal first")
        }
        return w
    }

    /// Maps a screenshot position to the screen. Rejects unknown ids, cross-target use,
    /// out-of-image coordinates, and window screenshots whose window was resized or closed.
    func mapScreenshotPoint(_ shotID: String, _ x: Double, _ y: Double, _ ctx: CallContext) throws -> (global: CGPoint, record: ScreenshotRecord) {
        let r = try screenshots.get(shotID)
        guard r.targetID == ctx.target.id else {
            throw DriverError(.invalidArgument, "Screenshot \(shotID) belongs to target '\(r.targetID)', not '\(ctx.target.id)'; targets are never switched automatically")
        }
        guard r.displayID == ctx.target.displayID else {
            throw DriverError(.staleScreenshot, "The target display changed since \(shotID) was taken; take a new screenshot")
        }
        guard x >= 0, y >= 0, x < Double(r.pixelSize.width), y < Double(r.pixelSize.height) else {
            throw DriverError(.outOfBounds, "(\(x), \(y)) is outside screenshot \(shotID) (\(Int(r.pixelSize.width))x\(Int(r.pixelSize.height)))")
        }
        let offset = CGPoint(x: x / Double(r.scale), y: y / Double(r.scale))
        let geo = ctx.target.geometry
        if let wid = r.windowID, let captured = r.windowFrame {
            guard let info = windows.cgWindow(wid), info.isOnScreen else {
                throw DriverError(.unknownWindow, "The window in screenshot \(shotID) is closed or hidden")
            }
            let now = info.bounds
            if abs(now.width - captured.width) > 1 || abs(now.height - captured.height) > 1 {
                throw DriverError(.staleScreenshot, "The window in \(shotID) was resized since capture; take a new screenshot")
            }
            if now.origin != captured.origin { ctx.warn("Window moved since \(shotID); position re-mapped to its current frame") }
            return (CGPoint(x: now.minX + offset.x, y: now.minY + offset.y), r)
        }
        let local = CGPoint(x: r.origin.x + offset.x, y: r.origin.y + offset.y)
        return (geo.toGlobal(local), r)
    }

    /// The window that would receive a real click at `global`, front to back.
    func hitTest(_ global: CGPoint, on display: CGDirectDisplayID) throws -> (pid: pid_t, windowID: CGWindowID, owner: String) {
        guard CGDisplayBounds(display).contains(global) else {
            throw DriverError(.outOfBounds, "Point is outside the target display")
        }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in windows.cgWindows(onScreenOnly: true) where w.alpha > 0 && w.bounds.contains(global) {
            if w.pid == me { continue }
            if systemUIOwners.contains(w.ownerName) {
                if w.layer == 0 { continue }
                throw DriverError(.unsupported, "The point is over system UI (\(w.ownerName)), which cannot receive per-application input",
                                  details: ["owner": .string(w.ownerName), "layer": .number(Double(w.layer))])
            }
            return (w.pid, w.id, w.ownerName)
        }
        throw DriverError(.outOfBounds, "There is no application window at that point (empty desktop)")
    }

    func resolvePosition(_ pos: PositionArg, _ ctx: CallContext) throws -> ResolvedPoint {
        let geo = ctx.target.geometry
        switch pos {
        case .screenshot(let id, let x, let y):
            let (global, rec) = try mapScreenshotPoint(id, x, y, ctx)
            let hit = try hitTest(global, on: ctx.target.displayID)
            if let wid = rec.windowID, hit.windowID != wid {
                guard let shotWin = windows.cgWindow(wid), shotWin.pid == hit.pid else {
                    throw DriverError(.actionFailed, "That point of window win:\(wid) is covered by another app's window (\(hit.owner)); input would reach the wrong target",
                                      details: ["covering_window": .string(WindowService.idString(hit.windowID))])
                }
            }
            return ResolvedPoint(global: global, local: geo.toLocal(global), pid: hit.pid, windowID: hit.windowID, element: nil, ref: nil)

        case .ref(let ref):
            let e = try snapshots.refs.lookup(ref)
            guard let f = AX.frame(e.element), f.width > 0, f.height > 0 else {
                throw DriverError(.staleRef, "Element \(ref) has no on-screen frame (hidden or collapsed)")
            }
            guard let info = windows.cgWindow(e.windowID), info.isOnScreen,
                  WindowService.display(for: info.bounds) == ctx.target.displayID else {
                throw DriverError(.windowNotOnTarget, "Element \(ref) is not in a visible window on target '\(ctx.target.id)'")
            }
            // Click the visible part of the element: clip to its window and the display.
            let visible = f.intersection(info.bounds).intersection(geo.bounds)
            guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
                throw DriverError(.outOfBounds, "Element \(ref) is scrolled out of view")
            }
            let p = visible.center
            return ResolvedPoint(global: p, local: geo.toLocal(p), pid: e.pid, windowID: e.windowID, element: e.element, ref: ref)
        }
    }

    /// Validates that the input location set by the last click on this target is still the
    /// place keystrokes will go. Rejects (never redirects) if anything changed.
    func requireInputFocus(_ ctx: CallContext) throws -> InputFocus {
        guard let f = focus.get(ctx.target.id) else {
            throw DriverError(.noInputTarget, "No input location on target '\(ctx.target.id)'. Click the field first with computer_click")
        }
        guard let info = windows.cgWindow(f.windowID), info.isOnScreen,
              WindowService.display(for: info.bounds) == ctx.target.displayID else {
            focus.clear(ctx.target.id)
            throw DriverError(.noInputTarget, "The window clicked last (win:\(f.windowID)) is gone, hidden or off target; click again")
        }
        let app = AX.app(f.pid)
        if let fw = AX.element(app, kAXFocusedWindowAttribute), let fwid = AX.windowID(fw), fwid != f.windowID {
            // A sheet/dialog raised by the click is a legitimate input location; a different
            // document window is not.
            let role = AX.string(fw, kAXRoleAttribute), sub = AX.string(fw, kAXSubroleAttribute)
            let transient = role == kAXSheetRole || sub == kAXDialogSubrole || sub == kAXSystemDialogSubrole || sub == kAXFloatingWindowSubrole
            // A window of the same app on another display is the user's own (their second browser
            // window, say): key status inside the app is taken back for the action and returned
            // afterwards. Another window on this target is a different matter: then it is unclear
            // which one the script means.
            let elsewhere = windows.cgWindow(fwid).map { WindowService.display(for: $0.bounds) != ctx.target.displayID } ?? false
            if !transient && !elsewhere {
                throw DriverError(.noInputTarget, "Keyboard focus in that app moved to another window (win:\(fwid)); click the intended field again")
            }
        }
        if let el = f.element, !AX.isAlive(el) {
            focus.clear(ctx.target.id)
            throw DriverError(.noInputTarget, "The focused element from the last click no longer exists; click again")
        }
        return f
    }

    /// Records the input location after a successful click.
    func recordFocus(pid: pid_t, windowID: CGWindowID, ctx: CallContext, via: String) {
        let el = AX.element(AX.app(pid), kAXFocusedUIElementAttribute)
        focus.set(ctx.target.id, InputFocus(pid: pid, windowID: windowID, element: el, setAt: Date(), via: via))
    }

    // MARK: Resume guards (see CallContext.guardResume)

    /// A pointer action may continue after a takeover only if the same window is still what a
    /// click at that point would reach.
    func guardPointer(_ ctx: CallContext, pid: pid_t, windowID: CGWindowID, at global: CGPoint, element: AXUIElement? = nil) {
        let display = ctx.target.displayID
        ctx.guardResume { [self] in
            let frame = element.flatMap { AX.frame($0) }
            return { [self] in
                let hit = try? self.hitTest(global, on: display)
                guard let hit, hit.pid == pid, hit.windowID == windowID else {
                    throw DriverError(.targetChanged, "While the user had control, the window under the target point changed; observe again before continuing",
                                      details: ["window": .string(WindowService.idString(windowID))])
                }
                if let element, AX.frame(element) != frame {
                    throw DriverError(.targetChanged, "While the user had control, the target element moved or disappeared; take a new snapshot")
                }
            }
        }
    }

    /// Keyboard input may continue after a takeover only if the same element still has keyboard
    /// focus with the caret where the call left it. Otherwise the rest would land elsewhere.
    func guardKeyboard(_ ctx: CallContext, _ f: InputFocus) {
        let display = ctx.target.displayID
        ctx.guardResume { [self] in
            let app = AX.app(f.pid)
            let element = AX.element(app, kAXFocusedUIElementAttribute)
            let selection = element.flatMap { AXText.selectedRange($0) }
            return { [self] in
                func changed(_ what: String) -> DriverError {
                    DriverError(.targetChanged, "While the user had control, \(what); click the field again before sending more keys",
                                details: ["window": .string(WindowService.idString(f.windowID))])
                }
                guard let info = self.windows.cgWindow(f.windowID), info.isOnScreen, WindowService.display(for: info.bounds) == display else {
                    throw changed("the window receiving the keys was closed, hidden or moved off the target")
                }
                let now = AX.element(app, kAXFocusedUIElementAttribute)
                switch (element, now) {
                case (.some(let a), .some(let b)) where CFEqual(a, b): break
                case (nil, nil): break
                default: throw changed("keyboard focus moved to another element")
                }
                if let selection, let now, let s = AXText.selectedRange(now), s.location != selection.location || s.length != selection.length {
                    throw changed("the caret or selection moved")
                }
                if let w = try? self.windows.resolve(f.windowID), AX.string(w.ax, kAXRoleAttribute) == kAXWindowRole {
                    _ = WindowFocuser.ensureKey(pid: f.pid, windowID: f.windowID, axWindow: w.ax)
                }
            }
        }
    }

    /// A window action may continue after a takeover only if the window still exists on the target.
    func guardWindow(_ ctx: CallContext, _ w: ResolvedWindow) {
        let display = ctx.target.displayID
        ctx.guardResume { [self] in
            return { [self] in
                guard let now = try? self.windows.resolve(w.id), self.windows.displayOf(now) == display else {
                    throw DriverError(.targetChanged, "While the user had control, window \(w.idString) was closed or moved off the target",
                                      details: ["window": .string(w.idString)])
                }
            }
        }
    }
}
