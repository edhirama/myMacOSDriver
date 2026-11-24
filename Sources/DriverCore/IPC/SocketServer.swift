import Foundation
import DriverProtocol

/// Unix-domain-socket server speaking newline-delimited JSON.
///
/// - One JSON object per line in each direction. Responses carry the request `id`, so a client
///   may pipeline several requests on one connection.
/// - `{"op":"cancel","id":...}` cancels a running call; `{"op":"status"}` reports host state.
/// - When a connection closes, its in-flight calls are cancelled after `disconnectGraceMs` (a
///   departed client should not keep driving the desktop), unless another connection has sent
///   the same id by then. So a client whose connection dropped can reconnect, re-send the id and
///   attach to the call still running, and gets its real result. Completed results stay in the
///   idempotency ledger, so a later re-send gets the stored result instead of a second run.
/// - The socket file is created with mode 0600 inside a 0700 directory: only this user can connect.
public final class SocketServer: @unchecked Sendable {
    public let path: String
    private let driver: Driver
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.macdriver.ipc", attributes: .concurrent)
    private let connections = Locked<[Int32: Connection]>([:])
    /// How many open connections are waiting on each in-flight request id.
    private let waiting = Locked<[String: Int]>([:])
    /// The latest disconnect that left each id with no client. A grace timer cancels a call only
    /// if it belongs to that disconnect, so an older timer never cuts a newer grace period short.
    private let orphans = Locked<(next: Int, latest: [String: Int])>((1, [:]))
    /// How long a call whose client disconnected keeps running, waiting for a retry to attach.
    public var disconnectGraceMs = 2_000
    public var onActivity: (@Sendable (String) -> Void)?
    /// Enables `test_take_control` / `test_give_back` for automated tests (`--test-ops`).
    public var testControl: (@Sendable (Bool) -> Void)?
    /// Test-only mirror input and user actions; returns `{"error": ...}` or a result object.
    public var testUserInput: (@Sendable ([String: JSONValue]) async -> JSONValue)?

    public init(path: String = DriverProtocol.defaultSocketPath, driver: Driver) {
        self.path = path; self.driver = driver
    }

