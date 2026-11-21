import Foundation
import DriverProtocol

/// Idempotency ledger keyed by the request id.
///
/// - A request whose id is already running attaches to the running execution (no second run).
/// - A request whose id already completed returns the stored response with `replayed: true`.
/// - Reusing an id for a different request (different name/arguments) is rejected.
/// - Responses that performed no side effects (`dispatch: none` and not ok) are not stored, so a
///   caller can safely retry after e.g. `user_has_control` or `timeout` before dispatch.
///
/// With a journal file the guarantee also holds across a host restart or crash. Calls that can
/// have side effects are written to the journal when they start and when they finish. After a
/// restart, a finished id is replayed as before, and an id that started but never finished is
/// answered with `dispatch: unknown` instead of being run a second time.
public actor RequestLedger {
    enum Entry {
        case running(fingerprint: String, task: Task<ToolResponse, Never>)
        case done(fingerprint: String, response: ToolResponse)
        /// Started by a previous host process that stopped before the call finished.
        case interrupted(fingerprint: String, name: String)
    }

    private var entries = LRUCache<String, Entry>(capacity: RequestLedger.capacity)
    private let journal: Journal?
    static let capacity = 1024
    /// How long a journaled request is remembered across restarts, in seconds.
    static let retention: TimeInterval = 24 * 3600
    private var appended = 0
    /// When each journaled request started (seconds since 1970), kept across rewrites so that
    /// records age out.
    private var stamps: [String: Double] = [:]

    public init(journalURL: URL? = nil) {
        guard let journalURL else { journal = nil; return }
        let j = Journal(url: journalURL)
        journal = j
        // Rebuild from the previous process's journal, then rewrite it without dead records.
        var order: [String] = []
        var loaded: [String: Entry] = [:]
        // Nobody retries a request a day later; older records are dropped so they cannot pile up.
        let oldest = Date().timeIntervalSince1970 - RequestLedger.retention
        for rec in j.load() {
            guard let id = rec["id"]?.stringValue, let t = rec["t"]?.stringValue else { continue }
            let ts = rec["ts"]?.doubleValue ?? 0
            if t != "drop", ts < oldest { continue }
            if t != "drop" { stamps[id] = ts }
            switch t {
            case "start":
                guard let fp = rec["fp"]?.stringValue else { continue }
                if loaded[id] == nil { order.append(id) }
                loaded[id] = .interrupted(fingerprint: fp, name: rec["name"]?.stringValue ?? "")
            case "done":
                guard let fp = rec["fp"]?.stringValue, let r = rec["response"].flatMap({ ToolResponse(json: $0) }) else { continue }
                if loaded[id] == nil { order.append(id) }
                loaded[id] = .done(fingerprint: fp, response: r)
            case "drop": loaded[id] = nil
            default: continue
            }
        }
        var keep: [JSONValue] = []
        for id in order.suffix(RequestLedger.capacity) {
            guard let e = loaded[id] else { continue }
            entries[id] = e
            switch e {
            case .interrupted(let fp, let name): keep.append(Journal.start(id: id, fingerprint: fp, name: name, ts: stamps[id] ?? 0))
            case .done(let fp, let r): keep.append(Journal.done(id: id, fingerprint: fp, response: r, ts: stamps[id] ?? 0))
            case .running: break
            }
        }
        stamps = stamps.filter { loaded[$0.key] != nil }
        j.rewrite(keep)
    }

    /// `journaled` is true for calls that can have side effects; only those need to survive a restart.
    public func run(_ req: ToolRequest, journaled: Bool = false, _ op: @escaping @Sendable () async -> ToolResponse) async -> ToolResponse {
        let fp = req.fingerprint
        if let e = entries[req.id] {
            switch e {
            case .running(let f, let task):
                guard f == fp else { return conflict(req) }
                var r = await task.value
                r.replayed = true
                return r
            case .done(let f, let resp):
                guard f == fp else { return conflict(req) }
                var r = resp
                r.replayed = true
                return r
            case .interrupted(let f, _):
                guard f == fp else { return conflict(req) }
                return ToolResponse(id: req.id, name: req.name, ok: false,
                                    error: DriverError(.unknownOutcome, "The host stopped while this request was running, so it is not known how much of its input was sent. It was not run again. Observe the current state, then continue under a new id",
                                                       details: ["retry_with_new_id": .bool(true)]),
                                    dispatch: .unknown, replayed: true)
            }
        }
        let task = Task { await op() }
        entries[req.id] = .running(fingerprint: fp, task: task)
        let now = Date().timeIntervalSince1970.rounded()
        if journaled, journal != nil { stamps[req.id] = now; journal?.append(Journal.start(id: req.id, fingerprint: fp, name: req.name, ts: now)); appended += 1 }
        let resp = await task.value
        if resp.ok || resp.dispatch != .none {
            entries[req.id] = .done(fingerprint: fp, response: resp)
            if journaled { journal?.append(Journal.done(id: req.id, fingerprint: fp, response: resp, ts: now)) }
        } else {
            entries[req.id] = nil
            if journaled { journal?.append(["t": "drop", "id": .string(req.id)]); stamps[req.id] = nil }
        }
        if journaled { compactIfNeeded() }
        return resp
    }

    /// The journal only grows by appending; once it holds several times more records than the
    /// ledger remembers, rewrite it from what is still remembered.
    private func compactIfNeeded() {
        guard let journal, appended >= RequestLedger.capacity * 4 else { return }
        appended = 0
        var keep: [JSONValue] = []
        for (id, e) in entries.items {
            switch e {
            case .running(let fp, _): keep.append(Journal.start(id: id, fingerprint: fp, name: "", ts: stamps[id] ?? 0))
            case .interrupted(let fp, let name): keep.append(Journal.start(id: id, fingerprint: fp, name: name, ts: stamps[id] ?? 0))
            case .done(let fp, let r): keep.append(Journal.done(id: id, fingerprint: fp, response: r, ts: stamps[id] ?? 0))
            }
        }
        journal.rewrite(keep)
    }

    /// Cancels a running request. Returns false if the id is unknown or already finished.
    public func cancel(_ id: String) -> Bool {
        guard let e = entries[id], case .running(_, let task) = e else { return false }
        task.cancel()
        return true
    }

    public func cancelAll() {
        for e in entries.values { if case .running(_, let t) = e { t.cancel() } }
    }

    public var inFlight: Int {
        entries.values.reduce(0) { n, e in if case .running = e { return n + 1 }; return n }
    }

    /// Requests a previous host process left unfinished.
    public var interrupted: Int {
        entries.values.reduce(0) { n, e in if case .interrupted = e { return n + 1 }; return n }
    }

    private func conflict(_ req: ToolRequest) -> ToolResponse {
        ToolResponse(id: req.id, name: req.name, ok: false,
                     error: DriverError(.idConflict, "Request id '\(req.id)' was already used for a different request"))
    }
}

