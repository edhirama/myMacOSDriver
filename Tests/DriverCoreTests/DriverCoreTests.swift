import XCTest
import CoreGraphics
@testable import DriverCore
@testable import DriverProtocol

final class KeySpecTests: XCTestCase {
    func testNamedKeys() throws {
        XCTAssertEqual(try KeySpec.parse("Return").keyCode, 0x24)
        XCTAssertEqual(try KeySpec.parse("Backspace").keyCode, 0x33)
        XCTAssertEqual(try KeySpec.parse("ArrowLeft").keyCode, 0x7B)
        XCTAssertEqual(try KeySpec.parse("arrow_left").keyCode, 0x7B)
        XCTAssertEqual(try KeySpec.parse("F5").keyCode, 0x60)
        XCTAssertEqual(try KeySpec.parse("Escape").keyCode, 0x35)
    }

    func testCombos() throws {
        let k = try KeySpec.parse("super+a")
        XCTAssertEqual(k.keyCode, 0x00)
        XCTAssertEqual(k.modifiers, [.super])
        let k2 = try KeySpec.parse("ctrl+shift+Tab")
        XCTAssertEqual(k2.modifiers, [.ctrl, .shift])
        XCTAssertEqual(k2.keyCode, 0x30)
        XCTAssertEqual(try KeySpec.parse("cmd+alt+Escape").modifiers, [.super, .alt])
    }

    func testShiftedCharacterImpliesShift() throws {
        let k = try KeySpec.parse("!")
        XCTAssertEqual(k.keyCode, 0x12)
        XCTAssertEqual(k.modifiers, [.shift])
        XCTAssertEqual(try KeySpec.parse("super++").modifiers, [.super, .shift])
    }

    func testBareModifier() throws {
        let k = try KeySpec.parse("shift")
        XCTAssertNil(k.keyCode)
        XCTAssertEqual(k.modifiers, [.shift])
    }

    func testRejectsUnknown() {
        XCTAssertThrowsError(try KeySpec.parse("hyper+a"))
        XCTAssertThrowsError(try KeySpec.parse("NotAKey"))
        XCTAssertThrowsError(try KeySpec.parse(""))
        XCTAssertThrowsError(try KeySpec.parse("super+"))
    }
}

final class ArgsTests: XCTestCase {
    func args(_ o: [String: JSONValue], _ allowed: Set<String>) throws -> Args { try Args(o, tool: "t", allowed: allowed) }

    func testUnknownArgumentRejected() {
        XCTAssertThrowsError(try args(["bogus": 1], ["x"])) { e in
            XCTAssertEqual((e as? DriverError)?.code, .invalidArgument)
        }
        XCTAssertNoThrow(try args(["computer": "virtual"], []))
    }

    func testPositionFormsAreExclusive() throws {
        XCTAssertThrowsError(try PositionArg.parse(try args(["ref": "r", "in": "s", "x": 1, "y": 2], ["ref", "in", "x", "y"])))
        XCTAssertThrowsError(try PositionArg.parse(try args(["in": "s", "x": 1], ["in", "x", "y"])))
        XCTAssertThrowsError(try PositionArg.parse(try args([:], ["in", "x", "y"])))
        if case .ref(let r)? = try PositionArg.parse(try args(["ref": "ref:1.2"], ["ref"])) { XCTAssertEqual(r, "ref:1.2") } else { XCTFail() }
        if case .screenshot(let id, let x, let y)? = try PositionArg.parse(try args(["in": "s", "x": 3, "y": 4.5], ["in", "x", "y"])) {
            XCTAssertEqual(id, "s"); XCTAssertEqual(x, 3); XCTAssertEqual(y, 4.5)
        } else { XCTFail() }
    }