    public enum ServerError: Error, CustomStringConvertible {
        case pathTooLong, alreadyRunning, posix(String, Int32)
        public var description: String {
            switch self {
            case .pathTooLong: return "Socket path is too long"
            case .alreadyRunning: return "Another MacDriver host is already serving this socket"
            case .posix(let op, let e): return "\(op) failed: \(String(cString: strerror(e)))"
            }
        }
    }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The attributes above apply only when the directory is created; enforce them on an existing one.
        chmod(dir, 0o700)
        // A leftover socket file from a crash is removed; a live one means another host is running.
        if FileManager.default.fileExists(atPath: path) {
            if Self.canConnect(path) { throw ServerError.alreadyRunning }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.posix("socket", errno) }
        var addr = try Self.address(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard r == 0 else { close(fd); throw ServerError.posix("bind", errno) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw ServerError.posix("listen", errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.resume()
        acceptSource = src
        Log.ipc.info("Listening on \(self.path)")
    }

    public func stop() {
        acceptSource?.cancel(); acceptSource = nil
        // Only remove the socket file if this instance bound it; otherwise it may belong to
        // another running host.
        let owned = listenFD >= 0
        if owned { close(listenFD); listenFD = -1 }
        for c in connections.withLock({ d -> [Connection] in let v = Array(d.values); d.removeAll(); return v }) { c.close() }
        if owned { unlink(path) }
    }

    public var connectionCount: Int { connections.get.count }

    private func acceptPending() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { return }
            // Whoever connects can drive the machine. File permissions already limit the socket
            // to this user; verifying the peer's user id does not depend on them staying intact.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(cfd, &uid, &gid) == 0, uid == getuid() else {
                Log.ipc.error("Refused a connection from another user (uid \(uid))")
                close(cfd)
                continue
            }
            var on: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let conn = Connection(fd: cfd, server: self)
            connections.withLock { $0[cfd] = conn }
            conn.start(queue: queue)
        }
    }

    fileprivate func closed(_ c: Connection) {
        connections.withLock { $0[c.fd] = nil }
        let ids = c.untrackAll()
        guard !ids.isEmpty else { return }
        let orphaned = ids.filter { stopWaiting($0) }
        guard !orphaned.isEmpty else { return }
        Log.ipc.info("Client disconnected with \(orphaned.count) call(s) in flight; cancelling them unless a retry attaches within \(self.disconnectGraceMs) ms")
        let grace = disconnectGraceMs
        let token = orphans.withLock { o -> Int in
            let t = o.next; o.next += 1
            for id in orphaned { o.latest[id] = t }
            return t
        }
        Task { [driver] in
            try? await sleepMs(grace)
            for id in orphaned where self.claimOrphan(id, token) && !self.isWaitedOn(id) {
                if await driver.cancel(id) { Log.ipc.info("Cancelled \(id): no client came back for it") }
            }
        }
    }

    /// True when `token` is still the latest disconnect for the id; the record is then dropped.
    private func claimOrphan(_ id: String, _ token: Int) -> Bool {
        orphans.withLock { o in
            guard o.latest[id] == token else { return false }
            o.latest[id] = nil
            return true
        }
    }

    private func startWaiting(_ id: String) { waiting.withLock { $0[id, default: 0] += 1 } }
    /// Returns true when no connection is waiting on the id any more.
    private func stopWaiting(_ id: String) -> Bool {
        waiting.withLock { w in
            let n = (w[id] ?? 1) - 1
            w[id] = n > 0 ? n : nil
            return n <= 0
        }
    }
    private func isWaitedOn(_ id: String) -> Bool { waiting.withLock { $0[id] != nil } }

    fileprivate func handle(line: Data, from c: Connection) {
        let value: JSONValue
        do { value = try JSONValue.parse(line) } catch {
            c.send(errorEnvelope(id: nil, DriverError(.invalidRequest, "Line is not valid JSON")))
            return
        }
        let msg: InboundMessage
        do { msg = try InboundMessage.parse(value, generateId: { "auto-" + UUID().uuidString.lowercased() }) } catch let e as DriverError {
            c.send(errorEnvelope(id: value["id"]?.stringValue, e)); return
        } catch { return }

        switch msg {
        case .status(let id):
            Task {
                var s = await driver.status()
                if case .object(var o) = s { o["connections"] = .number(Double(connectionCount)); s = .object(o) }
                c.sendLater(["id": JSONValue(id), "ok": true, "op": "status", "result": s])
            }
        case .tools(let id):
            c.send(["id": JSONValue(id), "ok": true, "op": "tools",
                    "result": ["protocol_version": .number(Double(DriverProtocol.version)), "tools": .array(driver.toolSpecs.map { $0.json })]])
        case .testControl(let op):
            guard let h = testControl else {
                c.send(errorEnvelope(id: nil, DriverError(.invalidRequest, "Test ops are disabled; launch the host with --test-ops")))
                return
            }
            h(op == "test_take_control")
            c.send(["ok": true, "op": .string(op), "result": ["control": .string(driver.arbiter.owner.rawValue)]])
        case .testUserInput(let o):
            guard let h = testUserInput else {
                c.send(errorEnvelope(id: nil, DriverError(.invalidRequest, "Test ops are disabled; launch the host with --test-ops")))
                return
            }
            Task {
                let r = await h(o)
                if let err = r["error"]?.stringValue { c.sendLater(errorEnvelope(id: nil, DriverError(.invalidArgument, err))) }
                else { c.sendLater(["ok": true, "op": "test_user_input", "result": r]) }
            }
        case .cancel(let id):
            Task {
                let found = await driver.cancel(id)
                c.sendLater(["id": .string(id), "ok": .bool(found), "op": "cancel",
                        "result": ["cancelled": .bool(found)]])
            }
        case .call(let req):
            // A line still in the buffer of a connection that has closed: nobody would receive
            // the result or be counted as waiting for it, so the call is not started.
            guard let added = c.track(req.id) else { return }
            if added { startWaiting(req.id) }
            onActivity?("\(req.name) [\(req.id)]")
            Task {
                let resp = await driver.call(req)
                if c.untrack(req.id) { _ = stopWaiting(req.id) }
                c.sendLater(resp.json)
            }
        }
    }

    private func errorEnvelope(id: String?, _ e: DriverError) -> JSONValue {
        ["id": JSONValue(id), "ok": false, "error": e.json, "dispatch": "none"]
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw ServerError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    public static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = try? address(path) else { return false }
        defer { close(fd) }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        return r == 0
    }
}

