import Foundation

/// Wire protocol between `driver.call` clients and the host app.
///
/// Transport: a Unix domain socket carrying newline-delimited JSON (one object per line).
/// See docs/PROTOCOL.md for the full contract.
public enum DriverProtocol {
    public static let version = 1

    /// Default socket path. Override with the MACDRIVER_SOCKET environment variable.
    public static var defaultSocketPath: String {
        if let p = ProcessInfo.processInfo.environment["MACDRIVER_SOCKET"], !p.isEmpty { return p }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacDriver", isDirectory: true)
        return base.appendingPathComponent("driver.sock").path
    }

    public static let toolNames: [String] = [
        "computer_apps", "computer_open", "computer_screenshot", "computer_snapshot",
        "computer_click", "computer_drag", "computer_scroll", "computer_type",
        "computer_key", "computer_window", "computer_close",
    ]
}

/// A tool call: `{ "id"?, "name", "arguments"?, "timeout_ms"? }`.
public struct ToolRequest: Sendable, Equatable {
    /// Idempotency key: re-sending the same id never repeats side effects. Optional on the wire;
    /// when the client omits it, `InboundMessage.parse` generates one (`auto-<uuid>`), so it is
    /// always set here. A generated id gives no retry protection, since the client never learns
    /// it before a lost reply: clients that may retry must send their own.
    public var id: String
    public var name: String
    public var arguments: [String: JSONValue]
    public var timeoutMs: Int?

    public init(id: String, name: String, arguments: [String: JSONValue] = [:], timeoutMs: Int? = nil) {
        self.id = id; self.name = name; self.arguments = arguments; self.timeoutMs = timeoutMs
    }

    /// Stable fingerprint used to detect an id being reused for a different request.
    public var fingerprint: String {
        let v: JSONValue = .object(["name": .string(name), "arguments": .object(arguments)])
        return (try? String(data: v.jsonData(), encoding: .utf8)) ?? name
    }
}

/// Whether input reached the target application.
public enum DispatchState: String, Sendable, Codable {
    /// No input events or AX actions were performed (observation tools, or rejected before acting).
    case none
    /// All input for the call was delivered to the target.
    case dispatched
    /// Some but not all input was delivered (cancelled or interrupted midway).
    case partial
    /// The host stopped while the call was running, so how much was delivered is not known.
    case unknown
}

/// What the driver could observe about the call's effect on the application.
public struct Effect: Sendable, Equatable {
    public var confirmed: Bool
    public var evidence: [String]
    public init(confirmed: Bool, evidence: [String] = []) { self.confirmed = confirmed; self.evidence = evidence }

    public var json: JSONValue { .object(["confirmed": .bool(confirmed), "evidence": .array(evidence.map { .string($0) })]) }
}

public enum ErrorCode: String, Sendable, Codable, CaseIterable {
    case invalidRequest = "invalid_request"
    case unknownTool = "unknown_tool"
    case invalidArgument = "invalid_argument"
    case unknownTarget = "unknown_target"
    case targetUnavailable = "target_unavailable"
    case unknownApp = "unknown_app"
    case unknownWindow = "unknown_window"
    case windowNotOnTarget = "window_not_on_target"
    case unknownScreenshot = "unknown_screenshot"
    case staleScreenshot = "stale_screenshot"
    case staleRef = "stale_ref"
    case outOfBounds = "out_of_bounds"
    case noInputTarget = "no_input_target"
    case userHasControl = "user_has_control"
    /// A call paused by a takeover found its target changed when control came back.
    case targetChanged = "target_changed"
    case cancelled = "cancelled"
    case timeout = "timeout"
    case idConflict = "id_conflict"
    /// The host restarted while this request was running; it was not run again.
    case unknownOutcome = "unknown_outcome"
    case accessibilityUnavailable = "accessibility_unavailable"
    case permissionMissing = "permission_missing"
    case unsupported = "unsupported"
    case actionFailed = "action_failed"
    case notReady = "not_ready"
    case internalError = "internal_error"
}