    func testTypes() throws {
        let a = try args(["count": 1.5, "button": "left", "keys": ["shift", "super"], "frame": ["x": 0, "y": 0, "width": 10, "height": 10]],
                         ["count", "button", "keys", "frame"])
        XCTAssertThrowsError(try a.positiveInt("count"))
        XCTAssertThrowsError(try a.oneOf("button", ["right"]))
        XCTAssertEqual(try a.modifiers(), [.shift, .super])
        XCTAssertEqual(try a.frame("frame"), CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertThrowsError(try args(["count": 4], ["count"]).positiveInt("count", max: 3))
        XCTAssertThrowsError(try args(["keys": ["meta", "fn"]], ["keys"]).modifiers())
    }

    func testPathNeedsTwoPoints() throws {
        XCTAssertThrowsError(try args(["path": [["x": 1, "y": 1]]], ["path"]).points("path", min: 2))
        XCTAssertEqual(try args(["path": [["x": 1, "y": 1], ["x": 2, "y": 3]]], ["path"]).points("path", min: 2).count, 2)
    }
}

final class ProtocolTests: XCTestCase {
    func testParseCall() throws {
        let v = try JSONValue.parse(Data(#"{"id":"a","name":"computer_click","arguments":{"x":1},"timeout_ms":500}"#.utf8))
        guard case .call(let r) = try InboundMessage.parse(v, generateId: { "gen" }) else { return XCTFail() }
        XCTAssertEqual(r.id, "a"); XCTAssertEqual(r.name, "computer_click"); XCTAssertEqual(r.timeoutMs, 500)
        XCTAssertEqual(r.arguments["x"], 1)
    }

    func testGeneratedIdAndControlOps() throws {
        guard case .call(let r) = try InboundMessage.parse(["name": "computer_apps"], generateId: { "gen" }) else { return XCTFail() }
        XCTAssertEqual(r.id, "gen")
        XCTAssertEqual(try InboundMessage.parse(["op": "cancel", "id": "x"], generateId: { "" }), .cancel(id: "x"))
        XCTAssertThrowsError(try InboundMessage.parse(["name": "x", "arguments": [1, 2]], generateId: { "" }))
        XCTAssertThrowsError(try InboundMessage.parse(["name": "x", "timeout_ms": -1], generateId: { "" }))
    }

    func testResponseRoundTrip() {
        let r = ToolResponse(id: "1", name: "computer_type", ok: false, error: DriverError(.cancelled, "c"), dispatch: .partial,
                             effect: Effect(confirmed: true, evidence: ["screen_changed"]), warnings: ["w"])
        let back = ToolResponse(json: r.json)
        XCTAssertEqual(back?.dispatch, .partial)
        XCTAssertEqual(back?.error?.code, .cancelled)
        XCTAssertEqual(back?.effect.evidence, ["screen_changed"])
    }

    func testFingerprintIgnoresKeyOrder() throws {
        let a = ToolRequest(id: "1", name: "n", arguments: ["a": 1, "b": 2])
        let b = ToolRequest(id: "1", name: "n", arguments: ["b": 2, "a": 1])
        XCTAssertEqual(a.fingerprint, b.fingerprint)
    }
}

final class LedgerTests: XCTestCase {
    static func ok(_ id: String, dispatch: DispatchState = .dispatched) -> ToolResponse {
        ToolResponse(id: id, name: "t", ok: true, dispatch: dispatch)
    }

    func testCompletedIdIsReplayedNotReExecuted() async {
        let ledger = RequestLedger()
        let runs = Locked(0)
        let req = ToolRequest(id: "same", name: "t")
        let r1 = await ledger.run(req) { runs.withLock { $0 += 1 }; return Self.ok("same") }
        let r2 = await ledger.run(req) { runs.withLock { $0 += 1 }; return Self.ok("same") }
        XCTAssertEqual(runs.get, 1)
        XCTAssertFalse(r1.replayed)
        XCTAssertTrue(r2.replayed)
    }

    func testConcurrentDuplicateAttaches() async {
        let ledger = RequestLedger()
        let runs = Locked(0)
        let req = ToolRequest(id: "c", name: "t")
        async let a = ledger.run(req) { runs.withLock { $0 += 1 }; try? await Task.sleep(nanoseconds: 100_000_000); return Self.ok("c") }
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let b = ledger.run(req) { runs.withLock { $0 += 1 }; return Self.ok("c") }
        let (ra, rb) = await (a, b)
        XCTAssertEqual(runs.get, 1)
        XCTAssertTrue(ra.ok && rb.ok)
    }

    func testIdReuseWithDifferentRequestIsRejected() async {
        let ledger = RequestLedger()
        _ = await ledger.run(ToolRequest(id: "x", name: "t", arguments: ["a": 1])) { Self.ok("x") }
        let r = await ledger.run(ToolRequest(id: "x", name: "t", arguments: ["a": 2])) { Self.ok("x") }
        XCTAssertEqual(r.error?.code, .idConflict)
    }

    func testFailuresWithoutSideEffectsAreRetryable() async {
        let ledger = RequestLedger()
        let runs = Locked(0)
        let req = ToolRequest(id: "r", name: "t")
        _ = await ledger.run(req) { runs.withLock { $0 += 1 }
            return ToolResponse(id: "r", name: "t", ok: false, error: DriverError(.userHasControl, ""), dispatch: .none) }
        let second = await ledger.run(req) { runs.withLock { $0 += 1 }; return Self.ok("r") }
        XCTAssertEqual(runs.get, 2)
        XCTAssertTrue(second.ok)
        // A partial failure is stored: retrying must not repeat what was already sent.
        let p = ToolRequest(id: "p", name: "t")
        _ = await ledger.run(p) { ToolResponse(id: "p", name: "t", ok: false, error: DriverError(.cancelled, ""), dispatch: .partial) }
        let again = await ledger.run(p) { runs.withLock { $0 += 1 }; return Self.ok("p") }
        XCTAssertTrue(again.replayed)
        XCTAssertEqual(again.dispatch, .partial)
    }
}

final class ToolSchemaTests: XCTestCase {
    private lazy var specs: [String: ToolSpec] = {
        let d = Driver(display: VirtualDisplayManager())
        return Dictionary(uniqueKeysWithValues: d.toolSpecs.map { ($0.name, $0) })
    }()

    private func code(_ tool: String, _ args: [String: JSONValue]) -> ErrorCode? {
        do { try specs[tool]!.validate(args); return nil } catch let e as DriverError { return e.code } catch { return .internalError }
    }

    func testAllElevenToolsAreDeclared() {
        XCTAssertEqual(specs.count, 11)
        for s in specs.values {
            XCTAssertFalse(s.summary.isEmpty, s.name)
            XCTAssertEqual(Set(s.params.map { $0.name }).count, s.params.count, "duplicate parameter in \(s.name)")
        }
    }

    func testGenericValidation() {
        XCTAssertNil(code("computer_scroll", ["ref": "ref:1.2", "direction": "down", "amount": 3]))
        XCTAssertEqual(code("computer_scroll", ["ref": "ref:1.2", "direction": "down", "amount": 3, "speed": 2]), .invalidArgument)  // unknown key
        XCTAssertEqual(code("computer_scroll", ["ref": "ref:1.2", "direction": "sideways", "amount": 3]), .invalidArgument)          // not an allowed value
        XCTAssertEqual(code("computer_scroll", ["ref": "ref:1.2", "direction": "down", "amount": 0]), .invalidArgument)             // out of range
        XCTAssertEqual(code("computer_scroll", ["ref": "ref:1.2", "direction": "down", "amount": "3"]), .invalidArgument)           // wrong type
        XCTAssertEqual(code("computer_scroll", ["ref": "ref:1.2", "amount": 3]), .invalidArgument)                                  // missing required
        XCTAssertNil(code("computer_apps", ["computer": "virtual"]))                                                               // every tool takes computer
        XCTAssertEqual(code("computer_apps", ["computer": 3]), .invalidArgument)
        XCTAssertEqual(code("computer_drag", ["in": "shot:a.1", "path": [["x": 1, "y": 2]]]), .invalidArgument)                     // too few points
        XCTAssertNil(code("computer_window", ["window": "win:1", "frame": ["x": 0, "y": 0, "width": 10, "height": 10]]))
        XCTAssertEqual(code("computer_window", ["window": "win:1", "frame": ["x": 0, "y": 0]]), .invalidArgument)
        XCTAssertNil(code("computer_click", ["ref": "ref:1.2", "keys": ["shift"]]))
        XCTAssertNil(code("computer_click", ["ref": "ref:1.2", "keys": "shift+super"]))
    }

    func testPublishedSchemaShape() {
        let j = specs["computer_scroll"]!.json
        XCTAssertEqual(j["input_schema"]?["type"], "object")
        XCTAssertEqual(j["input_schema"]?["additionalProperties"], false)
        XCTAssertEqual(Set(j["input_schema"]?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []), ["direction", "amount"])
        XCTAssertEqual(j["input_schema"]?["properties"]?["direction"]?["enum"]?.arrayValue?.count, 4)
        XCTAssertNotNil(j["input_schema"]?["properties"]?["computer"])
        XCTAssertEqual(j["mutating"], true)
    }

    /// docs/PROTOCOL.md is written by hand; this keeps it from drifting from the declarations.
    func testProtocolDocMentionsEveryToolAndParameter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/PROTOCOL.md"), encoding: .utf8)
        for s in specs.values {
            guard let row = doc.split(separator: "\n").first(where: { $0.hasPrefix("| `\(s.name)`") }) else {
                XCTFail("docs/PROTOCOL.md has no row for \(s.name)"); continue
            }
            for p in s.params where !["in", "x", "y", "ref"].contains(p.name) || s.name == "computer_drag" || s.name == "computer_click" {
                XCTAssertTrue(row.contains("`\(p.name)"), "docs/PROTOCOL.md row for \(s.name) does not mention `\(p.name)`")
            }
        }
    }
}

final class JournalTests: XCTestCase {
    private static func ok(_ id: String) -> ToolResponse { ToolResponse(id: id, name: "t", ok: true, result: ["v": 1], dispatch: .dispatched) }
    private func tempURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).journal") }

