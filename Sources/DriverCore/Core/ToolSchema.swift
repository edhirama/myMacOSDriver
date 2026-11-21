import Foundation
import DriverProtocol

/// One declared parameter of a tool. The declaration is the single source for three things:
/// which keys the tool accepts, the generic checks run before the tool body (type, allowed
/// values, range, required), and the JSON Schema published by the `tools` listing.
/// Rules that span several parameters ("ref or in+x+y, never both") stay in the tool.
public struct Param: Sendable {
    public enum Kind: Sendable {
        case string
        case integer(min: Int, max: Int)
        case number
        case choice([String])
        /// Modifier names: an array, or a "+"-joined string.
        case modifiers
        /// { x, y, width, height }
        case frame
        /// [{ x, y }, ...]
        case points(min: Int, max: Int)
    }

    public let name: String
    public let kind: Kind
    public let required: Bool
    public let description: String

    public init(_ name: String, _ kind: Kind, required: Bool = false, _ description: String) {
        self.name = name; self.kind = kind; self.required = required; self.description = description
    }

    /// Present on every tool.
    public static let computer = Param("computer", .string,
        "Which display to act on: \"virtual\" (the default) or \"display:<id>\" for a physical display from status. Physical displays are never chosen implicitly.")

    static let pointSchema: JSONValue = ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]],
                                         "required": ["x", "y"]]

    public var jsonSchema: JSONValue {
        var o: [String: JSONValue] = ["description": .string(description)]
        switch kind {
        case .string: o["type"] = "string"
        case .integer(let lo, let hi): o["type"] = "integer"; o["minimum"] = .number(Double(lo)); o["maximum"] = .number(Double(hi))
        case .number: o["type"] = "number"
        case .choice(let c): o["type"] = "string"; o["enum"] = .array(c.map { .string($0) })
        case .modifiers:
            o["type"] = "array"
            o["items"] = ["type": "string", "enum": .array(Modifier.allCases.map { .string($0.rawValue) })]
        case .frame:
            o["type"] = "object"
            o["properties"] = ["x": ["type": "number"], "y": ["type": "number"],
                               "width": ["type": "number", "minimum": 1], "height": ["type": "number", "minimum": 1]]
            o["required"] = ["x", "y", "width", "height"]
        case .points(let lo, let hi):
            o["type"] = "array"; o["items"] = Self.pointSchema
            o["minItems"] = .number(Double(lo)); o["maxItems"] = .number(Double(hi))
        }
        return .object(o)
    }

    /// The generic check for one supplied value.
    func validate(_ v: JSONValue) throws {
        func bad(_ expected: String) -> DriverError { DriverError(.invalidArgument, "'\(name)' must be \(expected)") }
        switch kind {
        case .string:
            guard v.stringValue != nil else { throw bad("a string") }
        case .integer(let lo, let hi):
            guard let i = v.intValue else { throw bad("an integer") }
            guard i >= lo, i <= hi else { throw DriverError(.invalidArgument, "'\(name)' must be an integer between \(lo) and \(hi)") }
        case .number:
            guard let d = v.doubleValue, d.isFinite else { throw bad("a number") }
        case .choice(let c):
            guard let s = v.stringValue else { throw bad("a string") }
            guard c.contains(s) else {
                throw DriverError(.invalidArgument, "'\(name)' must be one of: \(c.joined(separator: ", "))", details: ["got": .string(s)])
            }
        case .modifiers:
            guard v.stringValue != nil || v.arrayValue?.allSatisfy({ $0.stringValue != nil }) == true else { throw bad("an array of modifier names") }
        case .frame:
            guard let o = v.objectValue, ["x", "y", "width", "height"].allSatisfy({ o[$0]?.doubleValue?.isFinite == true }) else {
                throw bad("an object { x, y, width, height } of numbers")
            }
        case .points(let lo, let hi):
            guard let a = v.arrayValue, a.allSatisfy({ $0.objectValue?["x"]?.doubleValue?.isFinite == true && $0.objectValue?["y"]?.doubleValue?.isFinite == true }) else {
                throw bad("an array of {x, y} points")
            }
            guard a.count >= lo else { throw DriverError(.invalidArgument, "'\(name)' needs at least \(lo) points") }
            guard a.count <= hi else { throw DriverError(.invalidArgument, "'\(name)' accepts at most \(hi) points") }
        }
    }
}

public extension ToolSpec {
    var allParams: [Param] { params + [Param.computer] }
    var allowed: Set<String> { Set(params.map { $0.name }) }

    /// Unknown keys, wrong types, out-of-range values and missing required parameters, in that
    /// order. Runs before the tool body, so none of these can have side effects.
    func validate(_ raw: [String: JSONValue]) throws {
        let known = Dictionary(uniqueKeysWithValues: allParams.map { ($0.name, $0) })
        let unknown = Set(raw.keys).subtracting(known.keys)
        if !unknown.isEmpty {
            throw DriverError(.invalidArgument, "\(name) does not accept: \(unknown.sorted().joined(separator: ", "))",
                              details: ["accepted": .array(known.keys.sorted().map { .string($0) })])
        }
        for p in allParams {
            if let v = raw[p.name], !v.isNull { try p.validate(v) }
            else if p.required { throw DriverError(.invalidArgument, "\(name) requires '\(p.name)'") }
        }
    }

    /// The published description: name, summary and a JSON Schema of the arguments (the shape
    /// MCP and most agent frameworks expect for a tool definition).
    var json: JSONValue {
        [
            "name": .string(name),
            "description": .string(summary),
            "mutating": .bool(mutating),
            "default_timeout_ms": .number(Double(defaultTimeoutMs)),
            "input_schema": [
                "type": "object",
                "properties": .object(Dictionary(uniqueKeysWithValues: allParams.map { ($0.name, $0.jsonSchema) })),
                "required": .array(allParams.filter { $0.required }.map { .string($0.name) }),
                "additionalProperties": false,
            ],
        ]
    }
}
