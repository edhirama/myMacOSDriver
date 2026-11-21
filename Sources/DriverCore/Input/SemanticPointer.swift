import Foundation
import ApplicationServices
import CoreGraphics

/// Pointer actions performed through accessibility instead of mouse events:
///
/// - text: caret placement (1 click), word (2), line (3), shift-click extends, drag selects;
/// - buttons, checkboxes, links, …: a single click presses the element.
///
/// These were introduced when mouse events could not reach an inactive app's views at all.
/// Events now can (see InputRouter and EventPoster), but text and standard controls stay on this
/// path: it is deterministic, needs no pointer position inside the app, and is verified by the
/// end-to-end suites.
///
/// The semantic path replaces the mouse events (it never adds to them), so each click acts once.
/// These are the accessibility primitives only; InputRouter decides when each one is used.
public enum SemanticPointer {
    static let pressableRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, "AXLink",
        kAXDisclosureTriangleRole, kAXIncrementorRole, "AXSwitch", "AXToggle", kAXMenuItemRole, kAXMenuBarItemRole,
    ]

    /// A left click on editable text: caret (1 click), word (2), line (3); `extend` is a
    /// shift-click. Returns the resulting selection, or nil when the text refused it.
    public static func clickText(_ el: AXUIElement, at p: CGPoint, count: Int, extend: Bool) -> CFRange? {
        guard let idx = AXText.index(at: p, in: el) else { return nil }
        var range: CFRange
        switch count {
        case 2: range = AXText.wordRange(at: idx, in: el) ?? CFRange(location: idx, length: 0)
        case 3...: range = AXText.lineRange(at: idx, in: el) ?? CFRange(location: idx, length: 0)
        default: range = CFRange(location: idx, length: 0)
        }
        if extend, count == 1, let cur = AXText.selectedRange(el) {
            let lo = min(cur.location, idx), hi = max(cur.location + cur.length, idx)
            range = CFRange(location: lo, length: hi - lo)
        }
        AX.set(el, kAXFocusedAttribute, kCFBooleanTrue)
        guard AXText.setSelectedRange(el, range) == .success else { return nil }
        return AXText.selectedRange(el) ?? range
    }

    /// A pressable control under the point (the element itself or a close ancestor).
    public static func pressable(at p: CGPoint, pid: pid_t) -> (element: AXUIElement, role: String)? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AX.app(pid), Float(p.x), Float(p.y), &hit) == .success, var cur = hit else { return nil }
        for _ in 0..<3 {
            if let role = AX.string(cur, kAXRoleAttribute), pressableRoles.contains(role),
               AX.bool(cur, kAXEnabledAttribute) != false, AX.actions(cur).contains(kAXPressAction) {
                return (cur, role)
            }
            guard let parent = AX.element(cur, kAXParentAttribute) else { break }
            cur = parent
        }
        return nil
    }

    /// Text drag-selection from `a` to `b`. Returns nil when `a` is not on editable text.
    public static func selectText(from a: CGPoint, to b: CGPoint, pid: pid_t) -> CFRange? {
        guard let el = AXText.editableText(at: a, pid: pid), let i = AXText.index(at: a, in: el) else { return nil }
        let j = AXText.index(at: b, in: el) ?? i
        let range = CFRange(location: min(i, j), length: abs(j - i))
        AX.set(el, kAXFocusedAttribute, kCFBooleanTrue)
        guard AXText.setSelectedRange(el, range) == .success else { return nil }
        return AXText.selectedRange(el) ?? range
    }
}

extension CFRange {
    var json: [String: Int] { ["location": location, "length": length] }
}