    func testFinishedRequestIsReplayedAfterRestart() async {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let runs = Locked(0)
        let req = ToolRequest(id: "a", name: "t", arguments: ["x": 1])
        let first = RequestLedger(journalURL: url)
        _ = await first.run(req, journaled: true) { runs.withLock { $0 += 1 }; return Self.ok("a") }
        // A new ledger on the same file stands for the host after a restart.
        let second = RequestLedger(journalURL: url)
        let r = await second.run(req, journaled: true) { runs.withLock { $0 += 1 }; return Self.ok("a") }
        XCTAssertEqual(runs.get, 1)
        XCTAssertTrue(r.ok); XCTAssertTrue(r.replayed)
        XCTAssertEqual(r.dispatch, .dispatched)
        XCTAssertEqual(r.result, ["v": 1])
        let other = await second.run(ToolRequest(id: "a", name: "t", arguments: ["x": 2]), journaled: true) { Self.ok("a") }
        XCTAssertEqual(other.error?.code, .idConflict)
    }

    func testRequestInterruptedByACrashIsNotRunAgain() async throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        // What a host leaves behind when it dies mid-call: a start record with no end.
        let j = Journal(url: url)
        let req = ToolRequest(id: "crash", name: "t")
        j.append(Journal.start(id: "crash", fingerprint: req.fingerprint, name: "t", ts: Date().timeIntervalSince1970))
        try "{\"t\":\"done\",\"id\":\"torn".write(to: url.appendingPathExtension("x"), atomically: true, encoding: .utf8)
        let h = try FileHandle(forWritingTo: url); _ = try h.seekToEnd()
        try h.write(contentsOf: Data("{\"t\":\"done\",\"id\":\"torn".utf8)); try h.close()  // torn last line
        try? FileManager.default.removeItem(at: url.appendingPathExtension("x"))

