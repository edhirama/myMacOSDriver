import Foundation
import ApplicationServices
import CoreGraphics

/// Text-specific accessibility helpers: caret/selection ranges and point → character mapping.
public enum AXText {
    public static func selectedRange(_ el: AXUIElement) -> CFRange? {
        let (e, v) = AX.raw(el, kAXSelectedTextRangeAttribute)
        guard e == .success, let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    @discardableResult
    public static func setSelectedRange(_ el: AXUIElement, _ r: CFRange) -> AXError {
        var r = r
        guard let v = AXValueCreate(.cfRange, &r) else { return .failure }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
    }

    /// Screen bounds of a character range (AXBoundsForRange).
    public static func bounds(_ r: CFRange, in el: AXUIElement) -> CGRect? {
        var r = r
        guard let arg = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(out as! AXValue, .cgRect, &rect) ? rect : nil
    }

    public static func length(_ el: AXUIElement) -> Int {
        if let n = (AX.raw(el, kAXNumberOfCharactersAttribute).1 as? NSNumber)?.intValue { return n }
        return AX.string(el, kAXValueAttribute)?.utf16.count ?? 0
    }

    /// Caret index a real click at `p` would produce. AXRangeForPosition answers 0 for points
    /// outside the laid-out lines (e.g. the empty area below the text), whereas AppKit snaps to
    /// the nearest line; this does the same by clamping to the first/last line.
    public static func index(at p: CGPoint, in el: AXUIElement) -> Int? {
        guard let i = rawIndex(at: p, in: el) else { return nil }
        let n = length(el)
        guard n > 0 else { return 0 }
        func onLine(_ idx: Int) -> Bool {
            guard idx < n, let b = bounds(CFRange(location: idx, length: 1), in: el), b.height > 0 else { return false }
            return p.y >= b.minY - 1 && p.y <= b.maxY + 1
        }
        if onLine(i) {
            // Right of the line's last glyph (no glyph under the point): end of that line.
            if let b = bounds(CFRange(location: i, length: 1), in: el), p.x > b.maxX + 1,
               let lr = lineRange(at: i, in: el) {
                var end = lr.location + lr.length
                if end > 0, end <= n, let s = AX.string(el, kAXValueAttribute) {
                    let u = Array(s.utf16)
                    if end - 1 < u.count, u[end - 1] == 0x0A || u[end - 1] == 0x0D { end -= 1 }
                }
                // Only when the point really is past the last glyph of that line.
                if end > i, let lastGlyph = bounds(CFRange(location: max(lr.location, end - 1), length: 1), in: el), p.x > lastGlyph.maxX {
                    return end
                }
                if end <= i { return end }
            }
            return i
        }
        guard let first = bounds(CFRange(location: 0, length: 1), in: el),
              let last = bounds(CFRange(location: n - 1, length: 1), in: el) else { return i }
        if p.y < first.minY {
            return rawIndex(at: CGPoint(x: p.x, y: first.midY), in: el) ?? 0
        }
        if p.y > last.maxY {
            // Below the text: same x on the last line, or the very end when past its last glyph.
            if p.x >= last.maxX { return n }
            if let j = rawIndex(at: CGPoint(x: p.x, y: last.midY), in: el), onLine(j) || j == n - 1 { return j }
            return n
        }
        return i
    }

    private static func rawIndex(at p: CGPoint, in el: AXUIElement) -> Int? {
        var pt = p
        guard let arg = AXValueCreate(.cgPoint, &pt) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForPositionParameterizedAttribute as CFString, arg, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(out as! AXValue, .cfRange, &r) ? r.location : nil
    }

    /// Range of the line containing `index`.
    public static func lineRange(at index: Int, in el: AXUIElement) -> CFRange? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXLineForIndexParameterizedAttribute as CFString, index as CFNumber, &out) == .success,
              let line = (out as? NSNumber)?.intValue else { return nil }
        var rv: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForLineParameterizedAttribute as CFString, line as CFNumber, &rv) == .success,
              let rv, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(rv as! AXValue, .cfRange, &r) ? r : nil
    }

    /// Range of the word containing `index` in the element's value (letters, digits, underscore).
    public static func wordRange(at index: Int, in el: AXUIElement) -> CFRange? {
        guard let s = AX.string(el, kAXValueAttribute) else { return nil }
        let u = Array(s.utf16)
        guard !u.isEmpty else { return CFRange(location: 0, length: 0) }
        let i = min(max(0, index), u.count - 1)
        func isWord(_ c: UInt16) -> Bool {
            guard let sc = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(sc) || c == 0x5F
        }
        guard isWord(u[i]) else { return CFRange(location: i, length: 1) }
        var a = i, b = i
        while a > 0 && isWord(u[a - 1]) { a -= 1 }
        while b + 1 < u.count && isWord(u[b + 1]) { b += 1 }
        return CFRange(location: a, length: b - a + 1)
    }

    /// The text element under a global point within an app, if it supports caret placement.
    public static func editableText(at p: CGPoint, pid: pid_t) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AX.app(pid), Float(p.x), Float(p.y), &el) == .success, var cur = el else { return nil }
        for _ in 0..<4 {
            let role = AX.string(cur, kAXRoleAttribute) ?? ""
            if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"].contains(role) {
                return AX.isSettable(cur, kAXSelectedTextRangeAttribute) ? cur : nil
            }
            guard let parent = AX.element(cur, kAXParentAttribute) else { break }
            cur = parent
        }
        return nil
    }
}
