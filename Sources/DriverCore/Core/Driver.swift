import Foundation
import AppKit
import CoreGraphics
import DriverProtocol

/// Per-call state: what was dispatched, what was observed, and the gate every tool passes
/// before each individual input event.
public final class CallContext: Sendable {
    public let request: ToolRequest
    public let target: Target
    public let mutating: Bool
    public let deadlineMs: Int
    /// True for actions the human started from the host UI: they are not subject to the arbiter.
    public let asUser: Bool
    /// Owns the buttons and keys this call holds down, so only they are released when it ends.
    public let inputOwner: InputOwner
    let driver: Driver

    private struct State {
        var events = 0
        var evidence: [String] = []
        var warnings: [String] = []
        var confirmed = false
        var pausedMs = 0
        var pauses = 0
        var paused = false
        var releasedInputs = 0
        /// Each guard captures the state its tool depends on when a pause begins and returns
        /// the check to run when the call resumes.
        var resumeGuards: [@Sendable () -> (@Sendable () throws -> Void)] = []
    }
    private let state = Locked(State())

    init(request: ToolRequest, target: Target, mutating: Bool, driver: Driver, deadlineMs: Int, asUser: Bool = false) {
        self.request = request; self.target = target; self.mutating = mutating; self.driver = driver
        self.deadlineMs = deadlineMs; self.asUser = asUser; self.inputOwner = .call(asUser: asUser)
    }

    /// Must be called before each input event.
    ///
    /// - Cancelled or timed out: throws, so the call stops at a safe boundary.
    /// - The user has control: the call *pauses* here, having sent nothing more, and continues
    ///   after Give Back once every resume guard confirms its target is unchanged.
    /// - A takeover that found this call holding a button or key (mid-drag): the gesture was
    ///   released and cannot be continued, so the call fails instead of resuming.
    public func gate() async throws {
        try Task.checkCancellation()
        guard mutating, !asUser else { return }
        let d = driver
        if d.arbiter.owner == .user {
            d.inputLedger.releaseForTakeover()
            try checkGestureIntact()
            // Let input already sent reach the app before recording what "unchanged" means.
            try await sleepMs(120)
            let guards = state.withLock { s in s.paused = true; return s.resumeGuards }
            let checks = guards.map { $0() }
            defer { state.withLock { $0.paused = false } }
            let waited = try await d.arbiter.waitForAgent(deadlineMs: deadlineMs, dispatchedEvents: events)
            state.withLock { $0.pausedMs += waited; $0.pauses += 1 }
            try Task.checkCancellation()
            for c in checks { try c() }
            evidence("resumed_after_takeover")
        }
        try checkGestureIntact()
    }

    private func checkGestureIntact() throws {
        if driver.inputLedger.wasInterrupted(inputOwner) {
            throw DriverError(.userHasControl, "The user took control in the middle of a held gesture; the held input was released and the gesture cannot be resumed",
                              details: ["resumable": .bool(false)])
        }
    }

    /// Registers what must still be true for this call to continue after a takeover. `capture`
    /// runs when the pause begins; the closure it returns runs on resume and throws to stop.
    public func guardResume(_ capture: @escaping @Sendable () -> (@Sendable () throws -> Void)) {
        state.withLock { $0.resumeGuards.append(capture) }
    }

    /// Buttons and keys this call still held when it ended, which the driver released for it.
    func noteReleased(_ n: Int) { guard n > 0 else { return }; state.withLock { $0.releasedInputs += n } }
    var releasedInputs: Int { state.withLock { $0.releasedInputs } }

    func notePause(_ ms: Int) { guard ms > 0 else { return }; state.withLock { $0.pausedMs += ms; $0.pauses += 1 } }

    public func dispatched(_ n: Int = 1) { state.withLock { $0.events += n } }
    public func evidence(_ e: String) { state.withLock { if !$0.evidence.contains(e) { $0.evidence.append(e) } } }
    public func warn(_ w: String) { state.withLock { $0.warnings.append(w) } }
    public func confirm(_ e: String? = nil) { state.withLock { $0.confirmed = true }; if let e { evidence(e) } }

