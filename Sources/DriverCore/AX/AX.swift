import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import CPrivate
import DriverProtocol

// Accessibility handles are immutable references to an element in another process; every call
// on them is a thread-safe IPC round trip. Declaring that once here lets the types that carry
// them be checked `Sendable` by the compiler instead of each one opting out.
extension AXUIElement: @unchecked @retroactive Sendable {}

/// Thin, failure-tolerant wrappers around the C Accessibility API.
public enum AX {
    /// Upper bound on any single AX round-trip, so an unresponsive app cannot hang the driver.
    public static let messagingTimeout: Float = 1.5

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
        return el
    }

    public static func raw(_ el: AXUIElement, _ attr: String) -> (AXError, CFTypeRef?) {
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        return (e, v)
    }

    public static func string(_ el: AXUIElement, _ attr: String) -> String? {
        let (e, v) = raw(el, attr)
        guard e == .success, let v else { return nil }
        if let s = v as? String { return s }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    public static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        let (e, v) = raw(el, attr)
        guard e == .success, let v else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    public static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        let (e, v) = raw(el, attr)
        guard e == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    public static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        let (e, v) = raw(el, attr)
        guard e == .success, let arr = v as? [AnyObject] else { return [] }
        return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    public static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        let (e, v) = raw(el, attr)
        guard e == .success, let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    public static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        let (e, v) = raw(el, attr)
        guard e == .success, let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Global frame (CoreGraphics coordinates, top-left origin).
    public static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    public static func setPosition(_ el: AXUIElement, _ p: CGPoint) -> AXError {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
    }

    @discardableResult
    public static func setSize(_ el: AXUIElement, _ s: CGSize) -> AXError {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
    }

    @discardableResult
    public static func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(el, attr as CFString, value)
    }

    public static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var b: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &b) == .success && b.boolValue
    }

    public static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let a = names as? [String] else { return [] }
        return a
    }

    @discardableResult
    public static func perform(_ el: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
    }

    public static func pid(_ el: AXUIElement) -> pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(el, &p) == .success ? p : nil
    }

    public static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        if MDAXWindowID(el, &id) == .success, id != 0 { return id }
        guard !Capabilities.axWindowLookup else { return nil }
        return windowIDByFrame(el)
    }

    /// Fallback when the private lookup is missing: the app's layer-0 window with the same frame.
    /// Ambiguous matches (two windows with identical frames) are refused rather than guessed.
    static func windowIDByFrame(_ el: AXUIElement) -> CGWindowID? {
        guard let p = pid(el), let f = frame(el),
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let matches = list.filter { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == p, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return false }
            return abs(r.minX - f.minX) <= 1 && abs(r.minY - f.minY) <= 1 && abs(r.width - f.width) <= 1 && abs(r.height - f.height) <= 1
        }
        return matches.count == 1 ? (matches[0][kCGWindowNumber as String] as? CGWindowID) : nil
    }

    /// True if the element still exists in its application.
    public static func isAlive(_ el: AXUIElement) -> Bool {
        let (e, _) = raw(el, kAXRoleAttribute)
        return e == .success
    }

    public static func windows(of pid: pid_t) -> [AXUIElement] {
        elements(app(pid), kAXWindowsAttribute)
    }

    public static func describe(_ e: AXError) -> String {
        switch e {
        case .success: return "success"
        case .apiDisabled: return "accessibility API disabled (grant Accessibility permission)"
        case .invalidUIElement: return "element no longer exists"
        case .cannotComplete: return "application did not respond"
        case .attributeUnsupported: return "attribute unsupported"
        case .actionUnsupported: return "action unsupported"
        case .notImplemented: return "not implemented by the application"
        case .illegalArgument: return "illegal argument"
        default: return "AXError \(e.rawValue)"
        }
    }

    /// Batched attribute read; missing attributes come back as nil.
    public static func multiple(_ el: AXUIElement, _ attrs: [String]) -> [String: AnyObject] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let arr = values as? [AnyObject], arr.count == attrs.count else { return [:] }
        var out: [String: AnyObject] = [:]
        for (i, a) in attrs.enumerated() {
            let v = arr[i]
            // Errors for individual attributes come back as AXValue of type .axError.
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { continue }
            out[a] = v
        }
        return out
    }
}

/// Chromium-based apps (Chrome, Edge, Electron apps) build the accessibility tree of their web
/// content only when a client asks for it. Without the request a snapshot shows the toolbar and
/// an empty page.
///
/// The request is made the first time a window of the app is read with `computer_snapshot`, not
/// before: keeping that tree up to date costs the app some CPU, and a script that works from
/// screenshots alone never needs it. It is withdrawn when the host shuts down.
///
/// Two attributes exist. Electron apps take `AXManualAccessibility`, which has no other effect.
/// Chrome only takes `AXEnhancedUserInterface`, the one VoiceOver sets; with it AppKit animates
/// window moves made through accessibility, so `suspended` switches it off around those.
public enum WebAccessibility {
    private static var manual: CFString { "AXManualAccessibility" as CFString }
    private static var enhanced: CFString { "AXEnhancedUserInterface" as CFString }
    /// pid -> whether the enhanced-interface attribute is the one in use.
    private static let enabled = Locked<[pid_t: Bool]>([:])

    /// Only for apps that have web content to expose; asking any other app would only slow its window moves.
    static func isChromium(pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return false }
        // Electron, the Chromium Embedded Framework, or a browser's own framework with its helper apps.
        return names.contains { name in
            name == "Electron Framework.framework" || name == "Chromium Embedded Framework.framework"
                || (name.hasSuffix(" Framework.framework") && FileManager.default.fileExists(atPath: frameworks.appendingPathComponent(name).appendingPathComponent("Helpers").path))
        }
    }

    /// Returns true when the request was made just now, so the caller knows the tree is still being built.
    @discardableResult
    public static func enable(pid: pid_t) -> Bool {
        if enabled.withLock({ $0[pid] != nil }) { return false }
        let app = AX.app(pid)
        if AXUIElementSetAttributeValue(app, manual, kCFBooleanTrue) == .success {
            enabled.withLock { $0[pid] = false }
            return true
        }
        guard isChromium(pid: pid), AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue) == .success else { return false }
        enabled.withLock { $0[pid] = true }
        return true
    }

    public static func isEnabled(pid: pid_t) -> Bool { enabled.withLock { $0[pid] != nil } }

    /// Runs `body` with the enhanced-interface attribute off, for window moves and resizes.
    public static func suspended<T>(pid: pid_t, _ body: () -> T) -> T {
        guard enabled.withLock({ $0[pid] }) == true else { return body() }
        let app = AX.app(pid)
        AXUIElementSetAttributeValue(app, enhanced, kCFBooleanFalse)
        defer { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue) }
        return body()
    }

    public static func withdrawAll() {
        let all = enabled.withLock { s -> [pid_t: Bool] in defer { s.removeAll() }; return s }
        for (p, usesEnhanced) in all { AXUIElementSetAttributeValue(AX.app(p), usesEnhanced ? enhanced : manual, kCFBooleanFalse) }
    }
}
