import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import DriverProtocol

enum WindowTools {
    // MARK: open

    static func resolveApp(_ s: String) throws -> (url: URL?, running: NSRunningApplication?) {
        if let pid = WindowService.parseAppId(s) {
            guard let r = NSRunningApplication(processIdentifier: pid) else { throw DriverError(.unknownApp, "No running app \(s)") }
            return (r.bundleURL, r)
        }
        if s.hasSuffix(".app") || s.hasPrefix("/") {
            let url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw DriverError(.unknownApp, "No application at \(s)") }
            return (url, NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL })
        }
        if s.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s) {
            return (url, NSRunningApplication.runningApplications(withBundleIdentifier: s).first)
        }
        if let r = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.caseInsensitiveCompare(s) == .orderedSame && $0.activationPolicy == .regular }) {
            return (r.bundleURL, r)
        }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                    NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(s + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return (url, nil) }
        }
        throw DriverError(.unknownApp, "Could not find an application named '\(s)'. Use a name, bundle id, .app path or app:<pid>")
    }

    static func open(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_open",
                 summary: "Opens an app or a file on the target display, or asks a running app for a new window or document.",
                 mutating: true, params: [
            Param("app", .string, "App name, bundle id or path to the .app."),
            Param("path", .string, "File to open, with its default app or with app. Not together with intent."),
            Param("intent", .choice(["new_window", "new_document"]), "Ask the app for a new window or document. Needs app; not together with path."),
        ], defaultTimeoutMs: 30_000) { ctx, a in
            let appArg = try a.string("app")
            let pathArg = try a.string("path")
            let intent = try a.oneOf("intent", ["new_window", "new_document"])
            guard appArg != nil || pathArg != nil else { throw DriverError(.invalidArgument, "computer_open requires 'app' or 'path'") }
            if intent != nil {
                guard appArg != nil else { throw DriverError(.invalidArgument, "'intent' requires 'app'") }
                guard pathArg == nil else { throw DriverError(.invalidArgument, "'intent' cannot be combined with 'path'") }
            }
            var fileURL: URL?
            if let p = pathArg {
                let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else { throw DriverError(.invalidArgument, "No file at '\(p)'") }
                fileURL = url
            }
            var appURL: URL?, running: NSRunningApplication?
            if let s = appArg { (appURL, running) = try resolveApp(s) }

            let display = ctx.target.displayID
            let existing = Set(d.windows.cgWindows(onScreenOnly: false).map { $0.id })
            let focusGuard = FocusGuard(watching: running?.processIdentifier)

            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.addsToRecentItems = false
            cfg.createsNewApplicationInstance = false
            cfg.promptsUserIfNeeded = false
            cfg.hides = false

            try await ctx.gate()
            let launched: NSRunningApplication
            let wasRunning: Bool
            do {
                if let fileURL {
                    if let appURL {
                        wasRunning = running != nil
                        launched = try await NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: cfg)
                    } else {
                        guard let def = NSWorkspace.shared.urlForApplication(toOpen: fileURL) else {
                            throw DriverError(.unknownApp, "No application can open '\(fileURL.path)'")
                        }
                        wasRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleURL == def }
                        launched = try await NSWorkspace.shared.open(fileURL, configuration: cfg)
                    }
                } else if let r = running, intent != nil {
                    launched = r; wasRunning = true
                } else {
                    wasRunning = running != nil
                    launched = try await NSWorkspace.shared.openApplication(at: appURL!, configuration: cfg)
                }
            } catch let e as DriverError { throw e } catch {
                throw DriverError(.actionFailed, "Open failed: \(error.localizedDescription)")
            }
            if !(intent != nil && wasRunning) { ctx.dispatched() }
            let pid = launched.processIdentifier
            focusGuard.watch(pid)

            var menuUsed: JSONValue = .null
            if let intent {
                // Wait for the app's menu bar to be available after a cold launch.
                var match: MenuInvoker.Match?
                let until = monotonicMs() + 8_000
                while match == nil && monotonicMs() < until {
                    match = MenuInvoker.find(MenuInvoker.Command(rawValue: intent)!, pid: pid)
                    if match == nil { try await sleepMs(200) }
                }
                guard let m = match else {
                    throw DriverError(.unsupported, "\(launched.localizedName ?? "The app") has no enabled New Window / New Document menu command",
                                      details: ["app": .string(WindowService.appIdString(pid))])
                }
                try await ctx.gate()
                let err = AX.perform(m.item, kAXPressAction)
                guard err == .success else {
                    throw DriverError(.actionFailed, "Pressing menu item '\(m.title)' failed: \(AX.describe(err))")
                }
                ctx.dispatched()
                menuUsed = ["title": .string(m.title), "matched_by": .string(m.matchedBy)]
            }

            // Collect windows the app created: wait for new ones, then for the set to stabilise.
            var newIDs: [CGWindowID] = []
            let until = monotonicMs() + 6_000
            var stableSince = 0
            while monotonicMs() < until {
                try Task.checkCancellation()
                let ids = d.windows.cgWindows(onScreenOnly: false).filter { $0.pid == pid && $0.layer == 0 && !existing.contains($0.id) }.map { $0.id }
                let resolvable = ids.filter { (try? d.windows.resolve($0)) != nil }
                if resolvable != newIDs { newIDs = resolvable; stableSince = monotonicMs() }
                if !newIDs.isEmpty && monotonicMs() - stableSince > 500 { break }
                if newIDs.isEmpty && wasRunning && intent == nil && fileURL == nil && monotonicMs() - (until - 6_000) > 1_200 { break }
                try await sleepMs(120)
            }
            if let w = focusGuard.restore(targetPid: pid) { ctx.warn(w) }

            // Place created windows on the target. Pre-existing windows elsewhere are never moved.
            let area = WindowService.visibleFrame(of: display)
            let geo = ctx.target.geometry
            var results: [JSONValue] = []
            for (i, wid) in newIDs.enumerated() {
                guard let w = try? d.windows.resolve(wid) else { continue }
                let original = AX.frame(w.ax) ?? .null
                var placement = "already_on_target"
                if WindowService.display(for: original) != display {
                    try await ctx.gate()
                    let cascade = CGPoint(x: area.minX + 40 + CGFloat(i * 30), y: area.minY + 30 + CGFloat(i * 30))
                    let f = d.windows.move(w, into: area, preferredOrigin: cascade)
                    ctx.dispatched()
                    d.windows.recordPlacement(wid, pid: pid, original: original)
                    placement = (f.flatMap { WindowService.display(for: $0) } == display) ? "moved_to_target" : "move_failed"
                    if placement == "moved_to_target" { ctx.confirm("window_placed_on_target") }
                }
                d.windows.setHome(wid, display)
                let frame = AX.frame(w.ax) ?? original
                results.append(["window": .string(w.idString), "title": JSONValue(AX.string(w.ax, kAXTitleAttribute)),
                                "frame": frameJSON(geo.toLocal(frame)), "status": "created", "placement": .string(placement)])
            }
            if !newIDs.isEmpty {
                ctx.confirm("new_windows")
                // Report placement only once the window server agrees (its bounds lag AX moves).
                let settleUntil = monotonicMs() + 1_500
                while monotonicMs() < settleUntil {
                    let landed = newIDs.allSatisfy { id in
                        d.windows.cgWindow(id).map { !$0.isOnScreen || WindowService.display(for: $0.bounds) == display } ?? true
                    }
                    if landed { break }
                    try await sleepMs(80)
                }
            }
            // Nothing new: report the app's existing windows (reused), wherever they are.
            if results.isEmpty {
                for e in d.windows.windows(on: display) where e.window.pid == pid {
                    results.append(["window": .string(e.window.idString), "title": .string(e.title),
                                    "frame": frameJSON(geo.toLocal(e.frame)), "status": "reused", "placement": "already_on_target"])
                }
                for info in d.windows.cgWindows(onScreenOnly: true) where info.pid == pid && info.layer == 0
                    && WindowService.display(for: info.bounds) != display {
                    results.append(["window": .string(WindowService.idString(info.id)), "title": JSONValue(info.title),
                                    "status": "reused", "placement": "on_other_display_not_moved"])
                }
                if results.isEmpty { ctx.warn("The app opened but produced no window") }
            }
            var out = appJSON(pid)
            out["launched"] = .bool(!wasRunning)
            out["intent"] = JSONValue(intent)
            out["path"] = JSONValue(fileURL?.path)
            out["menu_item"] = menuUsed
            out["windows"] = .array(results)
            return .object(out)
        }
    }

    // MARK: window

    static func window(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_window",
                 summary: "Minimizes, maximizes, restores or resizes a window.",
                 mutating: true, params: [
            Param("window", .string, required: true, "Window to change (win:<id>)."),
            Param("state", .choice(["normal", "minimized", "maximized"]), "State to put the window in."),
            Param("frame", .frame, "New position and size in target-display points. Applies to state normal."),
        ], defaultTimeoutMs: 15_000) { ctx, a in
            let state = try a.oneOf("state", ["normal", "minimized", "maximized"])
            let frame = try a.frame("frame")
            guard state != nil || frame != nil else { throw DriverError(.invalidArgument, "computer_window requires 'state' or 'frame'") }
            if frame != nil, let s = state, s != "normal" {
                throw DriverError(.invalidArgument, "'frame' can only be combined with state 'normal'")
            }
            let w = try d.requireWindowOnTarget(try a.requiredString("window"), ctx)
            d.guardWindow(ctx, w)
            let geo = ctx.target.geometry
            let display = ctx.target.displayID
            let area = WindowService.visibleFrame(of: display)
            if let frame {
                guard geo.bounds.contains(geo.toGlobal(frame)) else {
                    throw DriverError(.outOfBounds, "frame must lie within the target display (0, 0, \(Int(geo.bounds.width)), \(Int(geo.bounds.height)))")
                }
            }
            if AX.bool(w.ax, "AXFullScreen") == true {
                throw DriverError(.unsupported, "Window \(w.idString) is in a separate full-screen Space; exit full screen first")
            }
            let before = AX.frame(w.ax)
            let wasMin = d.windows.isMinimized(w)
            // The app announces minimize/restore/move itself; react to that instead of sleeping.
            let watch = AXNotificationWatch(pid: w.pid)
            defer { watch?.stop() }
            func unminimize() async throws {
                if d.windows.isMinimized(w) {
                    try await ctx.gate()
                    AX.set(w.ax, kAXMinimizedAttribute, kCFBooleanFalse); ctx.dispatched()
                }
            }
            switch state {
            case "minimized":
                if !wasMin {
                    try await ctx.gate()
                    let e = AX.set(w.ax, kAXMinimizedAttribute, kCFBooleanTrue); ctx.dispatched()
                    if e != .success { ctx.warn("Setting AXMinimized returned AX error \(e.rawValue)") }
                }
            case "maximized":
                try await unminimize()
                if let f = AX.frame(w.ax), !ObserveTools.isMaximized(f, display) { d.windows.saveFrame(w.id, f) }
                try await ctx.gate()
                // Never AXFullScreen: that would create a separate Space.
                AX.setPosition(w.ax, area.origin); AX.setSize(w.ax, area.size); AX.setPosition(w.ax, area.origin)
                ctx.dispatched()
            default:
                try await unminimize()
                var dest: CGRect?
                if let frame { dest = geo.toGlobal(frame) }
                else if let f = AX.frame(w.ax), ObserveTools.isMaximized(f, display) { dest = d.windows.savedFrame(w.id) }
                if let dest {
                    try await ctx.gate()
                    AX.setPosition(w.ax, dest.origin); AX.setSize(w.ax, dest.size); AX.setPosition(w.ax, dest.origin)
                    ctx.dispatched()
                    if frame == nil { d.windows.clearSavedFrame(w.id) }
                }
            }
            // Read back what actually happened.
            // Minimize/restore animate; poll until the app reports the requested state.
            var minimized = d.windows.isMinimized(w)
            let wantMinimized = state == "minimized"
            let until = monotonicMs() + 2_000
            while state != nil && minimized != wantMinimized && monotonicMs() < until {
                let seen = watch?.count ?? 0
                if let watch { await watch.waitForEvent(after: seen, timeoutMs: 100) } else { try await sleepMs(100) }
                minimized = d.windows.isMinimized(w)
            }
            if wasMin && !minimized && !wantMinimized {
                // Restoring re-applies the frame after the animation; re-assert any explicit frame.
                try? await sleepMs(250)
                if let frame { AX.setPosition(w.ax, geo.toGlobal(frame).origin); AX.setSize(w.ax, frame.size) }
            }
            try? await sleepMs(150)
            let after = AX.frame(w.ax)
            let actual = minimized ? "minimized" : (after.map { ObserveTools.isMaximized($0, display) } == true ? "maximized" : "normal")
            if let s = state, s == actual { ctx.confirm("state_read_back") }
            else if let s = state {
                ctx.warn("The window did not reach state '\(s)'; it is '\(actual)'. The app or the system did not carry out the change")
                if s == "minimized", Capabilities.stageManagerOn {
                    ctx.warn("Stage Manager is on, and windows do not minimize while it is; see status.capabilities.stage_manager_off")
                }
            }
            if let frame, let after, abs(after.minX - geo.toGlobal(frame).minX) <= 2, abs(after.width - frame.width) <= 2,
               abs(after.minY - geo.toGlobal(frame).minY) <= 2, abs(after.height - frame.height) <= 2 {
                ctx.confirm("frame_read_back")
            } else if frame != nil {
                ctx.warn("The app adjusted the requested frame (size constraints); see 'frame' for the actual result")
            }
            if before != after { ctx.evidence("window_frame_changed") }
            if let watch { for n in watch.evidence.names { ctx.evidence(n) } }
            if state == nil && frame == nil { ctx.warn("Nothing to change") }
            return ["window": .string(w.idString), "state": .string(actual), "requested_state": JSONValue(state),
                    "frame": after.map { frameJSON(geo.toLocal($0)) } ?? .null]
        }
    }

    // MARK: close

    static func close(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_close",
                 summary: "Closes a window. If the app asks about unsaved changes, returns that prompt and its buttons without choosing one.",
                 mutating: true, params: [
            Param("window", .string, required: true, "Window to close (win:<id>)."),
        ], defaultTimeoutMs: 15_000) { ctx, a in
            let w = try d.requireWindowOnTarget(try a.requiredString("window"), ctx)
            d.guardWindow(ctx, w)
            // A prompt is already attached (its close button is disabled while it shows): report
            // it so the caller can answer it, instead of failing.
            if let sheet = AX.elements(w.ax, kAXChildrenAttribute).first(where: { AX.string($0, kAXRoleAttribute) == kAXSheetRole }) {
                ctx.warn("A prompt was already open on this window; nothing was pressed")
                return try promptResult(d, ctx, w, prompt: sheet, promptWindow: w.id, kind: "sheet")
            }
            guard let button = AX.element(w.ax, kAXCloseButtonAttribute), AX.bool(button, kAXEnabledAttribute) != false else {
                throw DriverError(.unsupported, "Window \(w.idString) has no enabled close button")
            }
            let existing = Set(d.windows.cgWindows(onScreenOnly: false).filter { $0.pid == w.pid }.map { $0.id })
            try await ctx.gate()
            // The app announces the outcome (window destroyed, sheet created); check as soon as it does.
            let watch = AXNotificationWatch(pid: w.pid)
            defer { watch?.stop() }
            let err = AX.perform(button, kAXPressAction)
            guard err == .success else { throw DriverError(.actionFailed, "Pressing the close button failed: \(AX.describe(err))") }
            ctx.dispatched()

            // Watch for: the window disappearing, a sheet attached to it, or a new dialog window.
            let until = monotonicMs() + 2_500
            var seen = 0
            while monotonicMs() < until {
                if let watch { await watch.waitForEvent(after: seen, timeoutMs: 120); seen = watch.count } else { try await sleepMs(120) }
                try Task.checkCancellation()
                if d.windows.cgWindow(w.id) == nil || !AX.isAlive(w.ax) {
                    ctx.confirm("window_gone")
                    if d.focus.get(ctx.target.id)?.windowID == w.id { d.focus.clear(ctx.target.id) }
                    return ["window": .string(w.idString), "closed": true, "status": "closed"]
                }
                if let sheet = AX.elements(w.ax, kAXChildrenAttribute).first(where: { AX.string($0, kAXRoleAttribute) == kAXSheetRole }) {
                    return try promptResult(d, ctx, w, prompt: sheet, promptWindow: w.id, kind: "sheet")
                }
                let dialogs = d.windows.cgWindows(onScreenOnly: true).filter { $0.pid == w.pid && !existing.contains($0.id) }
                if let dlg = dialogs.first, let dw = try? d.windows.resolve(dlg.id) {
                    return try promptResult(d, ctx, w, prompt: dw.ax, promptWindow: dlg.id, kind: "dialog")
                }
            }
            ctx.warn("The window is still open and no prompt was detected")
            return ["window": .string(w.idString), "closed": false, "status": "still_open"]
        }
    }

    static func promptResult(_ d: Driver, _ ctx: CallContext, _ w: ResolvedWindow, prompt: AXUIElement, promptWindow: CGWindowID, kind: String) throws -> JSONValue {
        ctx.confirm("prompt_shown")
        ctx.warn("The window has unsaved content; the prompt was left open and nothing was discarded")
        // Expose the prompt's buttons as refs so the caller can choose explicitly.
        let gen = d.refs.nextGeneration()
        var buttons: [JSONValue] = []
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 8 else { return }
            if AX.string(el, kAXRoleAttribute) == kAXButtonRole {
                let ref = d.refs.register(RefEntry(element: el, pid: w.pid, windowID: promptWindow, role: kAXButtonRole, generation: gen), index: buttons.count)
                buttons.append(["ref": .string(ref), "name": JSONValue(AX.string(el, kAXTitleAttribute) ?? AX.string(el, kAXDescriptionAttribute))])
            }
            for c in AX.elements(el, kAXChildrenAttribute) { walk(c, depth: depth + 1) }
        }
        walk(prompt, depth: 0)
        let text = AX.elements(prompt, kAXChildrenAttribute).compactMap { el -> String? in
            AX.string(el, kAXRoleAttribute) == kAXStaticTextRole ? AX.string(el, kAXValueAttribute) : nil
        }
        return ["window": .string(w.idString), "closed": false, "status": "prompt_pending",
                "prompt": ["kind": .string(kind), "window": .string(WindowService.idString(promptWindow)),
                           "text": .array(text.map { .string($0) }), "buttons": .array(buttons)]]
    }
}
