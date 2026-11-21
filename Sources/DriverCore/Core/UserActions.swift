import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import DriverProtocol

/// Actions the human starts from the host UI (menu bar or mirror window).
///
/// The driver never moves the user's windows onto the virtual monitor on its own. These are the
/// explicit, user-initiated ways to put something there: open an app or file on it, move an
/// existing window to it, or send a window back. They run as the user, so they also work while
/// the user holds control, and they go through the same code and checks as the tools.
public struct UserWindowItem: Sendable {
    public let windowID: CGWindowID
    public let appName: String
    public let title: String
    public var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

public enum UserActionError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String { if case .failed(let s) = self { return s }; return "" }
}

extension Driver {
    /// Runs a tool as the user (not subject to Take Control) and returns its response.
    public func callAsUser(_ name: String, _ arguments: [String: JSONValue]) async -> ToolResponse {
        await execute(ToolRequest(id: "user-" + UUID().uuidString.lowercased(), name: name, arguments: arguments), asUser: true)
    }

    private func items(_ entries: [WindowService.WindowEntry]) -> [UserWindowItem] {
        entries.filter { !$0.minimized && $0.role == kAXWindowRole }.map {
            UserWindowItem(windowID: $0.window.id,
                           appName: NSRunningApplication(processIdentifier: $0.window.pid)?.localizedName ?? "pid \($0.window.pid)",
                           title: $0.title)
        }
    }

    /// The user's visible windows on physical displays (candidates for "Move Window Here").
    public func windowsOnPhysicalDisplays() -> [UserWindowItem] {
        targets.all().filter { !$0.isVirtual }.flatMap { items(windows.windows(on: $0.displayID)) }
    }

    /// Visible windows on the virtual monitor (candidates for "Send Window Back").
    public func windowsOnVirtualMonitor() -> [UserWindowItem] {
        guard let v = display.displayID else { return [] }
        return items(windows.windows(on: v))
    }

    /// Opens an app (a new window if it is already running) or a file on the virtual monitor.
    /// Returns a one-line summary.
    public func userOpen(appURL: URL? = nil, fileURL: URL? = nil) async -> String {
        var args: [String: JSONValue] = [:]
        if let fileURL { args["path"] = .string(fileURL.path) }
        if let appURL { args["app"] = .string(appURL.path) }
        var r = await callAsUser("computer_open", args)
        // A running app with no new window: ask it for one, the way a person would (File > New).
        if r.ok, fileURL == nil, let appURL, !created(r) {
            for intent in ["new_window", "new_document"] {
                let again = await callAsUser("computer_open", ["app": .string(appURL.path), "intent": .string(intent)])
                if again.ok { r = again; break }
            }
        }
        guard r.ok else { return "Could not open: \(r.error?.message ?? "unknown error")" }
        let name = r.result["name"]?.stringValue ?? "App"
        let count = r.result["windows"]?.arrayValue?.filter { $0["status"]?.stringValue == "created" }.count ?? 0
        return count > 0 ? "Opened \(name) on the virtual monitor" : "\(name) opened, but it created no new window there"
    }

    private func created(_ r: ToolResponse) -> Bool {
        r.result["windows"]?.arrayValue?.contains { $0["status"]?.stringValue == "created" } ?? false
    }

    /// Moves one of the user's windows to the virtual monitor (explicit user request).
    public func userMoveToVirtual(_ id: CGWindowID) throws {
        guard let vid = display.displayID else { throw UserActionError.failed("The virtual monitor is not running") }
        let w = try windows.resolve(id)
        guard AX.bool(w.ax, "AXFullScreen") != true else { throw UserActionError.failed("Exit full screen first") }
        let original = AX.frame(w.ax) ?? .null
        let area = WindowService.visibleFrame(of: vid)
        guard let f = windows.move(w, into: area, preferredOrigin: CGPoint(x: area.minX + 40, y: area.minY + 30)),
              WindowService.display(for: f) == vid else {
            throw UserActionError.failed("The app did not allow the window to move")
        }
        windows.recordPlacement(id, pid: w.pid, original: original)
        windows.setHome(id, vid)
    }

    /// Returns a window from the virtual monitor to where it came from (or the main display).
    public func userSendBack(_ id: CGWindowID) throws {
        let w = try windows.resolve(id)
        let original = windows.placedWindows.first { $0.0 == id }?.2
        let dest = original.flatMap { WindowService.display(for: $0) } ?? CGMainDisplayID()
        guard windows.move(w, into: WindowService.visibleFrame(of: dest), preferredOrigin: original?.origin) != nil else {
            throw UserActionError.failed("The app did not allow the window to move")
        }
        windows.forgetPlacement(id)
        windows.setHome(id, dest)
        // Back on the user's own screen, the app should not go on looking active.
        WindowFocuser.withdrawActiveBelief(pid: w.pid)
    }
}