        let runs = Locked(0)
        let ledger = RequestLedger(journalURL: url)
        let n = await ledger.interrupted
        XCTAssertEqual(n, 1)
        let r = await ledger.run(req, journaled: true) { runs.withLock { $0 += 1 }; return Self.ok("crash") }
        XCTAssertEqual(runs.get, 0)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error?.code, .unknownOutcome)
        XCTAssertEqual(r.dispatch, .unknown)
        // Still refused after yet another restart.
        let again = await RequestLedger(journalURL: url).run(req, journaled: true) { runs.withLock { $0 += 1 }; return Self.ok("crash") }
        XCTAssertEqual(again.error?.code, .unknownOutcome)
        XCTAssertEqual(runs.get, 0)
    }

    func testFailureWithoutSideEffectsCanBeRetriedAfterRestart() async {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let req = ToolRequest(id: "r", name: "t")
        _ = await RequestLedger(journalURL: url).run(req, journaled: true) {
            ToolResponse(id: "r", name: "t", ok: false, error: DriverError(.userHasControl, ""), dispatch: .none)
        }
        let r = await RequestLedger(journalURL: url).run(req, journaled: true) { Self.ok("r") }
        XCTAssertTrue(r.ok); XCTAssertFalse(r.replayed)
    }

    func testOldJournalRecordsExpire() async throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let req = ToolRequest(id: "old", name: "t")
        let twoDaysAgo = Date().timeIntervalSince1970 - 2 * 24 * 3600
        let line = "{\"t\":\"start\",\"id\":\"old\",\"fp\":\"x\",\"name\":\"t\",\"ts\":\(Int(twoDaysAgo))}\n"
        try line.write(to: url, atomically: true, encoding: .utf8)
        let ledger = RequestLedger(journalURL: url)
        let n = await ledger.interrupted
        XCTAssertEqual(n, 0)
        let r = await ledger.run(req, journaled: true) { Self.ok("old") }
        XCTAssertTrue(r.ok)
    }

    func testRestartsDoNotRefreshARecordsAge() async throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let almostExpired = Date().timeIntervalSince1970 - RequestLedger.retention + 3600
        Journal(url: url).append(Journal.start(id: "aging", fingerprint: "x", name: "t", ts: almostExpired))
        // Each start rewrites the journal; the record must keep its original time through that.
        for _ in 0..<3 { _ = RequestLedger(journalURL: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"ts\":\(Int(almostExpired))"), text)
    }

    func testReadOnlyCallsAreNotJournaled() async {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let runs = Locked(0)
        let req = ToolRequest(id: "s", name: "t")
        _ = await RequestLedger(journalURL: url).run(req) { runs.withLock { $0 += 1 }; return Self.ok("s") }
        _ = await RequestLedger(journalURL: url).run(req) { runs.withLock { $0 += 1 }; return Self.ok("s") }
        XCTAssertEqual(runs.get, 2)
    }
}

