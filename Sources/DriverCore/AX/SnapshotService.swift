import Foundation
import ApplicationServices
import CoreGraphics
import DriverProtocol

/// A registered element reference.
public struct RefEntry {
    public let element: AXUIElement
    public let pid: pid_t
    public let windowID: CGWindowID
    public let role: String
    public let generation: Int
}

/// Element references handed out by `computer_snapshot`. Refs look like `ref:<gen>.<n>` and stay
/// valid as long as the underlying element exists in the same window; every use re-validates.
public final class RefRegistry: Sendable {
    private let store = Locked(LRUCache<String, RefEntry>(capacity: 20_000))
    private let gen = Locked(0)

    public init() {}

    public func nextGeneration() -> Int { gen.withLock { $0 += 1; return $0 } }

    public func register(_ e: RefEntry, index: Int) -> String {
        let id = "ref:\(e.generation).\(index)"
        store.withLock { $0[id] = e }
        return id
    }

    public func lookup(_ ref: String) throws -> RefEntry {
        guard let e = store.withLock({ $0[ref] }) else {
            throw DriverError(.staleRef, "Unknown ref '\(ref)'; take a new computer_snapshot")
        }
        guard AX.isAlive(e.element) else {
            throw DriverError(.staleRef, "Element \(ref) no longer exists; take a new computer_snapshot")
        }
        if let w = AX.element(e.element, kAXWindowAttribute), let wid = AX.windowID(w), wid != e.windowID {
            throw DriverError(.staleRef, "Element \(ref) moved to another window; take a new computer_snapshot")
        }
        return e
    }
}

/// Reads a window's accessibility tree into JSON with actionable refs.
public final class SnapshotService: @unchecked Sendable {
    public let refs: RefRegistry
    public var maxNodes = 1500
    /// Web pages nest deeply (a feed's posts sat below level 40 on one site), so this is generous;
    /// `maxNodes` is what bounds the work.
    public var maxDepth = 120

    public init(refs: RefRegistry) { self.refs = refs }

