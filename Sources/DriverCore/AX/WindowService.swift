import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import DriverProtocol

/// A window as seen by the window server.
public struct CGWindowInfo: Sendable, Equatable {
    public let id: CGWindowID
    public let pid: pid_t
    public let ownerName: String
    public let title: String?
    public let bounds: CGRect
    public let layer: Int
    public let isOnScreen: Bool
    public let alpha: Double
}

/// A window resolved to both its CGWindowID and its accessibility element.
public struct ResolvedWindow: Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let ax: AXUIElement
    public let info: CGWindowInfo?

    public var idString: String { WindowService.idString(id) }
}

/// Window discovery, identity and placement. Window identifiers are `win:<CGWindowID>`, which
/// stay stable for the life of the window; app identifiers are `app:<pid>`.
public final class WindowService: @unchecked Sendable {
    /// Last display each window was seen on. Lets minimized windows (which have no on-screen
    /// bounds) still be attributed to the target they belong to.
    private let homes = Locked<[CGWindowID: CGDirectDisplayID]>([:])
    /// Windows the driver moved onto a target, with their original frame (restored on shutdown).
    private let placed = Locked<[CGWindowID: (pid: pid_t, original: CGRect)]>([:])
    /// Frames saved before maximize, restored by state=normal.
    private let savedFrames = Locked<[CGWindowID: CGRect]>([:])

    public init() {}

    public static func idString(_ id: CGWindowID) -> String { "win:\(id)" }
    public static func appIdString(_ pid: pid_t) -> String { "app:\(pid)" }

    public static func parseWindowId(_ s: String) throws -> CGWindowID {
        let body = s.hasPrefix("win:") ? String(s.dropFirst(4)) : s
        guard let v = UInt32(body), v > 0 else {
            throw DriverError(.invalidArgument, "Invalid window id '\(s)'; expected 'win:<number>' from computer_apps")
        }
        return v
    }

    public static func parseAppId(_ s: String) -> pid_t? {
        guard s.hasPrefix("app:"), let p = Int32(s.dropFirst(4)), p > 0 else { return nil }
        return p
    }

    // MARK: Enumeration

    public func cgWindows(onScreenOnly: Bool) -> [CGWindowInfo] {
        let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap(Self.parse)
    }

    public func cgWindow(_ id: CGWindowID) -> CGWindowInfo? {
        if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
           let w = list.compactMap(Self.parse).first(where: { $0.id == id }) { return w }
        // macOS 26 omits minimized windows from the single-window query; the full list has them.
        return cgWindows(onScreenOnly: false).first { $0.id == id }
    }

