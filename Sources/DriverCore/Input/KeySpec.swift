import Foundation
import CoreGraphics
import DriverProtocol

/// A parsed key or key combination such as `Return`, `ArrowLeft`, `super+a`, `ctrl+shift+Tab`.
public struct KeySpec: Equatable, Sendable {
    public var modifiers: [Modifier]
    /// nil when the spec is a bare modifier (e.g. "shift").
    public var keyCode: CGKeyCode?
    public var display: String

    public static func parse(_ raw: String) throws -> KeySpec {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { throw DriverError(.invalidArgument, "'key' must not be empty") }
        var parts: [String]
        if s == "+" { parts = ["+"] }
        else if s.hasSuffix("++") { parts = s.dropLast(2).split(separator: "+").map(String.init) + ["+"] }
        else { parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init) }
        if parts.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw DriverError(.invalidArgument, "Malformed key combination '\(raw)'")
        }
        var mods: [Modifier] = []
        let keyPart = parts.removeLast()
        for p in parts {
            guard let m = Modifier(name: p) else {
                throw DriverError(.invalidArgument, "Unknown modifier '\(p)' in '\(raw)'. Use shift, ctrl, alt, super.")
            }
            if !mods.contains(m) { mods.append(m) }
        }
        if let m = Modifier(name: keyPart) {
            if !mods.contains(m) { mods.append(m) }
            return KeySpec(modifiers: mods, keyCode: nil, display: raw)
        }
        guard let (code, implied) = Self.lookup(keyPart) else {
            throw DriverError(.invalidArgument, "Unknown key '\(keyPart)' in '\(raw)'",
                              details: ["examples": ["Return", "Tab", "Escape", "Backspace", "Delete", "ArrowLeft", "PageDown", "F5", "super+a"]])
        }
        for m in implied where !mods.contains(m) { mods.append(m) }
        return KeySpec(modifiers: mods, keyCode: code, display: raw)
    }

    static let named: [String: CGKeyCode] = [
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "spacebar": 0x31,
        "backspace": 0x33, "delete": 0x33, "forwarddelete": 0x75, "del": 0x75,
        "escape": 0x35, "esc": 0x35,
        "arrowleft": 0x7B, "left": 0x7B, "arrowright": 0x7C, "right": 0x7C,
        "arrowdown": 0x7D, "down": 0x7D, "arrowup": 0x7E, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79, "help": 0x72, "insert": 0x72,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B, "f15": 0x71,
        "capslock": 0x39, "keypadenter": 0x4C,
        "minus": 0x1B, "equal": 0x18, "equals": 0x18, "plus": 0x18, "comma": 0x2B, "period": 0x2F,
        "slash": 0x2C, "backslash": 0x2A, "semicolon": 0x29, "quote": 0x27, "backquote": 0x32, "grave": 0x32,
        "bracketleft": 0x21, "bracketright": 0x1E,
    ]

    /// US ANSI key codes for printable characters (unshifted).
    static let chars: [Character: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
        "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32, " ": 0x31,
    ]

    /// Shifted characters -> base character.
    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func lookup(_ k: String) -> (CGKeyCode, [Modifier])? {
        let norm = k.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if k.count > 1, let c = named[norm] { return (c, []) }
        if k.count == 1, let ch = k.first {
            if let c = chars[Character(ch.lowercased())] { return (c, []) }
            if let base = shifted[ch], let c = chars[base] { return (c, [.shift]) }
        }
        if let c = named[norm] { return (c, []) }
        return nil
    }
}
