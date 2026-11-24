import XCTest
import CoreGraphics
@testable import DriverCore
@testable import DriverProtocol

// Regression tests for three bugs found in code review, now fixed. Each test asserts the intended
// behavior and failed before the fix. None of them needs the virtual display or any permission.

/// A pid no process can have (macOS pids stay below 100 000), so released events go nowhere.
private let nobody = pid_t(Int32.max)

// MARK: Held input belongs to one owner (was: one ledger released by every call and the mirror)

final class InputOwnershipTests: XCTestCase {
    /// A call on one target held a button (a drag on `display:N`, say) while an unrelated call
    /// failed. The failing call's cleanup must not release the other call's input.
    func testFailedCallDoesNotReleaseAnotherCallsHeldInput() async {
        let d = Driver(display: VirtualDisplayManager())
        defer { d.inputLedger.releaseEverything() }
        d.inputLedger.pressed(button: .left, at: .zero, windowID: 1, pid: nobody, owner: .call(asUser: false))

        let r = await d.call(ToolRequest(id: "unrelated", name: "computer_click", arguments: ["zzz": 1]))
        XCTAssertEqual(r.error?.code, .invalidArgument)

        XCTAssertEqual(d.inputLedger.heldCount, 1,
                       "an unrelated call's error path released input held by another call")
    }

    /// During a takeover the user presses a button in the mirror (the forwarder records it in the
    /// same ledger). A script call that reaches its gate afterwards must pause without releasing
    /// the user's button, or the user's drag is cut short.
    func testScriptGateDuringTakeoverDoesNotReleaseTheUsersInput() async {
        let d = Driver(display: VirtualDisplayManager())
        defer { d.inputLedger.releaseEverything(); d.arbiter.giveBack() }
        let ctx = scriptContext(d, deadlineMs: monotonicMs() + 300)

        d.arbiter.takeControl()
        // The user starts a drag in the mirror.
        d.inputLedger.pressed(button: .left, at: .zero, windowID: 1, pid: nobody, owner: .mirror)

        do {
            try await ctx.gate()
            XCTFail("the gate should wait for Give Back until the deadline")
        } catch {
            XCTAssertEqual((error as? DriverError)?.code, .userHasControl)
        }
        XCTAssertEqual(d.inputLedger.heldCount, 1,
                       "a paused script call released the button the user is holding in the mirror")
    }

    /// Call B held nothing when the user took control; only another call (A, on another target)
    /// held a button. After Give Back, B must resume, not fail as a broken gesture.
    func testTakeoverDoesNotBreakACallThatHeldNothing() async {
        let d = Driver(display: VirtualDisplayManager())
        defer { d.inputLedger.releaseEverything() }
        let a = scriptContext(d, deadlineMs: monotonicMs() + 2_000)
        let b = scriptContext(d, deadlineMs: monotonicMs() + 2_000)
        // Call A's drag on another target.
        d.inputLedger.pressed(button: .left, at: .zero, windowID: 2, pid: nobody, owner: a.inputOwner)

        d.arbiter.takeControl()
        d.arbiter.giveBack()

        do {
            try await b.gate()
        } catch {
            XCTFail("call B held no input but was failed as an interrupted gesture: \(error)")
        }
        // Call A's gesture really was broken off, and it is told so.
        do { try await a.gate(); XCTFail("call A's held drag was released, so it must not resume") }
        catch { XCTAssertEqual((error as? DriverError)?.details["resumable"], .bool(false)) }
    }

    private func scriptContext(_ d: Driver, deadlineMs: Int) -> CallContext {
        CallContext(request: ToolRequest(id: UUID().uuidString, name: "computer_drag"),
                    target: Target(id: "virtual", displayID: 1, isVirtual: true),
                    mutating: true, driver: d, deadlineMs: deadlineMs)
    }
}

// MARK: A client that stops reading is disconnected (was: Connection.send spun forever)