    public var events: Int { state.withLock { $0.events } }
    var isPaused: Bool { state.withLock { $0.paused } }
    var pause: (ms: Int, count: Int) { state.withLock { ($0.pausedMs, $0.pauses) } }
    var snapshot: (events: Int, evidence: [String], warnings: [String], confirmed: Bool) {
        state.withLock { s in
            var w = s.warnings
            if s.pauses > 0 { w.insert("Paused \(s.pausedMs) ms while the user had control", at: 0) }
            return (s.events, s.evidence, w, s.confirmed)
        }
    }

    /// This call's view of the router's hooks: pause at the gate, record what happened.
    var hooks: InputRouter.Hooks {
        var h = InputRouter.Hooks(owner: inputOwner)
        h.gate = { [self] in try await self.gate() }
        h.dispatched = { [self] n in self.dispatched(n) }
        h.evidence = { [self] e in self.evidence(e) }
        h.confirm = { [self] e in self.confirm(e) }
        h.warn = { [self] w in self.warn(w) }
        return h
    }
}

/// Declares a tool: what it does, its parameters (see ToolSchema.swift), whether it changes
/// anything, and its implementation.
public struct ToolSpec: Sendable {
    public let name: String
    public let summary: String
    public let mutating: Bool
    public let params: [Param]
    public let defaultTimeoutMs: Int
    public let run: @Sendable (CallContext, Args) async throws -> JSONValue

    public init(name: String, summary: String, mutating: Bool, params: [Param], defaultTimeoutMs: Int,
                run: @escaping @Sendable (CallContext, Args) async throws -> JSONValue) {
        self.name = name; self.summary = summary; self.mutating = mutating; self.params = params
        self.defaultTimeoutMs = defaultTimeoutMs; self.run = run
    }
}

/// The driver: a single `call(request)` entry point that validates, arbitrates, executes and
/// reports one tool call. Everything else in DriverCore exists to serve this.
public final class Driver: @unchecked Sendable {
    public let display: VirtualDisplayManager
    public let targets: TargetRegistry
    public let windows = WindowService()
    public let capture = ScreenshotService()
    public let refs = RefRegistry()
    public lazy var snapshots = SnapshotService(refs: refs)
    public let poster = EventPoster()
    public lazy var inputLedger = InputLedger(poster: poster)
    public lazy var router = InputRouter(poster: poster, ledger: inputLedger, windows: windows)
    public let arbiter = ControlArbiter()
    public let ledger: RequestLedger
    public let screenshots = ScreenshotRegistry()
    public let focus = FocusRegistry()

    /// Capabilities only the host can judge (e.g. whether its pointer barrier is running).
    public let hostCapabilities = Locked<[@Sendable () -> Capability]>([])
    /// Extra status fields supplied by the host app (the pointer report).
    public let hostStatus = Locked<(@Sendable () -> [String: JSONValue])?>(nil)

    private var tools: [String: ToolSpec] = [:]
    private let targetLocks = Locked<[String: AsyncLock]>([:])
    public let startedAt = Date()

    /// `journalURL`: where the idempotency ledger is persisted so it survives a host restart.
    public init(display: VirtualDisplayManager, journalURL: URL? = nil) {
        self.display = display
        self.ledger = RequestLedger(journalURL: journalURL)
        self.targets = TargetRegistry(display: display)
        for t in Tools.all(self) { tools[t.name] = t }
        arbiter.observe { [weak self] owner in
            guard let self, owner == .user else { return }
            // The user may click anywhere during takeover; a previous input location can no
            // longer be trusted.
            self.focus.clearAll()
            self.inputLedger.releaseForTakeover()
        }
    }

    public var toolNames: [String] { tools.keys.sorted() }
    /// Every tool's published definition, for the `tools` listing.
    public var toolSpecs: [ToolSpec] { toolNames.compactMap { tools[$0] } }