/// Append-only file of JSON lines behind the ledger. A plain write is enough to survive the host
/// process dying, which is the failure this protects against (it is not synced against power loss).
final class Journal: @unchecked Sendable {
    private let url: URL
    private var handle: FileHandle?
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    static func start(id: String, fingerprint: String, name: String, ts: Double) -> JSONValue {
        ["t": "start", "id": .string(id), "fp": .string(fingerprint), "name": .string(name), "ts": .number(ts)]
    }
    static func done(id: String, fingerprint: String, response: ToolResponse, ts: Double) -> JSONValue {
        ["t": "done", "id": .string(id), "fp": .string(fingerprint), "response": response.json, "ts": .number(ts)]
    }

    func load() -> [[String: JSONValue]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // A torn last line (the process died mid-write) simply fails to parse and is skipped.
        return data.split(separator: 0x0A).compactMap { (try? JSONDecoder().decode(JSONValue.self, from: Data($0)))?.objectValue }
    }

    func rewrite(_ records: [JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close(); handle = nil
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for r in records { if let d = try? r.jsonData() { data.append(d); data.append(0x0A) } }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { Log.driver.error("Request journal unavailable: \(error.localizedDescription)") }
    }

    func append(_ record: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        guard var data = try? record.jsonData() else { return }
        data.append(0x0A)
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        do { try handle?.write(contentsOf: data) } catch { Log.driver.error("Request journal write failed: \(error.localizedDescription)") }
    }
}