final class ArbiterTests: XCTestCase {
    func testTakeoverBlocksUntilTimeout() async throws {
        let a = ControlArbiter()
        let seen = Locked<[ControlOwner]>([])
        a.observe { o in seen.withLock { $0.append(o) } }
        a.takeControl()
        a.takeControl()  // idempotent
        XCTAssertEqual(a.owner, .user)
        XCTAssertEqual(seen.get, [.user])
        do {
            _ = try await a.waitForAgent(deadlineMs: monotonicMs() + 120, dispatchedEvents: 3)
            XCTFail("should time out")
        } catch let e as DriverError {
            XCTAssertEqual(e.code, .userHasControl)
            XCTAssertTrue(e.message.contains("3 input event"))
        }
    }

    func testWaitResumesAfterGiveBack() async throws {
        let a = ControlArbiter()
        a.takeControl()
        Task { try? await Task.sleep(nanoseconds: 100_000_000); a.giveBack() }
        let waited = try await a.waitForAgent(deadlineMs: monotonicMs() + 2000)
        XCTAssertGreaterThan(waited, 50)
        XCTAssertEqual(a.owner, .agent)
    }
}

final class ConcurrencyTests: XCTestCase {
    func testDeadlineCancelsOperation() async {
        let finished = Locked(false)
        do {
            _ = try await withDeadline(monotonicMs() + 80) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                finished.withLock { $0 = true }
                return 1
            }
            XCTFail("expected timeout")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(finished.get)
    }