final class StalledClientTests: XCTestCase {
    func testAcceptedSocketsInheritNonBlocking() throws {
        // Why `send` must handle a full buffer: on Darwin, accept() copies O_NONBLOCK from the listener, so the
        // server's connection sockets are non-blocking and `write` returns EAGAIN when full.
        let path = shortSocketPath()
        defer { unlink(path) }
        let l = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(l) }
        var addr = try SocketServer.address(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(l, $0, len) } }, 0)
        XCTAssertEqual(listen(l, 1), 0)
        _ = fcntl(l, F_SETFL, fcntl(l, F_GETFL) | O_NONBLOCK)
        let c = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(c) }
        XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(c, $0, len) } }, 0)
        let a = accept(l, nil, nil)
        defer { close(a) }
        XCTAssertGreaterThanOrEqual(a, 0)
        XCTAssertNotEqual(fcntl(a, F_GETFL) & O_NONBLOCK, 0)
    }

    /// A client that connects and never reads must not hold a server thread forever: `send`
    /// should give up (and close the connection) after a bounded wait.
    func testSendToAClientThatNeverReadsReturns() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let (serverEnd, clientEnd) = (fds[0], fds[1])
        var on: Int32 = 1
        setsockopt(serverEnd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(serverEnd, F_SETFL, fcntl(serverEnd, F_GETFL) | O_NONBLOCK)  // as accept() leaves it

        let server = SocketServer(path: shortSocketPath(), driver: Driver(display: VirtualDisplayManager()))
        let conn = Connection(fd: serverEnd, server: server)
        let big: JSONValue = ["blob": .string(String(repeating: "x", count: 4 * 1024 * 1024))]

        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { conn.send(big); returned.signal() }
        let result = returned.wait(timeout: .now() + 5)

        // Unblock a spinning writer either way (EPIPE ends its loop), so the test run continues.
        close(clientEnd)
        if result == .timedOut { _ = returned.wait(timeout: .now() + 5) }
        close(serverEnd)
        XCTAssertEqual(result, .success, "Connection.send was still spinning on EAGAIN after 5 s for a client that never reads")
    }
}

// MARK: A retry after a dropped connection attaches to the running call (was: got `cancelled`)

final class DisconnectRetryTests: XCTestCase {
    /// The documented contract (README, both clients): re-sending the same id after a dropped
    /// connection returns the original result instead of repeating the action. The server used
    /// to cancel a connection's in-flight calls the moment it closed, so the retry found the call
    /// cancelled midway and got that back instead.
    func testRetryAfterDisconnectGetsTheOriginalResult() async throws {
        let d = Driver(display: VirtualDisplayManager())
        let server = SocketServer(path: shortSocketPath(), driver: d)
        try server.start()
        defer { server.stop() }

        let id = "retry-\(UUID().uuidString.prefix(8))"
        let req = ToolRequest(id: id, name: "computer_type", arguments: ["text": "hello"])
        // The host's execution of the call: it has sent part of its input and needs ~600 ms more.
        // Cancelled midway, it reports what `execute` reports: cancelled, partially dispatched.
        let running = Task {
            await d.ledger.run(req, journaled: false) {
                do { try await sleepMs(600) } catch {
                    return ToolResponse(id: id, name: req.name, ok: false, error: DriverError(.cancelled, "The call was cancelled"),
                                        dispatch: .partial)
                }
                return ToolResponse(id: id, name: req.name, ok: true, result: ["characters": 5], dispatch: .dispatched)
            }
        }
        try await sleepMs(50)
        let line = #"{"id":"\#(id)","name":"computer_type","arguments":{"text":"hello"}}"#

        // Client 1 sends the call (attaching to the running execution), then its connection drops.
        let first = try RawClient(server.path)
        try first.send(line)
        try await sleepMs(100)
        first.close()

        // Client 1 reconnects at once and retries with the same id, as both clients do.
        try await sleepMs(20)
        let retry = try RawClient(server.path)
        try retry.send(line)
        let reply = try retry.readLine(timeout: 5)
        retry.close()
        _ = await running.value

        XCTAssertEqual(reply["ok"]?.boolValue, true,
                       "the retry got \(reply["error"]?["code"]?.stringValue ?? "?") instead of the original result")
    }
}