    private func lock(for target: String) -> AsyncLock {
        targetLocks.withLock { d in
            if let l = d[target] { return l }
            let l = AsyncLock(); d[target] = l; return l
        }
    }

    /// The single entry point.
    public func call(_ req: ToolRequest) async -> ToolResponse {
        await ledger.run(req, journaled: tools[req.name]?.mutating ?? false) { [self] in await self.execute(req) }
    }

    public func cancel(_ id: String) async -> Bool { await ledger.cancel(id) }

    func execute(_ req: ToolRequest, asUser: Bool = false) async -> ToolResponse {
        let started = monotonicMs()
        guard let spec = tools[req.name] else {
            return ToolResponse(id: req.id, name: req.name, ok: false,
                                error: DriverError(.unknownTool, "Unknown tool '\(req.name)'",
                                                   details: ["tools": .array(toolNames.map { .string($0) })]))
        }
        let timeout = min(req.timeoutMs ?? spec.defaultTimeoutMs, 600_000)
        let deadline = started + timeout
        var ctx: CallContext?
        defer { if let ctx { inputLedger.forget(ctx.inputOwner) } }
        do {
            try spec.validate(req.arguments)
            let args = try Args(req.arguments, tool: spec.name, allowed: spec.allowed)
            let target = try targets.resolve(try args.string("computer"))
            let c = CallContext(request: req, target: target, mutating: spec.mutating, driver: self, deadlineMs: deadline, asUser: asUser)
            ctx = c
            let result = try await withDeadline(deadline) { [self] in
                try await self.runGuarded(spec, c, args, deadline: deadline)
            }
            let s = c.snapshot
            return ToolResponse(id: req.id, name: req.name, ok: true, result: result,
                                dispatch: s.events > 0 ? .dispatched : .none,
                                effect: Effect(confirmed: s.confirmed, evidence: s.evidence),
                                warnings: s.warnings, durationMs: monotonicMs() - started, pausedMs: c.pause.ms)
        } catch {
            // Usually the call's own cleanup in `runGuarded` has already released and counted them.
            let held = ctx.map { c in c.noteReleased(inputLedger.releaseAll(owner: c.inputOwner)); return c.releasedInputs } ?? 0
            var err = mapError(error, deadline: deadline, ctx: ctx)
            if held > 0 { err.details["released_inputs"] = .number(Double(held)) }
            let s = ctx?.snapshot ?? (events: 0, evidence: [], warnings: [], confirmed: false)
            return ToolResponse(id: req.id, name: req.name, ok: false, error: err,
                                dispatch: s.events > 0 ? .partial : .none,
                                effect: Effect(confirmed: s.confirmed, evidence: s.evidence),
                                warnings: s.warnings, durationMs: monotonicMs() - started, pausedMs: ctx?.pause.ms ?? 0)
        }
    }

    private func runGuarded(_ spec: ToolSpec, _ c: CallContext, _ args: Args, deadline: Int) async throws -> JSONValue {
        guard spec.mutating else { return try await spec.run(c, args) }
        if c.asUser {
            // The human acting from the host UI: serialized with scripts, never paused or cancelled by takeover.
            // While the user has control every script call is paused (possibly holding the
            // target's turn), so there is nothing to serialize with and nothing to wait for.
            if arbiter.owner == .user { return try await spec.run(c, args) }
            let l = lock(for: c.target.id)
            try await l.lock()
            defer { c.noteReleased(inputLedger.releaseAll(owner: c.inputOwner)); Task { await l.unlock() } }
            return try await spec.run(c, args)
        }
        // Pause before starting while the user has control, then take the target's turn. A call
        // that pauses later, at a gate, keeps its turn: calls queued behind it stay in order.
        c.notePause(try await arbiter.waitForAgent(deadlineMs: deadline))
        let l = lock(for: c.target.id)
        try await l.lock()
        defer { c.noteReleased(inputLedger.releaseAll(owner: c.inputOwner)); router.returnKeyWindowsToUser(); Task { await l.unlock() } }
        return try await spec.run(c, args)
    }