    func testAsyncLockSerializes() async throws {
        let lock = AsyncLock()
        let log = Locked<[Int]>([])
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<5 {
                g.addTask {
                    _ = try? await lock.withLock {
                        log.withLock { $0.append(i) }
                        try await Task.sleep(nanoseconds: 5_000_000)
                        log.withLock { $0.append(i) }
                    }
                }
            }
        }
        let l = log.get
        // Each task's two entries must be adjacent (no interleaving).
        for k in stride(from: 0, to: l.count, by: 2) { XCTAssertEqual(l[k], l[k + 1]) }
    }
}

final class DriverValidationTests: XCTestCase {
    func testCallsFailCleanlyWithoutDisplay() async {
        let d = Driver(display: VirtualDisplayManager())
        let r = await d.call(ToolRequest(id: "1", name: "computer_apps"))
        XCTAssertEqual(r.error?.code, .targetUnavailable)
        XCTAssertEqual(r.dispatch, .none)
        let u = await d.call(ToolRequest(id: "2", name: "nope"))
        XCTAssertEqual(u.error?.code, .unknownTool)
        let bad = await d.call(ToolRequest(id: "3", name: "computer_click", arguments: ["zzz": 1]))
        XCTAssertEqual(bad.error?.code, .invalidArgument)
    }

    func testDisplayGeometryMapping() {
        let g = DisplayGeometry(displayID: 9, bounds: CGRect(x: 4072, y: 1440, width: 1920, height: 1080), scale: 2)
        XCTAssertEqual(g.toGlobal(CGPoint(x: 10, y: 20)), CGPoint(x: 4082, y: 1460))
        XCTAssertEqual(g.toLocal(CGPoint(x: 4082, y: 1460)), CGPoint(x: 10, y: 20))
    }
}

final class PointerBarrierTests: XCTestCase {
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)

    /// An external monitor was unplugged: the virtual display moved to where it used to be, and the
    /// last position remembered on the external monitor is now inside the virtual display.
    func testReturnPointIsNeverOnTheVirtualDisplay() {
        let virtual = CGRect(x: 1512, y: 982, width: 1920, height: 1080)
        let remembered = CGPoint(x: 3416, y: 1424)
        XCTAssertTrue(virtual.contains(remembered))
        let back = PointerBarrier.returnPoint(wanted: remembered, displays: [builtIn, virtual], blocked: virtual)
        XCTAssertEqual(back, CGPoint(x: 1496, y: 966))
        XCTAssertFalse(virtual.contains(back!))
    }

    func testReturnPointStaysNearWhereThePointerWas() {
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let virtual = CGRect(x: 4072, y: 1440, width: 1920, height: 1080)
        // In the corner that touches the virtual display: moved in from the edges, on the same display.
        XCTAssertEqual(PointerBarrier.returnPoint(wanted: CGPoint(x: 4071, y: 1439), displays: [builtIn, external, virtual], blocked: virtual),
                       CGPoint(x: 4056, y: 1424))
        // Already well inside a display: left where it was.
        XCTAssertEqual(PointerBarrier.returnPoint(wanted: CGPoint(x: 700, y: 400), displays: [builtIn, external, virtual], blocked: virtual),
                       CGPoint(x: 700, y: 400))
    }

    func testNoReturnPointWithoutARealDisplay() {
        let virtual = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertNil(PointerBarrier.returnPoint(wanted: CGPoint(x: 5, y: 5), displays: [virtual], blocked: virtual))
    }
}
