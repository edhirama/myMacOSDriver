import Foundation
import ApplicationServices
import CoreGraphics
import DriverProtocol

/// Snapshot of observable state used to tell "dispatched" apart from "confirmed".
struct Observation {
    var screen: UInt64?
    var focused: AXUIElement?
    var value: String?
    var windowFrame: CGRect?

    static func take(_ d: Driver, pid: pid_t, display: CGDirectDisplayID, element: AXUIElement? = nil, window: AXUIElement? = nil) async -> Observation {
        let focused = AX.element(AX.app(pid), kAXFocusedUIElementAttribute)
        let valueEl = element ?? focused
        return Observation(screen: await d.capture.displayFingerprint(display), focused: focused,
                           value: valueEl.flatMap { AX.string($0, kAXValueAttribute) },
                           windowFrame: window.flatMap { AX.frame($0) })
    }

    /// Records evidence of change between two observations.
    static func compare(_ a: Observation, _ b: Observation, _ ctx: CallContext) {
        if let x = a.screen, let y = b.screen, x != y { ctx.confirm("screen_changed") }
        switch (a.focused, b.focused) {
        case (nil, .some): ctx.confirm("focus_changed")
        case (.some(let x), .some(let y)) where !CFEqual(x, y): ctx.confirm("focus_changed")
        default: break
        }
        if a.value != b.value, b.value != nil { ctx.confirm("ax_value_changed") }
        if let f1 = a.windowFrame, let f2 = b.windowFrame, f1 != f2 { ctx.confirm("window_frame_changed") }
    }
}

/// Watches one action's effect from start to finish: a before/after comparison plus the app's
/// own accessibility notifications in between.
struct EffectProbe {
    let before: Observation
    let watch: AXNotificationWatch?
    let pid: pid_t
    let display: CGDirectDisplayID
    let element: AXUIElement?
    let window: AXUIElement?

    static func begin(_ d: Driver, pid: pid_t, display: CGDirectDisplayID, element: AXUIElement? = nil, window: AXUIElement? = nil) async -> EffectProbe {
        let before = await Observation.take(d, pid: pid, display: display, element: element, window: window)
        return EffectProbe(before: before, watch: AXNotificationWatch(pid: pid), pid: pid, display: display, element: element, window: window)
    }

    /// Waits for the app to finish reacting. If the app announces its reaction, that is the
    /// signal and the wait ends once it goes quiet; otherwise fall back to watching the screen.
    func settle(_ d: Driver, budgetMs: Int) async {
        let start = monotonicMs()
        if let watch, await watch.waitForEvent(timeoutMs: min(150, budgetMs)) {
            await watch.waitQuiet(budgetMs: max(0, budgetMs - (monotonicMs() - start)))
            _ = await d.capture.waitForSettle(display, budgetMs: min(300, max(100, budgetMs - (monotonicMs() - start))))
        } else {
            _ = await d.capture.waitForSettle(display, budgetMs: max(100, budgetMs - (monotonicMs() - start)))
        }
    }

    /// Settles, then records everything observed as evidence on the call. Returns the "after" state.
    @discardableResult
    func finish(_ d: Driver, _ ctx: CallContext, budgetMs: Int) async -> Observation {
        await settle(d, budgetMs: budgetMs)
        let after = await Observation.take(d, pid: pid, display: display, element: element, window: window)
        Observation.compare(before, after, ctx)
        record(ctx)
        return after
    }

    func record(_ ctx: CallContext) {
        guard let watch else { return }
        let e = watch.evidence
        for n in e.names { ctx.evidence(n) }
        if e.confirms { ctx.confirm("ax_notification") }
        watch.stop()
    }
}

/// The scroll area under a point, read through accessibility: used both as evidence that a
/// scroll happened and as a fallback for apps that ignore synthetic wheel events.
struct ScrollArea {
    let element: AXUIElement

