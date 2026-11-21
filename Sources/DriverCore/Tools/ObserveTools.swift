import Foundation
import AppKit
import CoreGraphics
import DriverProtocol

func frameJSON(_ r: CGRect) -> JSONValue {
    let r = r.rounded()
    return ["x": .number(r.minX), "y": .number(r.minY), "width": .number(r.width), "height": .number(r.height)]
}

func appJSON(_ pid: pid_t) -> [String: JSONValue] {
    let app = NSRunningApplication(processIdentifier: pid)
    return ["app": .string(WindowService.appIdString(pid)), "name": JSONValue(app?.localizedName),
            "bundle_id": JSONValue(app?.bundleIdentifier), "pid": .number(Double(pid))]
}

enum ObserveTools {
    static func apps(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_apps",
                 summary: "Lists the apps and windows on the target display.",
                 mutating: false, params: [], defaultTimeoutMs: 10_000) { ctx, _ in
            guard AX.isTrusted else { throw DriverError(.permissionMissing, "Accessibility permission is required to list windows") }
            let geo = ctx.target.geometry
            let entries = d.windows.windows(on: ctx.target.displayID)
            var byPid: [pid_t: [JSONValue]] = [:]
            var order: [pid_t] = []
            for e in entries {
                if byPid[e.window.pid] == nil { order.append(e.window.pid) }
                var w: [String: JSONValue] = [
                    "window": .string(e.window.idString), "title": .string(e.title),
                    "frame": frameJSON(geo.toLocal(e.frame)),
                    "state": .string(e.minimized ? "minimized" : (isMaximized(e.frame, ctx.target.displayID) ? "maximized" : "normal")),
                    "main": .bool(e.isMain), "focused_in_app": .bool(e.isFocused),
                ]
                if let z = e.zIndex { w["z_order"] = .number(Double(z)) }
                if let s = e.subrole { w["subrole"] = .string(s) }
                byPid[e.window.pid, default: []].append(.object(w))
            }
            let apps: [JSONValue] = order.map { pid in
                var a = appJSON(pid)
                a["windows"] = .array(byPid[pid] ?? [])
                return .object(a)
            }
            let front = NSWorkspace.shared.frontmostApplication
            return [
                "computer": .string(ctx.target.id),
                "display": ctx.target.json,
                "apps": .array(apps),
                "window_count": .number(Double(entries.count)),
                "system_frontmost_app": JSONValue(front?.localizedName),
                "coordinate_space": "target display points, origin top-left",
            ]
        }
    }

    static func isMaximized(_ frame: CGRect, _ display: CGDirectDisplayID) -> Bool {
        let v = WindowService.visibleFrame(of: display)
        return abs(frame.minX - v.minX) <= 2 && abs(frame.minY - v.minY) <= 2 && abs(frame.width - v.width) <= 4 && abs(frame.height - v.height) <= 4
    }

    static func screenshot(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_screenshot",
                 summary: "Captures the target display, or one window on it, and returns an id that click, drag and scroll positions refer to.",
                 mutating: false, params: [
            Param("window", .string, "Capture only this window (win:<id>). Default: the whole display."),
            Param("format", .choice(["png", "jpeg"]), "Image format. Default: png."),
            Param("resolution", .choice(["points", "pixels"]), "points: one image pixel per display point (default). pixels: native resolution."),
            Param("return", .choice(["base64", "path"]), "Return the image inline or as a file path. Default: base64."),
        ], defaultTimeoutMs: 15_000) { ctx, a in
            let format = try a.oneOf("format", ["png", "jpeg"], default: "png")!
            let resolution = try a.oneOf("resolution", ["points", "pixels"], default: "points")!
            let ret = try a.oneOf("return", ["base64", "path"], default: "base64")!
            let geo = ctx.target.geometry
            let scale: CGFloat = resolution == "pixels" ? geo.scale : 1
            let id = d.screenshots.newID()
            let image: CGImage
            let record: ScreenshotRecord
            var windowJSON: JSONValue = .null
            if let wid = try a.string("window") {
                let w = try d.requireWindowOnTarget(wid, ctx, allowMinimized: false)
                guard let info = d.windows.cgWindow(w.id), info.isOnScreen else {
                    throw DriverError(.unknownWindow, "Window \(w.idString) is not visible")
                }
                let frame = info.bounds
                image = try await d.capture.captureWindow(w.id, outputSize: CGSize(width: frame.width * scale, height: frame.height * scale))
                record = ScreenshotRecord(id: id, targetID: ctx.target.id, displayID: ctx.target.displayID, windowID: w.id,
                                          windowFrame: frame, origin: geo.toLocal(frame.origin),
                                          pixelSize: CGSize(width: image.width, height: image.height),
                                          scale: CGFloat(image.width) / frame.width, capturedAt: Date())
                windowJSON = .string(w.idString)
            } else {
                image = try await d.capture.captureDisplay(ctx.target.displayID,
                                                           outputSize: CGSize(width: geo.bounds.width * scale, height: geo.bounds.height * scale))
                record = ScreenshotRecord(id: id, targetID: ctx.target.id, displayID: ctx.target.displayID, windowID: nil,
                                          windowFrame: nil, origin: .zero,
                                          pixelSize: CGSize(width: image.width, height: image.height),
                                          scale: CGFloat(image.width) / geo.bounds.width, capturedAt: Date())
            }
            d.screenshots.add(record)
            let data = try ScreenshotService.encode(image, format: format)
            var out: [String: JSONValue] = [
                "screenshot": .string(id),
                "computer": .string(ctx.target.id),
                "window": windowJSON,
                "width": .number(Double(image.width)), "height": .number(Double(image.height)),
                "scale": .number(Double(record.scale)),
                "origin": ["x": .number(record.origin.x.rounded()), "y": .number(record.origin.y.rounded())],
                "coordinate_note": "Use pixel coordinates of this image with in=<screenshot>. Target point = origin + (x, y) / scale.",
                "mime_type": .string(format == "png" ? "image/png" : "image/jpeg"),
                "bytes": .number(Double(data.count)),
                "captured_at": .string(ISO8601DateFormatter().string(from: record.capturedAt)),
            ]
            if ret == "path" {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacDriverShots", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(id.replacingOccurrences(of: ":", with: "_") + (format == "png" ? ".png" : ".jpg"))
                try data.write(to: url)
                out["path"] = .string(url.path)
                pruneScreenshotFiles(in: dir, keep: 40)
            } else {
                out["image_base64"] = .string(data.base64EncodedString())
            }
            return .object(out)
        }
    }

    static func snapshot(_ d: Driver) -> ToolSpec {
        ToolSpec(name: "computer_snapshot",
                 summary: "Returns the accessibility tree of a window, with a ref for each element.",
                 mutating: false, params: [
            Param("window", .string, "Window to read (win:<id>). Default: the frontmost usable window on the target."),
            Param("scope", .choice(["all", "visible"]), "visible leaves out elements scrolled out of the window. Default: all."),
            Param("detail", .choice(["full", "compact"]), "compact leaves out groups with no name, value or action; their contents move up a level. Default: full."),
            Param("query", .string, "Return only elements whose name, value, placeholder or role contains this text, as a flat list in matches."),
        ], defaultTimeoutMs: 20_000) { ctx, a in
            guard AX.isTrusted else {
                throw DriverError(.accessibilityUnavailable, "Accessibility permission is not granted; screenshot-based operation remains available",
                                  details: ["fallback": "computer_screenshot"])
            }
            let w: ResolvedWindow
            var selected = "explicit"
            if let wid = try a.string("window") {
                w = try d.requireWindowOnTarget(wid, ctx)
            } else {
                guard let f = d.windows.frontmostOperable(on: ctx.target.displayID) else {
                    throw DriverError(.unknownWindow, "No operable window on target '\(ctx.target.id)'")
                }
                w = f; selected = "frontmost_on_target"
            }
            let geo = ctx.target.geometry
            let options = SnapshotService.Options(visibleOnly: try a.oneOf("scope", ["all", "visible"]) == "visible", compact: try a.oneOf("detail", ["full", "compact"]) == "compact")
            let query = try a.string("query")?.lowercased()
            var r: SnapshotService.Result
            do {
                let requested = WebAccessibility.enable(pid: w.pid)
                r = try d.snapshots.snapshot(w, options: options) { geo.toLocal($0) }
                if requested {
                    // The app builds its web content's tree after the request; read again until it stops growing.
                    let until = monotonicMs() + 2_000
                    var grew = false
                    while monotonicMs() < until {
                        try await sleepMs(150)
                        let again = try d.snapshots.snapshot(w, options: options) { geo.toLocal($0) }
                        let stable = again.nodeCount == r.nodeCount
                        if again.nodeCount > r.nodeCount { grew = true }
                        r = again
                        if stable && (grew || monotonicMs() > until - 1_400) { break }
                    }
                    if grew { ctx.evidence("web_accessibility_enabled") }
                }
            } catch let e as DriverError where e.code == .accessibilityUnavailable {
                var e2 = e; e2.details["fallback"] = "computer_screenshot"; e2.details["window"] = .string(w.idString); throw e2
            }
            var out = appJSON(w.pid)
            out["window"] = .string(w.idString)
            out["title"] = JSONValue(AX.string(w.ax, kAXTitleAttribute))
            out["selected_by"] = .string(selected)
            out["node_count"] = .number(Double(r.nodeCount))
            out["ref_count"] = .number(Double(r.refCount))
            out["truncated"] = .bool(r.truncated)
            if let query, !query.isEmpty {
                // A flat list of the matching elements, each without its contents.
                var matches: [JSONValue] = []
                func search(_ n: JSONValue) {
                    guard case .object(var o) = n else { return }
                    let kids = o["children"]?.arrayValue ?? []
                    let text = ["name", "value", "placeholder", "role", "identifier"].compactMap { o[$0]?.stringValue }.joined(separator: "\n").lowercased()
                    if text.contains(query), matches.count < 200 { o["children"] = nil; matches.append(.object(o)) }
                    kids.forEach(search)
                }
                search(r.tree)
                out["matches"] = .array(matches)
                out["match_count"] = .number(Double(matches.count))
            } else {
                out["tree"] = r.tree
            }
            if r.truncated {
                ctx.warn("The window has more elements than a snapshot holds (\(d.snapshots.maxNodes)). Narrow it with scope: visible, detail: compact or query")
            }
            if r.refCount == 0 { ctx.warn("The window exposes no actionable elements; use screenshot coordinates") }
            return .object(out)
        }
    }
}

/// Screenshot files are only useful to the caller that just asked for them. Without a limit
/// they accumulate for as long as the host runs (about 1 MB each).
func pruneScreenshotFiles(in dir: URL, keep: Int) {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]), files.count > keep else { return }
    let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? fm.removeItem(at: url) }
}

public enum Tools {
    public static func all(_ d: Driver) -> [ToolSpec] {
        [ObserveTools.apps(d), ObserveTools.screenshot(d), ObserveTools.snapshot(d),
         InputTools.click(d), InputTools.drag(d), InputTools.scroll(d), InputTools.type(d), InputTools.key(d),
         WindowTools.open(d), WindowTools.window(d), WindowTools.close(d)]
    }
}