public struct DriverError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: ErrorCode
    public var message: String
    public var details: [String: JSONValue]

    public init(_ code: ErrorCode, _ message: String, details: [String: JSONValue] = [:]) {
        self.code = code; self.message = message; self.details = details
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["code": .string(code.rawValue), "message": .string(message)]
        if !details.isEmpty { o["details"] = .object(details) }
        return .object(o)
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

/// A tool call response. Exactly one of `result` / `error` is meaningful, selected by `ok`.
public struct ToolResponse: Sendable, Equatable {
    public var id: String
    public var name: String
    public var ok: Bool
    public var result: JSONValue
    public var error: DriverError?
    public var dispatch: DispatchState
    public var effect: Effect
    public var warnings: [String]
    /// True when this response was served from the idempotency ledger instead of executing again.
    public var replayed: Bool
    public var durationMs: Int
    /// Time the call spent paused because the user had control (included in `durationMs`).
    public var pausedMs: Int

    public init(id: String, name: String, ok: Bool, result: JSONValue = .null, error: DriverError? = nil,
                dispatch: DispatchState = .none, effect: Effect = Effect(confirmed: false),
                warnings: [String] = [], replayed: Bool = false, durationMs: Int = 0, pausedMs: Int = 0) {
        self.id = id; self.name = name; self.ok = ok; self.result = result; self.error = error
        self.dispatch = dispatch; self.effect = effect; self.warnings = warnings
        self.replayed = replayed; self.durationMs = durationMs; self.pausedMs = pausedMs
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "ok": .bool(ok),
            "dispatch": .string(dispatch.rawValue), "effect": effect.json,
            "warnings": .array(warnings.map { .string($0) }),
            "replayed": .bool(replayed), "duration_ms": .number(Double(durationMs)),
        ]
        if pausedMs > 0 { o["paused_ms"] = .number(Double(pausedMs)) }
        if ok { o["result"] = result } else { o["error"] = error?.json ?? .null; if !result.isNull { o["result"] = result } }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue, let id = o["id"]?.stringValue, let ok = o["ok"]?.boolValue else { return nil }
        self.id = id
        self.name = o["name"]?.stringValue ?? ""
        self.ok = ok
        self.result = o["result"] ?? .null
        if let e = o["error"]?.objectValue, let c = e["code"]?.stringValue {
            self.error = DriverError(ErrorCode(rawValue: c) ?? .internalError, e["message"]?.stringValue ?? "",
                                     details: e["details"]?.objectValue ?? [:])
        } else { self.error = nil }
        self.dispatch = DispatchState(rawValue: o["dispatch"]?.stringValue ?? "none") ?? .none
        let eff = o["effect"]?.objectValue
        self.effect = Effect(confirmed: eff?["confirmed"]?.boolValue ?? false,
                             evidence: eff?["evidence"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
        self.warnings = o["warnings"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        self.replayed = o["replayed"]?.boolValue ?? false
        self.durationMs = o["duration_ms"]?.intValue ?? 0
        self.pausedMs = o["paused_ms"]?.intValue ?? 0
    }
}

/// Parsing of a single inbound line from a client.
public enum InboundMessage: Sendable, Equatable {
    case call(ToolRequest)
    case cancel(id: String)
    case status(id: String?)
    /// Lists every tool with a JSON Schema of its arguments.
    case tools(id: String?)
    /// Test-only: simulate the user's Take Control / Give Back (host must run with --test-ops).
    case testControl(op: String)
    /// Test-only: simulate the user's input in the mirror window during takeover (--test-ops).
    case testUserInput([String: JSONValue])

    public static func parse(_ value: JSONValue, generateId: () -> String) throws -> InboundMessage {
        guard let o = value.objectValue else { throw DriverError(.invalidRequest, "Message must be a JSON object") }
        if let op = o["op"] {
            guard let ops = op.stringValue else { throw DriverError(.invalidRequest, "op must be a string") }
            switch ops {
            case "cancel":
                guard let id = o["id"]?.stringValue else { throw DriverError(.invalidRequest, "cancel requires id") }
                return .cancel(id: id)
            case "status": return .status(id: o["id"]?.stringValue)
            case "tools": return .tools(id: o["id"]?.stringValue)
            case "test_take_control", "test_give_back": return .testControl(op: ops)
            case "test_user_input": return .testUserInput(o)
            case "call": break
            default: throw DriverError(.invalidRequest, "Unknown op '\(ops)'")
            }
        }
        guard let name = o["name"]?.stringValue, !name.isEmpty else {
            throw DriverError(.invalidRequest, "Request requires a string 'name'")
        }
        var args: [String: JSONValue] = [:]
        if let a = o["arguments"], !a.isNull {
            guard let ao = a.objectValue else { throw DriverError(.invalidRequest, "'arguments' must be an object") }
            args = ao
        }
        let id: String
        if let rawId = o["id"], !rawId.isNull {
            guard let s = rawId.stringValue, !s.isEmpty, s.count <= 200 else {
                throw DriverError(.invalidRequest, "'id' must be a non-empty string of at most 200 characters")
            }
            id = s
        } else { id = generateId() }
        var timeout: Int?
        if let t = o["timeout_ms"], !t.isNull {
            guard let ti = t.intValue, ti > 0 else { throw DriverError(.invalidRequest, "'timeout_ms' must be a positive integer") }
            timeout = ti
        }
        return .call(ToolRequest(id: id, name: name, arguments: args, timeoutMs: timeout))
    }
}