// MARK: Found reviewing the fixes above

final class DisconnectGraceTests: XCTestCase {
    /// Two disconnects in a row for the same id: the first one's timer must not cancel the call
    /// while the second one's grace period is still running.
    func testAnOlderDisconnectDoesNotCutANewerGracePeriodShort() async throws {
        let d = Driver(display: VirtualDisplayManager())
        let server = SocketServer(path: shortSocketPath(), driver: d)
        server.disconnectGraceMs = 600
        try server.start()
        defer { server.stop() }

        let id = "grace-\(UUID().uuidString.prefix(8))"
        let req = ToolRequest(id: id, name: "computer_type", arguments: ["text": "hello"])
        let running = Task {
            await d.ledger.run(req, journaled: false) {
                do { try await sleepMs(1_500) } catch {
                    return ToolResponse(id: id, name: req.name, ok: false, error: DriverError(.cancelled, "The call was cancelled"),
                                        dispatch: .partial)
                }
                return ToolResponse(id: id, name: req.name, ok: true, result: ["characters": 5], dispatch: .dispatched)
            }
        }
        try await sleepMs(50)
        let line = #"{"id":"\#(id)","name":"computer_type","arguments":{"text":"hello"}}"#

        let first = try RawClient(server.path)      // drops at about 100 ms: its timer fires at 700
        try first.send(line)
        try await sleepMs(50)
        first.close()
        try await sleepMs(100)
        let second = try RawClient(server.path)     // attaches, then drops at about 500 ms
        try second.send(line)
        try await sleepMs(300)
        second.close()
        try await sleepMs(350)                      // about 850 ms: past the first timer, inside the second grace
        let third = try RawClient(server.path)
        try third.send(line)
        let reply = try third.readLine(timeout: 5)
        third.close()
        _ = await running.value

        XCTAssertEqual(reply["ok"]?.boolValue, true,
                       "the retry got \(reply["error"]?["code"]?.stringValue ?? "?"): the first disconnect's timer cancelled the call")
    }

    /// A request line handled after its connection closed must not be tracked (and so not started).
    func testAClosedConnectionTracksNothing() {
        let server = SocketServer(path: shortSocketPath(), driver: Driver(display: VirtualDisplayManager()))
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let conn = Connection(fd: fds[0], server: server)
        XCTAssertEqual(conn.track("a"), true)
        XCTAssertEqual(conn.track("a"), false)
        XCTAssertEqual(conn.untrackAll(), ["a"])
        XCTAssertNil(conn.track("b"))
        XCTAssertFalse(conn.untrack("a"))
    }
}

// MARK: Helpers

/// sun_path holds 104 bytes, so keep test sockets short.
private func shortSocketPath() -> String { "/tmp/mdt-\(UUID().uuidString.prefix(8)).sock" }

/// Minimal blocking client: one connection, raw JSON lines.
private final class RawClient {
    let fd: Int32
    init(_ path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = try SocketServer.address(path)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
    }
    func send(_ line: String) throws {
        let data = Array((line + "\n").utf8)
        guard write(fd, data, data.count) == data.count else { throw POSIXError(.EPIPE) }
    }
    func readLine(timeout: Int) throws -> JSONValue {
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        while buf.firstIndex(of: 0x0A) == nil {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw POSIXError(.ETIMEDOUT) }
            buf.append(contentsOf: chunk[0..<n])
        }
        return try JSONValue.parse(buf.subdata(in: buf.startIndex..<buf.firstIndex(of: 0x0A)!))
    }
    func close() { Darwin.close(fd) }
}