/// One client connection: buffered line reader and serialized writer.
final class Connection: @unchecked Sendable {
    let fd: Int32
    private weak var server: SocketServer?
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private let writeLock = NSLock()
    /// The ids in flight on this connection; nil once it has closed, so nothing is tracked after.
    private let ids = Locked<Set<String>?>([])
    /// Responses produced by tasks are written here, so a slow reader blocks this queue and not
    /// one of the threads every call shares.
    private let writeQueue: DispatchQueue
    private var isClosed = false
    static let maxLine = 4 * 1024 * 1024

    init(fd: Int32, server: SocketServer) {
        self.fd = fd; self.server = server
        writeQueue = DispatchQueue(label: "dev.macdriver.conn.\(fd).write")
    }

    /// Each says whether it changed anything, so the server counts every id once per connection.
    /// `track` returns nil when the connection has already closed.
    func track(_ id: String) -> Bool? { ids.withLock { $0?.insert(id).inserted } }
    func untrack(_ id: String) -> Bool { ids.withLock { $0?.remove(id) != nil } }
    /// Called once, when the connection closes: returns what was in flight and stops tracking.
    func untrackAll() -> [String] { ids.withLock { let all = Array($0 ?? []); $0 = nil; return all } }

    /// `send` from an async task: the write, which may wait for the client, runs on this
    /// connection's own queue. Responses keep their order.
    func sendLater(_ v: JSONValue) { writeQueue.async { self.send(v) } }

    func start(queue: DispatchQueue) {
        let serial = DispatchQueue(label: "dev.macdriver.conn.\(fd)", target: queue)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serial)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [fd] in Darwin.close(fd) }
        source = src
        src.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { close(); return }
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { server?.handle(line: line, from: self) }
        }
        if buffer.count > Self.maxLine {
            send(["ok": false, "error": DriverError(.invalidRequest, "Request line exceeds 4 MB").json])
            close()
        }
    }

    /// How long one response may wait for a client to read before the connection is given up.
    static let writeTimeoutMs = 2_000

    /// Writes one line. The socket is non-blocking (accepted sockets inherit O_NONBLOCK from the
    /// listener), so a full buffer waits in `poll` for room, up to `writeTimeoutMs`. A client
    /// that stops reading for that long is disconnected instead of holding a thread forever.
    func send(_ v: JSONValue) {
        guard var data = try? v.jsonData() else { return }
        data.append(0x0A)
        let delivered: Bool = {
            writeLock.lock(); defer { writeLock.unlock() }
            if isClosed { return true }
            let deadline = monotonicMs() + Self.writeTimeoutMs
            return data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let w = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                    if w >= 0 { off += w; continue }
                    if errno == EINTR { continue }
                    guard errno == EAGAIN else { return false }
                    let remaining = deadline - monotonicMs()
                    guard remaining > 0 else { return false }
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&p, 1, Int32(remaining)) < 0, errno != EINTR { return false }
                }
                return true
            }
        }()
        if !delivered {
            Log.ipc.error("Closing a connection whose client stopped reading (or whose socket failed) while a response was sent")
            close()
        }
    }

    func close() {
        writeLock.lock()
        if isClosed { writeLock.unlock(); return }
        isClosed = true
        writeLock.unlock()
        source?.cancel()
        server?.closed(self)
    }
}