    static let attrs: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXIdentifierAttribute, kAXPlaceholderValueAttribute, kAXExpandedAttribute, kAXChildrenAttribute,
        "AXLabel", kAXHelpAttribute,
    ]

    /// Roles that are worth a ref even without any advertised action.
    static let interactiveRoles: Set<String> = [
        kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXComboBoxRole, kAXSliderRole, "AXLink", kAXMenuItemRole, kAXRowRole,
        kAXCellRole, kAXTabGroupRole, kAXIncrementorRole, kAXDisclosureTriangleRole, kAXScrollAreaRole, "AXSearchField",
        kAXStaticTextRole, kAXImageRole, kAXListRole, kAXTableRole, kAXOutlineRole, "AXWebArea", kAXWindowRole, kAXSheetRole,
    ]

    public struct Result {
        public let tree: JSONValue
        public let nodeCount: Int
        public let refCount: Int
        public let truncated: Bool
        public let generation: Int
    }

    /// What to leave out. Web pages have thousands of elements, most of them scrolled out of
    /// view or wrappers with nothing to say; a snapshot of everything is cut off at `maxNodes`
    /// long before it reaches what the script is looking for.
    public struct Options: Sendable {
        /// Leave out elements (and what they contain) that lie entirely outside the window.
        public var visibleOnly = false
        /// Leave out groups that have no name, value or action; their contents move up a level.
        public var compact = false
        public init(visibleOnly: Bool = false, compact: Bool = false) { self.visibleOnly = visibleOnly; self.compact = compact }
    }

    /// `toLocal` converts global coordinates to the target display's coordinate space.
    public func snapshot(_ w: ResolvedWindow, options: Options = Options(), toLocal: (CGRect) -> CGRect) throws -> Result {
        guard AX.isAlive(w.ax) else { throw DriverError(.unknownWindow, "Window \(w.idString) no longer exists") }
        let generation = refs.nextGeneration()
        var count = 0, refCount = 0, truncated = false
        let clip: CGRect? = options.visibleOnly ? AX.frame(w.ax) : nil

        /// Returns the node, or the nodes that stand in for it when it is left out.
        func visit(_ el: AXUIElement, depth: Int) -> [JSONValue] {
            if count >= maxNodes { truncated = true; return [] }
            let a = AX.multiple(el, Self.attrs)
            guard let role = a[kAXRoleAttribute] as? String else { return [] }
            var globalFrame: CGRect?
            if let pv = a[kAXPositionAttribute], let sv = a[kAXSizeAttribute],
               CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() {
                var p = CGPoint.zero, sz = CGSize.zero
                AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &sz)
                globalFrame = CGRect(origin: p, size: sz)
            }
            if let clip, depth > 0, let g = globalFrame {
                if g.width > 0, g.height > 0 {
                    if !g.intersects(clip) { return [] }
                } else if g.minY >= clip.maxY - 1 || g.maxY <= clip.minY + 1 || g.minX >= clip.maxX - 1 || g.maxX <= clip.minX + 1 {
                    // Browsers report content scrolled out of view as flattened against the edge it left by.
                    return []
                }
            }
            var node: [String: JSONValue] = ["role": .string(role)]
            if let s = a[kAXSubroleAttribute] as? String { node["subrole"] = .string(s) }
            let name = [a[kAXTitleAttribute], a["AXLabel"], a[kAXDescriptionAttribute]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            if let name { node["name"] = .string(String(name.prefix(200))) }
            if let v = a[kAXValueAttribute] {
                if let s = v as? String {
                    node["value"] = .string(s.count > 500 ? String(s.prefix(500)) + "…" : s)
                    // The full length, so a truncated value can still be checked.
                    if s.count > 500 { node["value_length"] = .number(Double(s.count)) }
                }
                else if let n = v as? NSNumber { node["value"] = .number(n.doubleValue) }
            }
            if let p = a[kAXPlaceholderValueAttribute] as? String, !p.isEmpty { node["placeholder"] = .string(p) }
            if let i = a[kAXIdentifierAttribute] as? String, !i.isEmpty { node["identifier"] = .string(i) }

            var states: [JSONValue] = []
            if let e = a[kAXEnabledAttribute] as? Bool { states.append(.string(e ? "enabled" : "disabled")) }
            if (a[kAXFocusedAttribute] as? Bool) == true { states.append("focused") }
            if (a[kAXSelectedAttribute] as? Bool) == true { states.append("selected") }
            if let ex = a[kAXExpandedAttribute] as? Bool { states.append(.string(ex ? "expanded" : "collapsed")) }
            if role == kAXCheckBoxRole || role == kAXRadioButtonRole, let n = a[kAXValueAttribute] as? NSNumber {
                states.append(.string(n.intValue == 1 ? "checked" : n.intValue == 2 ? "mixed" : "unchecked"))
            }
            if !states.isEmpty { node["states"] = .array(states) }
            // Caret / selection of text elements, as character offsets.
            if role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole || role == "AXSearchField",
               let r = AXText.selectedRange(el) {
                node["selection"] = ["location": .number(Double(r.location)), "length": .number(Double(r.length))]
            }

            if let g = globalFrame {
                let f = toLocal(g).rounded()
                node["frame"] = ["x": .number(f.minX), "y": .number(f.minY), "width": .number(f.width), "height": .number(f.height)]
            }

            let actions = AX.actions(el).filter { !$0.hasPrefix("AXShowAlternateUI") }
            // A wrapper: a group that says nothing and does nothing. Only its contents matter.
            // (Browsers offer "show menu" and "scroll to visible" on every element, and give groups an empty value.)
            let does = actions.contains { $0 != kAXShowMenuAction && $0 != "AXScrollToVisible" }
            let says = name != nil || (node["value"].map { $0.stringValue != "" } ?? false)
            let wrapper = options.compact && depth > 0 && (role == kAXGroupRole || role == "AXGenericElement") && !says && !does
            if !wrapper {
                count += 1
                if !actions.isEmpty {
                    node["actions"] = .array(actions.map { .string(Self.shortAction($0)) })
                }
                if !actions.isEmpty || Self.interactiveRoles.contains(role) {
                    node["ref"] = .string(refs.register(RefEntry(element: el, pid: w.pid, windowID: w.id, role: role, generation: generation), index: refCount))
                    refCount += 1
                }
            }

            var children: [JSONValue] = []
            if depth < maxDepth, let kids = a[kAXChildrenAttribute] as? [AnyObject], !kids.isEmpty {
                for k in kids where CFGetTypeID(k) == AXUIElementGetTypeID() {
                    children.append(contentsOf: visit(k as! AXUIElement, depth: depth + 1))
                    if truncated { break }
                }
            } else if depth >= maxDepth { truncated = true }
            if wrapper { return children }
            if !children.isEmpty { node["children"] = .array(children) }
            return [.object(node)]
        }

        guard let tree = visit(w.ax, depth: 0).first else {
            throw DriverError(.accessibilityUnavailable, "The window's accessibility structure could not be read; use screenshot-based operations")
        }
        return Result(tree: tree, nodeCount: count, refCount: refCount, truncated: truncated, generation: generation)
    }

    static func shortAction(_ a: String) -> String {
        switch a {
        case kAXPressAction: return "press"
        case kAXConfirmAction: return "confirm"
        case kAXIncrementAction: return "increment"
        case kAXDecrementAction: return "decrement"
        case kAXShowMenuAction: return "show_menu"
        case kAXRaiseAction: return "raise"
        case kAXCancelAction: return "cancel"
        case kAXPickAction: return "pick"
        default: return a
        }
    }
}