    static func parse(_ d: [String: Any]) -> CGWindowInfo? {
        guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
        var bounds = CGRect.null
        if let b = d[kCGWindowBounds as String] as? NSDictionary { bounds = CGRect(dictionaryRepresentation: b) ?? .null }
        return CGWindowInfo(id: id, pid: pid,
                            ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                            title: d[kCGWindowName as String] as? String,
                            bounds: bounds,
                            layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                            isOnScreen: (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                            alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
    }

    /// Display with the largest overlap with `rect`.
    public static func display(for rect: CGRect) -> CGDirectDisplayID? {
        var best: (CGDirectDisplayID, CGFloat)?
        for id in activeDisplayIDs() {
            let a = CGDisplayBounds(id).intersection(rect).area()
            if a > 0, a > (best?.1 ?? 0) { best = (id, a) }
        }
        return best?.0
    }

    /// Records which display each visible window is on.
    public func refreshHomes(_ windows: [CGWindowInfo]) {
        homes.withLock { h in
            for w in windows where w.isOnScreen && w.layer == 0 {
                if let d = Self.display(for: w.bounds) { h[w.id] = d }
            }
        }
    }

    public func home(of id: CGWindowID) -> CGDirectDisplayID? { homes.get[id] }
    public func setHome(_ id: CGWindowID, _ display: CGDirectDisplayID) { homes.withLock { $0[id] = display } }

    // MARK: Resolution

    /// Resolves a window id to its AX element. Fails with `unknown_window` if it is gone or not
    /// an accessible window.
    public func resolve(_ id: CGWindowID) throws -> ResolvedWindow {
        guard let info = cgWindow(id) else {
            throw DriverError(.unknownWindow, "Window \(Self.idString(id)) does not exist (closed?)")
        }
        guard AX.isTrusted else {
            throw DriverError(.permissionMissing, "Accessibility permission is required to operate windows")
        }
        for w in AX.windows(of: info.pid) where AX.windowID(w) == id {
            return ResolvedWindow(id: id, pid: info.pid, ax: w, info: info)
        }
        throw DriverError(.unknownWindow, "Window \(Self.idString(id)) is not an accessible application window",
                          details: ["owner": .string(info.ownerName), "layer": .number(Double(info.layer))])
    }

    /// Which display a window currently belongs to (its on-screen bounds, or its last known home
    /// when minimized/hidden).
    public func displayOf(_ w: ResolvedWindow) -> CGDirectDisplayID? {
        // The app's AX frame is current; the window server's bounds can lag a just-moved window.
        if AX.bool(w.ax, kAXMinimizedAttribute) != true, let f = AX.frame(w.ax), let d = Self.display(for: f) {
            setHome(w.id, d); return d
        }
        if let info = w.info, info.isOnScreen, let d = Self.display(for: info.bounds) {
            setHome(w.id, d); return d
        }
        if let h = home(of: w.id) { return h }
        // Minimized windows keep reporting their pre-minimize AX position.
        if let f = AX.frame(w.ax), let d = Self.display(for: f) { setHome(w.id, d); return d }
        return nil
    }

    public func isMinimized(_ w: ResolvedWindow) -> Bool { AX.bool(w.ax, kAXMinimizedAttribute) ?? false }

    // MARK: Listing

    public struct WindowEntry {
        public let window: ResolvedWindow
        public let title: String
        public let frame: CGRect   // global
        public let minimized: Bool
        public let isMain: Bool
        public let isFocused: Bool
        public let zIndex: Int?    // 0 = frontmost on screen
        public let role: String?
        public let subrole: String?
    }

    /// All accessible application windows on `display`, front to back (minimized windows last).
    public func windows(on display: CGDirectDisplayID) -> [WindowEntry] {
        let onScreen = cgWindows(onScreenOnly: true)
        refreshHomes(onScreen)
        let all = cgWindows(onScreenOnly: false).filter { $0.layer == 0 }
        var zOrder: [CGWindowID: Int] = [:]
        for (i, w) in onScreen.filter({ $0.layer == 0 }).enumerated() { zOrder[w.id] = i }

        // Candidates: on-screen windows on this display, plus every off-screen window (minimized
        // or hidden), which is attributed below by its remembered home or its AX position.
        let me = ProcessInfo.processInfo.processIdentifier
        let candidates = all.filter { w in
            if w.pid == me { return false }
            if w.isOnScreen { return Self.display(for: w.bounds) == display }
            if let h = home(of: w.id) { return h == display }
            return true
        }
        let byPid = Dictionary(grouping: candidates, by: { $0.pid })
        var out: [WindowEntry] = []
        for (pid, infos) in byPid {
            let axWins = AX.windows(of: pid)
            let app = AX.app(pid)
            let focused = AX.element(app, kAXFocusedWindowAttribute).flatMap { AX.windowID($0) }
            for ax in axWins {
                guard let id = AX.windowID(ax), let info = infos.first(where: { $0.id == id }) else { continue }
                if !info.isOnScreen && home(of: id) == nil {
                    guard let f = AX.frame(ax), Self.display(for: f) == display else { continue }
                    setHome(id, display)
                }
                let attrs = AX.multiple(ax, [kAXTitleAttribute, kAXMinimizedAttribute, kAXMainAttribute, kAXRoleAttribute, kAXSubroleAttribute])
                let minimized = (attrs[kAXMinimizedAttribute] as? Bool) ?? !info.isOnScreen
                out.append(WindowEntry(
                    window: ResolvedWindow(id: id, pid: pid, ax: ax, info: info),
                    title: (attrs[kAXTitleAttribute] as? String) ?? info.title ?? "",
                    frame: AX.frame(ax) ?? info.bounds,
                    minimized: minimized,
                    isMain: (attrs[kAXMainAttribute] as? Bool) ?? false,
                    isFocused: focused == id,
                    zIndex: zOrder[id],
                    role: attrs[kAXRoleAttribute] as? String,
                    subrole: attrs[kAXSubroleAttribute] as? String))
            }
        }
        out.sort { ($0.zIndex ?? Int.max, $0.window.id) < ($1.zIndex ?? Int.max, $1.window.id) }
        return out
    }

    /// Frontmost window on `display` that can be operated (visible, not minimized, accessible).
    public func frontmostOperable(on display: CGDirectDisplayID) -> ResolvedWindow? {
        windows(on: display).first { !$0.minimized && $0.zIndex != nil && ($0.role == kAXWindowRole) }?.window
    }

    // MARK: Placement

    public func recordPlacement(_ id: CGWindowID, pid: pid_t, original: CGRect) {
        placed.withLock { if $0[id] == nil { $0[id] = (pid, original) } }
    }

    public func forgetPlacement(_ id: CGWindowID) { placed.withLock { $0[id] = nil } }

    public var placedWindows: [(CGWindowID, pid_t, CGRect)] { placed.get.map { ($0.key, $0.value.pid, $0.value.original) } }

    public func saveFrame(_ id: CGWindowID, _ f: CGRect) { savedFrames.withLock { $0[id] = f } }
    public func savedFrame(_ id: CGWindowID) -> CGRect? { savedFrames.get[id] }
    public func clearSavedFrame(_ id: CGWindowID) { savedFrames.withLock { $0[id] = nil } }

    /// Moves a window so it lies inside `area` (global coordinates), keeping its size when it
    /// fits. Returns the frame actually applied, read back from the application.
    @discardableResult
    public func move(_ w: ResolvedWindow, into area: CGRect, preferredOrigin: CGPoint? = nil) -> CGRect? {
        guard var f = AX.frame(w.ax) else { return nil }
        f.size.width = min(f.width, area.width)
        f.size.height = min(f.height, area.height)
        var origin = preferredOrigin ?? CGPoint(x: area.minX + (area.width - f.width) / 2, y: area.minY + (area.height - f.height) / 2)
        origin.x = min(max(origin.x, area.minX), area.maxX - f.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - f.height)
        // Position first so the size change never pushes the window across displays.
        AX.setPosition(w.ax, origin)
        AX.setSize(w.ax, f.size)
        AX.setPosition(w.ax, origin)
        // Some apps apply the change late or only in part (a browser window created at the size
        // of a maximized one keeps its width on the first request). Ask again until it fits.
        var attempts = 0
        while attempts < 5, let now = AX.frame(w.ax), !area.insetBy(dx: -1, dy: -1).contains(now) {
            attempts += 1
            usleep(60_000)
            AX.setSize(w.ax, f.size)
            AX.setPosition(w.ax, origin)
        }
        return AX.frame(w.ax)
    }

    /// Usable area of a display: excludes the menu bar on the main display and the Dock if it is
    /// on that display.
    public static func visibleFrame(of display: CGDirectDisplayID) -> CGRect {
        // NSScreen is main-thread only. The main thread never blocks on the driver, so this is safe.
        if !Thread.isMainThread { return DispatchQueue.main.sync { visibleFrame(of: display) } }
        let bounds = CGDisplayBounds(display)
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) else { return bounds }
        // Convert NSScreen (bottom-left origin) to CG (top-left origin) using the primary screen height.
        let primaryH = NSScreen.screens.first?.frame.height ?? bounds.height
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: primaryH - v.maxY, width: v.width, height: v.height)
    }
}
