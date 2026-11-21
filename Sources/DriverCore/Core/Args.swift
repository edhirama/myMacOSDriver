import Foundation
import CoreGraphics
import DriverProtocol

/// Strict argument reader. Every tool declares the keys it accepts; unknown keys and wrong
/// types are rejected with `invalid_argument` so mistakes never turn into a silent default.
public struct Args: Sendable {
    public let raw: [String: JSONValue]
    public let tool: String

    public init(_ raw: [String: JSONValue], tool: String, allowed: Set<String>) throws {
        self.raw = raw; self.tool = tool
        let unknown = Set(raw.keys).subtracting(allowed.union(["computer"]))
        if !unknown.isEmpty {
            throw DriverError(.invalidArgument, "\(tool) does not accept: \(unknown.sorted().joined(separator: ", "))",
                              details: ["accepted": .array(allowed.union(["computer"]).sorted().map { .string($0) })])
        }
    }

    public func has(_ k: String) -> Bool { if let v = raw[k] { return !v.isNull }; return false }

    public func string(_ k: String) throws -> String? {
        guard let v = raw[k], !v.isNull else { return nil }
        guard let s = v.stringValue else { throw bad(k, "a string") }
        return s
    }

    public func requiredString(_ k: String) throws -> String {
        guard let s = try string(k) else { throw missing(k) }
        return s
    }

    public func int(_ k: String) throws -> Int? {
        guard let v = raw[k], !v.isNull else { return nil }
        guard let i = v.intValue else { throw bad(k, "an integer") }
        return i
    }

    public func double(_ k: String) throws -> Double? {
        guard let v = raw[k], !v.isNull else { return nil }
        guard let d = v.doubleValue, d.isFinite else { throw bad(k, "a number") }
        return d
    }

    public func requiredDouble(_ k: String) throws -> Double {
        guard let d = try double(k) else { throw missing(k) }
        return d
    }

    public func positiveInt(_ k: String, default def: Int? = nil, max: Int = 10_000) throws -> Int? {
        guard let i = try int(k) else { return def }
        guard i >= 1, i <= max else { throw DriverError(.invalidArgument, "'\(k)' must be an integer between 1 and \(max)") }
        return i
    }

    public func oneOf(_ k: String, _ allowed: [String], default def: String? = nil) throws -> String? {
        guard let s = try string(k) else { return def }
        guard allowed.contains(s) else {
            throw DriverError(.invalidArgument, "'\(k)' must be one of: \(allowed.joined(separator: ", "))",
                              details: ["got": .string(s)])
        }
        return s
    }

    /// `keys`: modifier names held during the action. Accepts an array or a "+"-joined string.
    public func modifiers(_ k: String = "keys") throws -> [Modifier] {
        guard let v = raw[k], !v.isNull else { return [] }
        var names: [String] = []
        if let s = v.stringValue { names = s.split(separator: "+").map { String($0) } }
        else if let a = v.arrayValue {
            for e in a { guard let s = e.stringValue else { throw bad(k, "an array of modifier names") }; names.append(s) }
        } else { throw bad(k, "an array of modifier names") }
        var out: [Modifier] = []
        for n in names {
            guard let m = Modifier(name: n) else {
                throw DriverError(.invalidArgument, "Unknown modifier '\(n)' in '\(k)'. Use shift, ctrl, alt, super.")
            }
            if !out.contains(m) { out.append(m) }
        }
        return out
    }

    /// `frame`: { x, y, width, height }.
    public func frame(_ k: String) throws -> CGRect? {
        guard let v = raw[k], !v.isNull else { return nil }
        guard let o = v.objectValue, let x = o["x"]?.doubleValue, let y = o["y"]?.doubleValue,
              let w = o["width"]?.doubleValue, let h = o["height"]?.doubleValue,
              [x, y, w, h].allSatisfy({ $0.isFinite }) else {
            throw bad(k, "an object { x, y, width, height } of numbers")
        }
        guard w >= 1, h >= 1 else { throw DriverError(.invalidArgument, "'\(k)' width and height must be at least 1") }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// `path`: [{x,y}, ...].
    public func points(_ k: String, min: Int) throws -> [CGPoint] {
        guard let v = raw[k], !v.isNull else { throw missing(k) }
        guard let a = v.arrayValue else { throw bad(k, "an array of {x, y} points") }
        var pts: [CGPoint] = []
        for e in a {
            guard let o = e.objectValue, let x = o["x"]?.doubleValue, let y = o["y"]?.doubleValue,
                  x.isFinite, y.isFinite else { throw bad(k, "an array of {x, y} points") }
            pts.append(CGPoint(x: x, y: y))
        }
        guard pts.count >= min else { throw DriverError(.invalidArgument, "'\(k)' needs at least \(min) points") }
        guard pts.count <= 500 else { throw DriverError(.invalidArgument, "'\(k)' accepts at most 500 points") }
        return pts
    }

    func missing(_ k: String) -> DriverError { DriverError(.invalidArgument, "\(tool) requires '\(k)'") }
    func bad(_ k: String, _ expected: String) -> DriverError { DriverError(.invalidArgument, "'\(k)' must be \(expected)") }
}

public enum Modifier: String, CaseIterable, Sendable {
    case shift, ctrl, alt, `super`

    public init?(name: String) {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "shift": self = .shift
        case "ctrl", "control": self = .ctrl
        case "alt", "option", "opt": self = .alt
        case "super", "cmd", "command", "meta": self = .super
        default: return nil
        }
    }

    public var flag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .ctrl: return .maskControl
        case .alt: return .maskAlternate
        case .super: return .maskCommand
        }
    }

    /// Virtual key code of the left-hand modifier key.
    public var keyCode: CGKeyCode {
        switch self {
        case .shift: return 0x38
        case .ctrl: return 0x3B
        case .alt: return 0x3A
        case .super: return 0x37
        }
    }
}

public extension Array where Element == Modifier {
    var flags: CGEventFlags { reduce(into: CGEventFlags()) { $0.insert($1.flag) } }
}

/// The two mutually exclusive position forms.
public enum PositionArg: Sendable {
    case screenshot(id: String, x: Double, y: Double)
    case ref(String)

    public static func parse(_ a: Args, required: Bool = true) throws -> PositionArg? {
        let hasIn = a.has("in"), hasX = a.has("x"), hasY = a.has("y"), hasRef = a.has("ref")
        if hasRef && (hasIn || hasX || hasY) {
            throw DriverError(.invalidArgument, "Use either 'ref' or 'in' + 'x' + 'y', not both")
        }
        if hasRef { return .ref(try a.requiredString("ref")) }
        if hasIn || hasX || hasY {
            guard hasIn, hasX, hasY else {
                throw DriverError(.invalidArgument, "Screenshot positions need all of 'in', 'x' and 'y'")
            }
            return .screenshot(id: try a.requiredString("in"), x: try a.requiredDouble("x"), y: try a.requiredDouble("y"))
        }
        if required { throw DriverError(.invalidArgument, "\(a.tool) requires a position: 'ref', or 'in' + 'x' + 'y'") }
        return nil
    }
}
