import Foundation
@_exported import DriverProtocol

/// The host could not be reached, or stopped answering. Tool errors are not thrown: they come
/// back in the response (`response["ok"] == false`).
public struct DriverConnectionError: Error, CustomStringConvertible {
    public let description: String
    /// True when the request may be sent again (with the same id) and false when waiting ran out.
    let retryable: Bool
}

/// Swift client for the MacDriver host.
///
///     import DriverClient
///     let driver = Driver()
///     let shot = try driver.call(["name": "computer_screenshot", "arguments": [:]])
///     try driver.call(["name": "computer_click",
///                      "arguments": ["in": shot["result"]!["screenshot"]!, "x": 300, "y": 200]])
///
/// `call` returns the response documented in docs/PROTOCOL.md.
///
/// Retries are safe: every request carries an id (generated here when absent) and the host runs
/// each id once, so re-sending after a dropped connection returns the original result instead of
/// repeating the action.
public struct Driver: Sendable {
    public var socketPath: String
    public var retries: Int
    public var connectTimeout: TimeInterval

    public init(socketPath: String = DriverProtocol.defaultSocketPath, retries: Int = 2, connectTimeout: TimeInterval = 5) {
        self.socketPath = socketPath; self.retries = retries; self.connectTimeout = connectTimeout
    }

    /// Executes one tool call: `["name": ..., "arguments": [...], "id"?: ..., "timeout_ms"?: ...]`.
    @discardableResult
    public func call(_ request: JSONValue, timeout: TimeInterval? = nil) throws -> JSONValue {
        guard var req = request.objectValue, req["name"]?.stringValue != nil else {
            throw DriverConnectionError(description: "The request must be an object with a 'name'", retryable: false)
        }
        if req["id"] == nil { req["id"] = .string("swift-" + UUID().uuidString.lowercased()) }
        if req["arguments"] == nil { req["arguments"] = [:] }
        // Wait longer than the host's own timeout, so its timeout response is seen.
        let wait = timeout ?? (Double(req["timeout_ms"]?.intValue ?? 60_000) / 1000 + 10)
        var last: DriverConnectionError?
        for attempt in 0...max(0, retries) {
            do { return try roundTrip(.object(req), wait: wait) }
            catch let e as DriverConnectionError {
                // Running out of time is not retried. The host cancels the call about 2 s after this
                // connection closes, unless a retry with the same id attaches first.
                guard e.retryable else { throw e }
                last = e
                Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))  // same id: never runs twice
            }
        }
        throw last!
    }

    /// Convenience for `call(["name": name, "arguments": arguments])`.
    @discardableResult
    public func call(_ name: String, _ arguments: [String: JSONValue] = [:], timeoutMs: Int? = nil) throws -> JSONValue {
        var req: [String: JSONValue] = ["name": .string(name), "arguments": .object(arguments)]
        if let timeoutMs { req["timeout_ms"] = JSONValue(timeoutMs) }
        return try call(.object(req))
    }

    public func status() throws -> JSONValue { try roundTrip(["op": "status"], wait: 10) }
    /// Every tool with a JSON Schema of its arguments (`input_schema`).
    public func tools() throws -> JSONValue { try roundTrip(["op": "tools"], wait: 10) }
    public func cancel(_ id: String) throws -> JSONValue { try roundTrip(["op": "cancel", "id": .string(id)], wait: 10) }

    // MARK: Transport

    /// Sends one JSON line on a new connection and reads one back.
    public func roundTrip(_ message: JSONValue, wait: TimeInterval) throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw unreachable("socket() failed") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setTimeouts(fd, connectTimeout)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw DriverConnectionError(description: "The socket path is too long: \(socketPath)", retryable: false)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b }; raw[bytes.count] = 0 }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw unreachable(String(cString: strerror(errno))) }

        var data = try message.jsonData()
        data.append(0x0A)
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + sent, data.count - sent) }
            guard n > 0 else { throw unreachable("the connection closed while sending") }
            sent += n
        }

        setTimeouts(fd, wait)
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw DriverConnectionError(description: "No response within \(Int(wait)) s", retryable: false)
            }
            guard n > 0 else { throw unreachable("the connection closed before a response arrived") }
            buf.append(contentsOf: chunk[0..<n])
            if let nl = buf.firstIndex(of: 0x0A) {
                guard let v = try? JSONValue.parse(buf.subdata(in: buf.startIndex..<nl)) else {
                    throw DriverConnectionError(description: "The host sent a response that is not JSON", retryable: false)
                }
                return v
            }
        }
    }

    private func unreachable(_ why: String) -> DriverConnectionError {
        DriverConnectionError(description: "MacDriver host unreachable at \(socketPath): \(why). Is MacDriver.app running?", retryable: true)
    }

    private func setTimeouts(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}