    static func at(pid: pid_t, _ p: CGPoint) -> ScrollArea? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AX.app(pid), Float(p.x), Float(p.y), &el) == .success, var cur = el else { return nil }
        for _ in 0..<12 {
            if AX.string(cur, kAXRoleAttribute) == kAXScrollAreaRole { return ScrollArea(element: cur) }
            guard let parent = AX.element(cur, kAXParentAttribute) else { break }
            cur = parent
        }
        return nil
    }

    func bar(vertical: Bool) -> AXUIElement? {
        AX.element(element, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute)
    }

    /// Scroll-bar value in 0...1, or nil when that axis cannot scroll.
    func position(vertical: Bool) -> Double? {
        guard let b = bar(vertical: vertical) else { return nil }
        let (e, v) = AX.raw(b, kAXValueAttribute)
        return e == .success ? (v as? NSNumber)?.doubleValue : nil
    }

    /// Scrolls by `points` of content through the scroll bar's AX value. Returns the new position.
    func scroll(vertical: Bool, points: Double) -> Double? {
        guard let b = bar(vertical: vertical), AX.isSettable(b, kAXValueAttribute), let cur = position(vertical: vertical),
              let visible = AX.frame(element) else { return nil }
        // Document size: the largest child of the scroll area (its document/content view).
        let content = AX.elements(element, kAXChildrenAttribute).compactMap { AX.frame($0) }
            .map { vertical ? $0.height : $0.width }.max() ?? 0
        let range = content - (vertical ? visible.height : visible.width)
        guard range > 1 else { return nil }
        let next = min(1, max(0, cur + points / Double(range)))
        AX.set(b, kAXValueAttribute, NSNumber(value: next))
        return position(vertical: vertical)
    }
}

func pointJSON(_ p: CGPoint) -> JSONValue { ["x": .number(p.x.rounded()), "y": .number(p.y.rounded())] }

func elementSummary(_ el: AXUIElement?) -> JSONValue {
    guard let el else { return .null }
    var o: [String: JSONValue] = ["role": JSONValue(AX.string(el, kAXRoleAttribute))]
    if let t = AX.string(el, kAXTitleAttribute) ?? AX.string(el, kAXDescriptionAttribute), !t.isEmpty { o["name"] = .string(String(t.prefix(120))) }
    return .object(o)
}

