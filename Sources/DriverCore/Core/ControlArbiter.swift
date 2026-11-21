import Foundation
import DriverProtocol

/// Who may drive the virtual monitor right now.
public enum ControlOwner: String, Sendable { case agent, user }

/// Arbitrates control between scripts and the human.
///
/// - `takeControl()` flips ownership to the user. Nothing is cancelled: every mutating call
///   pauses at its next gate (see `CallContext.gate`), before sending any further input, and the
///   input ledger releases anything still held.
/// - Only an explicit `giveBack()` returns control. Closing the mirror window does not.
/// - Paused calls, and mutating calls that arrive while the user has control, wait until Give
///   Back, then continue. One that is still waiting at its timeout fails with `user_has_control`.
public final class ControlArbiter: Sendable {
    private struct State {
        var owner: ControlOwner = .agent
        var handlers: [UUID: @Sendable (ControlOwner) -> Void] = [:]
        var takeovers = 0
    }
    private let state = Locked(State())

    public init() {}

    public var owner: ControlOwner { state.withLock { $0.owner } }
    /// How many times the user has taken control.
    public var takeoverCount: Int { state.withLock { $0.takeovers } }

    @discardableResult
    public func observe(_ h: @escaping @Sendable (ControlOwner) -> Void) -> UUID {
        let id = UUID(); state.withLock { $0.handlers[id] = h }; return id
    }

    /// Flips ownership and returns the handlers to notify, or nil when nothing changed. The
    /// handlers run after the lock is released, so they may call back into the arbiter.
    private func transfer(to new: ControlOwner) -> [@Sendable (ControlOwner) -> Void]? {
        state.withLock { s in
            guard s.owner != new else { return nil }
            s.owner = new
            if new == .user { s.takeovers += 1 }
            return Array(s.handlers.values)
        }
    }

    public func takeControl() {
        guard let handlers = transfer(to: .user) else { return }
        handlers.forEach { $0(.user) }
        Log.driver.info("User took control; script actions pause at their next step")
    }

    public func giveBack() {
        guard let handlers = transfer(to: .agent) else { return }
        handlers.forEach { $0(.agent) }
        Log.driver.info("Control given back to scripts")
    }

    /// Waits until scripts own the monitor, polling cheaply. Throws `user_has_control` when the
    /// deadline passes, or CancellationError when the call is cancelled. `dispatchedEvents` is
    /// how much input the waiting call had already sent (0 for a call that has not started).
    public func waitForAgent(deadlineMs: Int, dispatchedEvents: Int = 0) async throws -> Int {
        // Nothing to wait for: report no pause at all, not the time the check took.
        guard owner == .user else { return 0 }
        let start = monotonicMs()
        while owner == .user {
            try Task.checkCancellation()
            if monotonicMs() >= deadlineMs {
                let what = dispatchedEvents == 0 ? "nothing was dispatched"
                    : "\(dispatchedEvents) input event(s) were sent before the pause and nothing after it"
                throw DriverError(.userHasControl, "The user still had control of the virtual monitor when the call's timeout expired; \(what)",
                                  details: ["waited_ms": .number(Double(monotonicMs() - start))])
            }
            try await sleepMs(25)
        }
        return monotonicMs() - start
    }
}