    private func mapError(_ error: Error, deadline: Int, ctx: CallContext?) -> DriverError {
        if let d = error as? DriverError { return d }
        if error is CancellationError {
            if monotonicMs() >= deadline {
                if ctx?.isPaused == true || (ctx?.mutating == true && ctx?.asUser == false && arbiter.owner == .user) {
                    return DriverError(.userHasControl, "The user still had control of the virtual monitor when the call's timeout expired; no further input was sent")
                }
                return DriverError(.timeout, "The call exceeded its timeout and was stopped")
            }
            return DriverError(.cancelled, "The call was cancelled")
        }
        return DriverError(.internalError, String(describing: error))
    }

    // MARK: Status / lifecycle

    public func status() async -> JSONValue {
        let inflight = await ledger.inFlight
        var displayState: String
        switch display.state {
        case .idle: displayState = "idle"
        case .starting: displayState = "starting"
        case .ready: displayState = "ready"
        case .failed(let m): displayState = "failed: \(m)"
        case .stopped: displayState = "stopped"
        }
        var report: [String: JSONValue] = [
            "protocol_version": .number(Double(DriverProtocol.version)),
            "display_state": .string(displayState),
            "control": .string(arbiter.owner.rawValue),
            "targets": .array(targets.all().map { $0.json }),
            "permissions": ["accessibility": .bool(AX.isTrusted), "screen_recording": .bool(CGPreflightScreenCaptureAccess()),
                            "post_events": .bool(CGPreflightPostEventAccess())],
            "capabilities": .object(Dictionary(uniqueKeysWithValues:
                Capabilities.all(extra: hostCapabilities.get.map { $0() }).map { ($0.name, $0.json) })),
            "arrangement_deviations": .array(display.arrangementDeviations().map { .string($0) }),
            "in_flight": .number(Double(inflight)),
            "interrupted_requests": .number(Double(await ledger.interrupted)),
            "held_inputs": .number(Double(inputLedger.heldCount)),
            "tools": .array(toolNames.map { .string($0) }),
            "uptime_s": .number(Date().timeIntervalSince(startedAt).rounded()),
        ]
        if let extra = hostStatus.get { for (k, v) in extra() { report[k] = v } }
        return .object(report)
    }

    /// Stops everything in a safe order: cancel calls, release input, move driver-opened windows
    /// back to a physical display (so nothing is stranded or lost), then release the display.
    public func shutdown() async {
        await ledger.cancelAll()
        inputLedger.releaseEverything()
        WindowFocuser.withdrawActiveBelief()
        WebAccessibility.withdrawAll()
        if let vid = display.displayID {
            let vb = CGDisplayBounds(vid)
            let fallback = WindowService.visibleFrame(of: CGMainDisplayID())
            for (wid, _, original) in windows.placedWindows {
                guard let w = try? windows.resolve(wid), let f = AX.frame(w.ax), vb.intersects(f) else { continue }
                let dest = WindowService.display(for: original).map { WindowService.visibleFrame(of: $0) } ?? fallback
                windows.move(w, into: dest, preferredOrigin: original.origin)
            }
        }
        display.stop()
    }
}

/// Races `op` against a monotonic deadline. On timeout the op is cancelled and awaited, so by the
/// time this throws, no more input from the op can be sent.
func withDeadline<T: Sendable>(_ deadlineMs: Int, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { g in
        g.addTask { try await op() }
        g.addTask {
            let remaining = deadlineMs - monotonicMs()
            if remaining > 0 { try await sleepMs(remaining) }
            return nil
        }
        defer { g.cancelAll() }
        for try await v in g {
            if let v { return v }
            throw CancellationError()  // deadline reached; mapped to `timeout` by the caller
        }
        throw CancellationError()
    }
}