enum InputTools {
    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]

    // MARK: click

    static func click(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_click",
                 summary: "Clicks at a screenshot position or on an element ref. A valid click also sets where typed text and keys will go.",
                 mutating: true, params: [
            Param("in", .string, "Screenshot id the x/y position refers to. Use with x and y; not together with ref."),
            Param("x", .number, "X in the screenshot's pixels, from its left edge."),
            Param("y", .number, "Y in the screenshot's pixels, from its top edge."),
            Param("ref", .string, "Element ref from computer_snapshot. Use instead of in/x/y, never together."),
            Param("button", .choice(["left", "middle", "right"]), "Mouse button. Default: left."),
            Param("count", .integer(min: 1, max: 3), "Number of clicks: 2 selects a word in text, 3 a line. Default: 1."),
            Param("keys", .modifiers, "Modifier keys held during the action: shift, ctrl, alt, super."),
        ], defaultTimeoutMs: 15_000) { ctx, a in
            let pos = try PositionArg.parse(a)!
            let button = MouseButton(rawValue: try a.oneOf("button", ["left", "middle", "right"], default: "left")!)!
            let count = try a.positiveInt("count", default: 1, max: 3)!
            let mods = try a.modifiers()
            let rp = try d.resolvePosition(pos, ctx)
            d.guardPointer(ctx, pid: rp.pid, windowID: rp.windowID, at: rp.global, element: rp.element)
            let display = ctx.target.displayID
            let focusGuard = FocusGuard(watching: rp.pid)
            let probe = await EffectProbe.begin(d, pid: rp.pid, display: display)

            let outcome = try await d.router.click(InputRouter.Target(pid: rp.pid, windowID: rp.windowID, point: rp.global),
                                                   button: button, count: count, flags: mods.flags, element: rp.element, hooks: ctx.hooks)
            let method = outcome.method
            var selection: JSONValue = .null
            if let r = outcome.selection { selection = ["location": .number(Double(r.location)), "length": .number(Double(r.length))] }
            // Background apps may not move keyboard focus on a synthetic click; for text inputs
            // addressed by ref, set AX focus explicitly so typing has a target.
            if method == "events", let el = rp.element, let role = AX.string(el, kAXRoleAttribute), textRoles.contains(role),
               AX.bool(el, kAXFocusedAttribute) != true, AX.isSettable(el, kAXFocusedAttribute) {
                if AX.set(el, kAXFocusedAttribute, kCFBooleanTrue) == .success { ctx.evidence("ax_focus_set") }
            }
            if let w = focusGuard.restore(targetPid: rp.pid) { ctx.warn(w) }
            let after = await probe.finish(d, ctx, budgetMs: 700)
            d.recordFocus(pid: rp.pid, windowID: rp.windowID, ctx: ctx, via: method)

            var out = appJSON(rp.pid)
            out["window"] = .string(WindowService.idString(rp.windowID))
            out["point"] = pointJSON(rp.local)
            out["method"] = .string(method)
            out["button"] = .string(button.rawValue)
            out["count"] = .number(Double(count))
            out["keys"] = .array(mods.map { .string($0.rawValue) })
            if let r = rp.ref { out["ref"] = .string(r) }
            out["focused_element"] = elementSummary(after.focused)
            if !selection.isNull { out["selection"] = selection }
            return .object(out)
        }
    }

    // MARK: drag

    static func drag(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_drag",
                 summary: "Presses at the first path point, moves through the rest, and releases at the last.",
                 mutating: true, params: [
            Param("in", .string, required: true, "Screenshot id the path points refer to."),
            Param("path", .points(min: 2, max: 500), required: true, "Points to drag through, in the screenshot's pixels."),
            Param("button", .choice(["left", "middle", "right"]), "Mouse button. Default: left."),
            Param("keys", .modifiers, "Modifier keys held during the action: shift, ctrl, alt, super."),
        ], defaultTimeoutMs: 30_000) { ctx, a in
            let shot = try a.requiredString("in")
            let pts = try a.points("path", min: 2)
            let button = MouseButton(rawValue: try a.oneOf("button", ["left", "middle", "right"], default: "left")!)!
            let flags = try a.modifiers().flags
            let globals = try pts.map { try d.mapScreenshotPoint(shot, Double($0.x), Double($0.y), ctx).global }
            let bounds = CGDisplayBounds(ctx.target.displayID)
            guard globals.allSatisfy({ bounds.contains($0) }) else {
                throw DriverError(.outOfBounds, "Every path point must be on the target display")
            }
            let hit = try d.hitTest(globals[0], on: ctx.target.displayID)
            d.guardPointer(ctx, pid: hit.pid, windowID: hit.windowID, at: globals[0])
            let start = InputRouter.Target(pid: hit.pid, windowID: hit.windowID, point: globals[0])
            let win = try? d.windows.resolve(hit.windowID)
            let frameBefore = win.flatMap { AX.frame($0.ax) }
            // Title bar: the top strip of the window where the element under the pointer is the window itself or chrome.
            var onTitleBar = false
            if let f = frameBefore, globals[0].y - f.minY < 30 {
                var el: AXUIElement?
                AXUIElementCopyElementAtPosition(AX.app(hit.pid), Float(globals[0].x), Float(globals[0].y), &el)
                let role = el.flatMap { AX.string($0, kAXRoleAttribute) }
                onTitleBar = role == nil || role == kAXWindowRole || role == kAXToolbarRole || role == kAXStaticTextRole || role == kAXGroupRole
            }
            // Drag that starts on editable text selects that text (through accessibility, since a
            // background app would treat the press as an activation click).
            if button == .left, !onTitleBar {
                try await ctx.gate()
                try? prepareWindow(d, ctx, pid: hit.pid, windowID: hit.windowID)
                if let r = d.router.selectText(start, to: globals[globals.count - 1]) {
                    ctx.dispatched(); ctx.confirm("ax_selection_set")
                    d.recordFocus(pid: hit.pid, windowID: hit.windowID, ctx: ctx, via: "ax_text_selection")
                    var out = appJSON(hit.pid)
                    out["window"] = .string(WindowService.idString(hit.windowID))
                    out["method"] = "ax_text_selection"
                    out["title_bar"] = false
                    out["points"] = .number(Double(globals.count))
                    out["selection"] = ["location": .number(Double(r.location)), "length": .number(Double(r.length))]
                    return .object(out)
                }
            }
            let focusGuard = FocusGuard(watching: hit.pid)
            let probe = await EffectProbe.begin(d, pid: hit.pid, display: ctx.target.displayID, window: win?.ax)

            try await ctx.gate()
            try? prepareWindow(d, ctx, pid: hit.pid, windowID: hit.windowID)
            try d.router.mouseDown(start, button: button, clickState: 1, flags: flags, owner: ctx.inputOwner)
            ctx.dispatched()
            var last = globals[0]
            for p in globals.dropFirst() {
                let dist = hypot(p.x - last.x, p.y - last.y)
                let steps = max(1, Int(dist / 8))
                for s in 1...steps {
                    try await ctx.gate()
                    let t = CGFloat(s) / CGFloat(steps)
                    let q = CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t)
                    try d.router.mouseDragged(InputRouter.Target(pid: hit.pid, windowID: hit.windowID, point: q), button: button, flags: flags)
                    ctx.dispatched()
                    try? await sleepMs(8)
                }
                last = p
            }
            try d.router.mouseUp(InputRouter.Target(pid: hit.pid, windowID: hit.windowID, point: last), button: button, clickState: 1, flags: flags, owner: ctx.inputOwner)
            ctx.dispatched()

            await probe.settle(d, budgetMs: 700)
            var method = "events"
            if onTitleBar, let w = win, let f0 = frameBefore, AX.frame(w.ax) == f0 {
                // The window server did not move the window for synthetic events; apply the same
                // displacement through accessibility so the requested move still happens once.
                let delta = CGPoint(x: last.x - globals[0].x, y: last.y - globals[0].y)
                try await ctx.gate()
                if AX.setPosition(w.ax, CGPoint(x: f0.minX + delta.x, y: f0.minY + delta.y)) == .success {
                    ctx.dispatched(); method = "events+ax_window_move"
                    ctx.warn("Title-bar drag events did not move the window; moved it by the same offset through accessibility")
                }
            }
            if let w = focusGuard.restore(targetPid: hit.pid) { ctx.warn(w) }
            let after = await probe.finish(d, ctx, budgetMs: 300)

            var out = appJSON(hit.pid)
            out["window"] = .string(WindowService.idString(hit.windowID))
            out["method"] = .string(method)
            out["title_bar"] = .bool(onTitleBar)
            out["points"] = .number(Double(globals.count))
            if let f = after.windowFrame { out["window_frame"] = frameJSON(ctx.target.geometry.toLocal(f)) }
            return .object(out)
        }
    }

    // MARK: scroll

    static func scroll(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_scroll",
                 summary: "Scrolls the content under a position.",
                 mutating: true, params: [
            Param("in", .string, "Screenshot id the x/y position refers to. Use with x and y; not together with ref."),
            Param("x", .number, "X in the screenshot's pixels, from its left edge."),
            Param("y", .number, "Y in the screenshot's pixels, from its top edge."),
            Param("ref", .string, "Element ref from computer_snapshot. Use instead of in/x/y, never together."),
            Param("direction", .choice(["up", "down", "left", "right"]), required: true, "Direction to scroll."),
            Param("amount", .integer(min: 1, max: 200), required: true, "Wheel ticks to scroll."),
            Param("keys", .modifiers, "Modifier keys held during the action: shift, ctrl, alt, super."),
        ], defaultTimeoutMs: 15_000) { ctx, a in
            let pos = try PositionArg.parse(a)!
            guard let dir = try a.oneOf("direction", ["up", "down", "left", "right"]) else {
                throw DriverError(.invalidArgument, "computer_scroll requires 'direction'")
            }
            guard let amount = try a.positiveInt("amount", max: 200) else {
                throw DriverError(.invalidArgument, "computer_scroll requires 'amount' (positive integer wheel ticks)")
            }
            let flags = try a.modifiers().flags
            let rp = try d.resolvePosition(pos, ctx)
            d.guardPointer(ctx, pid: rp.pid, windowID: rp.windowID, at: rp.global)
            let (dx, dy): (Int32, Int32) = { switch dir {
                case "up": return (0, 1); case "down": return (0, -1); case "left": return (1, 0); default: return (-1, 0) } }()
            let display = ctx.target.displayID
            let probe = await EffectProbe.begin(d, pid: rp.pid, display: display)
            let o = try await d.router.scroll(InputRouter.Target(pid: rp.pid, windowID: rp.windowID, point: rp.global),
                                              dx: dx, dy: dy, repeats: amount, flags: flags, hooks: ctx.hooks) {
                await probe.settle(d, budgetMs: 500)
            }
            let (method, posBefore, posAfter, atLimit) = (o.method, o.before, o.after, o.atLimit)
            await probe.finish(d, ctx, budgetMs: 200)
            if let a = posBefore, let b = posAfter, a != b { ctx.confirm("scroll_position_changed") }
            if atLimit { ctx.warn("Already at the \(dir) scroll limit") }
            else if !ctx.snapshot.confirmed { ctx.warn("No visible change was observed") }
            var out = appJSON(rp.pid)
            out["window"] = .string(WindowService.idString(rp.windowID))
            out["point"] = pointJSON(rp.local)
            out["direction"] = .string(dir)
            out["ticks"] = .number(Double(amount))
            out["method"] = .string(method)
            if let p = posAfter { out["position"] = .number((p * 1000).rounded() / 1000) }
            return .object(out)
        }
    }

    // MARK: type

    static func type(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_type",
                 summary: "Types text at the input location set by the last valid click on the target.",
                 mutating: true, params: [
            Param("text", .string, required: true, "Text to type, up to 20000 characters. A newline presses Return."),
        ], defaultTimeoutMs: 60_000) { ctx, a in
            let text = try a.requiredString("text").replacingOccurrences(of: "\r\n", with: "\n")
            guard !text.isEmpty else { throw DriverError(.invalidArgument, "'text' must not be empty") }
            guard text.count <= 20_000 else { throw DriverError(.invalidArgument, "'text' is limited to 20000 characters per call") }
            let f = try d.requireInputFocus(ctx)
            d.guardKeyboard(ctx, f)
            try await ctx.gate()
            try prepareWindow(d, ctx, pid: f.pid, windowID: f.windowID)
            let focusGuard = FocusGuard(watching: f.pid)
            let probe = await EffectProbe.begin(d, pid: f.pid, display: ctx.target.displayID, element: f.element)

            // Exactly once: every chunk is sent once, never retried. On interruption the response
            // reports how much was typed.
            var typed = 0
            let total = text.count
            do {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for (li, line) in lines.enumerated() {
                    var chunk = ""
                    for ch in line {
                        if chunk.utf16.count + ch.utf16.count > 16 {
                            try await ctx.gate(); try d.poster.text(chunk, pid: f.pid); ctx.dispatched(); typed += chunk.count; chunk = ""
                            try? await sleepMs(6)
                        }
                        chunk.append(ch)
                    }
                    if !chunk.isEmpty { try await ctx.gate(); try d.poster.text(chunk, pid: f.pid); ctx.dispatched(); typed += chunk.count; try? await sleepMs(6) }
                    if li < lines.count - 1 {
                        try await ctx.gate()
                        try d.poster.key(0x24, down: true, flags: [], pid: f.pid)
                        d.inputLedger.pressed(key: 0x24, pid: f.pid, owner: ctx.inputOwner)
                        try d.poster.key(0x24, down: false, flags: [], pid: f.pid)
                        d.inputLedger.released(key: 0x24, pid: f.pid, owner: ctx.inputOwner)
                        ctx.dispatched(); typed += 1
                        try? await sleepMs(10)
                    }
                }
            } catch {
                ctx.warn("Typed \(typed) of \(total) characters before stopping; the rest was not sent")
                throw error
            }
            if let w = focusGuard.restore(targetPid: f.pid) { ctx.warn(w) }
            let after = await probe.finish(d, ctx, budgetMs: 600)
            if let v = after.value, let last = text.split(separator: "\n").last, v.contains(last) { ctx.confirm("text_present_in_value") }
            refreshFocusElement(d, ctx, f)
            var out = appJSON(f.pid)
            out["window"] = .string(WindowService.idString(f.windowID))
            out["characters"] = .number(Double(typed))
            out["element"] = elementSummary(f.element)
            return .object(out)
        }
    }

    // MARK: key

    static func key(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_key",
                 summary: "Presses a key or key combination at the input location set by the last valid click.",
                 mutating: true, params: [
            Param("key", .string, required: true, "Key or combination, for example Return, ArrowLeft, F5 or super+a."),
            Param("repeat", .integer(min: 1, max: 200), "Times to press it. Default: 1."),
        ], defaultTimeoutMs: 30_000) { ctx, a in
            let spec = try KeySpec.parse(try a.requiredString("key"))
            let repeatCount = try a.positiveInt("repeat", default: 1, max: 200)!
            let f = try d.requireInputFocus(ctx)
            d.guardKeyboard(ctx, f)
            try await ctx.gate()
            try prepareWindow(d, ctx, pid: f.pid, windowID: f.windowID)
            let focusGuard = FocusGuard(watching: f.pid)
            let probe = await EffectProbe.begin(d, pid: f.pid, display: ctx.target.displayID, element: f.element)
            var done = 0
            do {
                for _ in 0..<repeatCount {
                    try await ctx.gate()
                    var flags = CGEventFlags()
                    for m in spec.modifiers {
                        flags.insert(m.flag)
                        try d.poster.key(m.keyCode, down: true, flags: flags, pid: f.pid)
                        d.inputLedger.pressed(key: m.keyCode, pid: f.pid, owner: ctx.inputOwner)
                    }
                    if let code = spec.keyCode {
                        try d.poster.key(code, down: true, flags: flags, pid: f.pid)
                        d.inputLedger.pressed(key: code, pid: f.pid, owner: ctx.inputOwner)
                        try d.poster.key(code, down: false, flags: flags, pid: f.pid)
                        d.inputLedger.released(key: code, pid: f.pid, owner: ctx.inputOwner)
                    }
                    for m in spec.modifiers.reversed() {
                        flags.remove(m.flag)
                        try d.poster.key(m.keyCode, down: false, flags: flags, pid: f.pid)
                        d.inputLedger.released(key: m.keyCode, pid: f.pid, owner: ctx.inputOwner)
                    }
                    ctx.dispatched(); done += 1
                    try? await sleepMs(15)
                }
            } catch {
                ctx.warn("Pressed \(spec.display) \(done) of \(repeatCount) times before stopping")
                throw error
            }
            if let w = focusGuard.restore(targetPid: f.pid) { ctx.warn(w) }
            let after = await probe.finish(d, ctx, budgetMs: 700)
            refreshFocusElement(d, ctx, f)
            var out = appJSON(f.pid)
            out["window"] = .string(WindowService.idString(f.windowID))
            out["key"] = .string(spec.display)
            out["repeat"] = .number(Double(done))
            out["focused_element"] = elementSummary(after.focused)
            return .object(out)
        }
    }

    /// Keys posted to an app go to whichever window the app considers key. If the intended
    /// window cannot be made key, the keys would be dropped or, worse, land in another window of
    /// that app (possibly one the user is working in), so nothing is sent.
    static func prepareWindow(_ d: Driver, _ ctx: CallContext, pid: pid_t, windowID: CGWindowID) throws {
        if d.router.makeKey(InputRouter.Target(pid: pid, windowID: windowID, point: .zero), hooks: ctx.hooks) == false {
            throw DriverError(.noInputTarget, "win:\(windowID) could not be made the key window of its app, so keys would not reach it. Click inside the window by coordinates, then try again",
                              details: ["window": .string(WindowService.idString(windowID))])
        }
    }

    /// Keyboard actions can legitimately move focus within the same window (Tab, Return in a
    /// form). Follow it there, but never across windows.
    static func refreshFocusElement(_ d: Driver, _ ctx: CallContext, _ f: InputFocus) {
        let app = AX.app(f.pid)
        guard let fw = AX.element(app, kAXFocusedWindowAttribute), AX.windowID(fw) == f.windowID else { return }
        d.focus.set(ctx.target.id, InputFocus(pid: f.pid, windowID: f.windowID, element: AX.element(app, kAXFocusedUIElementAttribute),
                                              setAt: Date(), via: f.via))
    }
}
