import Foundation
import ApplicationServices

/// Finds and presses standard menu commands through the accessibility API, without activating
/// the app or sending keystrokes. Matching is by the AppKit action selector exposed as the menu
/// item's AXIdentifier first (language independent), then by English title.
public enum MenuInvoker {
    public enum Command: String {
        case newWindow = "new_window"
        case newDocument = "new_document"

        var identifiers: [String] {
            switch self {
            case .newWindow: return ["newWindow:", "newWindowForTab:", "_newWindow:", "newBrowserWindow:"]
            case .newDocument: return ["newDocument:", "newDocumentAction:", "_newDocument:"]
            }
        }

        var titles: [String] {
            switch self {
            case .newWindow: return ["New Window", "New Finder Window", "New Browser Window"]
            case .newDocument: return ["New Document", "New", "New File", "New Note", "New Text Document"]
            }
        }
    }

    public struct Match {
        public let item: AXUIElement
        public let title: String
        public let matchedBy: String
    }

    public static func find(_ cmd: Command, pid: pid_t) -> Match? {
        guard let bar = AX.element(AX.app(pid), kAXMenuBarAttribute) else { return nil }
        var byTitle: Match?
        // Menu bar -> top-level menus -> items (and one level of submenus).
        for top in AX.elements(bar, kAXChildrenAttribute) {
            for menu in AX.elements(top, kAXChildrenAttribute) {
                for item in AX.elements(menu, kAXChildrenAttribute) {
                    if let m = check(item, cmd) {
                        if m.matchedBy == "identifier" { return m }
                        if byTitle == nil { byTitle = m }
                    }
                }
            }
        }
        return byTitle
    }

    private static func check(_ item: AXUIElement, _ cmd: Command) -> Match? {
        let title = AX.string(item, kAXTitleAttribute) ?? ""
        if AX.bool(item, kAXEnabledAttribute) == false { return nil }
        if let ident = AX.string(item, kAXIdentifierAttribute), cmd.identifiers.contains(ident) {
            return Match(item: item, title: title, matchedBy: "identifier")
        }
        let clean = title.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
        if cmd.titles.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            return Match(item: item, title: title, matchedBy: "title")
        }
        return nil
    }
}
