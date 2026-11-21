import Foundation
import CoreGraphics
import os

public enum Log {
    static let subsystem = "dev.macdriver"
    public static let display = Logger(subsystem: subsystem, category: "display")
    public static let driver = Logger(subsystem: subsystem, category: "driver")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
    public static let input = Logger(subsystem: subsystem, category: "input")
}

/// A FIFO async mutex. Used to serialize mutating tool calls per target so two actions never
/// interleave their events.
public actor AsyncLock {
    private var locked = false
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []

    public init() {}

    public func lock() async throws {
        if !locked { locked = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiters.append((id, c))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.id == id }) {
            let w = waiters.remove(at: i)
            w.cont.resume(throwing: CancellationError())
        }
    }

    public func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().cont.resume() }
    }

    public func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await lock()
        do { let v = try await body(); unlock(); return v } catch { unlock(); throw error }
    }
}

/// Simple thread-safe box.
public final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    public init(_ v: T) { value = v }
    public func withLock<R>(_ body: (inout T) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
    public var get: T { withLock { $0 } }
}

/// Bounded insertion-ordered cache.
public struct LRUCache<K: Hashable, V> {
    private var dict: [K: V] = [:]
    private var order: [K] = []
    public let capacity: Int
    public init(capacity: Int) { self.capacity = capacity }

    public subscript(key: K) -> V? {
        get { dict[key] }
        set {
            if let v = newValue {
                if dict[key] == nil { order.append(key) }
                dict[key] = v
                while order.count > capacity { let k = order.removeFirst(); dict.removeValue(forKey: k) }
            } else {
                dict.removeValue(forKey: key); order.removeAll { $0 == key }
            }
        }
    }
    public var values: [V] { order.compactMap { dict[$0] } }
    /// Oldest first.
    public var items: [(K, V)] { order.compactMap { k in dict[k].map { (k, $0) } } }
    public var count: Int { dict.count }
}

public func monotonicMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

public func sleepMs(_ ms: Int) async throws { try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }

// MARK: Geometry

public extension CGRect {
    var json: [String: Any] { ["x": origin.x, "y": origin.y, "width": width, "height": height] }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    func area() -> CGFloat { isNull || isEmpty ? 0 : width * height }
    func rounded() -> CGRect {
        CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width.rounded(), height: height.rounded())
    }
}

/// Global display coordinates (CoreGraphics: origin at top-left of the main display, y down).
/// Every target exposes coordinates relative to its own top-left corner.
public struct DisplayGeometry: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    /// Bounds in global points.
    public let bounds: CGRect
    /// Backing scale (pixels per point).
    public let scale: CGFloat

    public init(displayID: CGDirectDisplayID, bounds: CGRect, scale: CGFloat) {
        self.displayID = displayID; self.bounds = bounds; self.scale = scale
    }

    public static func of(_ id: CGDirectDisplayID) -> DisplayGeometry {
        let b = CGDisplayBounds(id)
        var scale: CGFloat = 1
        if let m = CGDisplayCopyDisplayMode(id), m.width > 0 { scale = CGFloat(m.pixelWidth) / CGFloat(m.width) }
        return DisplayGeometry(displayID: id, bounds: b, scale: scale)
    }

    public func toLocal(_ global: CGRect) -> CGRect { global.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
    public func toLocal(_ global: CGPoint) -> CGPoint { CGPoint(x: global.x - bounds.minX, y: global.y - bounds.minY) }
    public func toGlobal(_ local: CGRect) -> CGRect { local.offsetBy(dx: bounds.minX, dy: bounds.minY) }
    public func toGlobal(_ local: CGPoint) -> CGPoint { CGPoint(x: local.x + bounds.minX, y: local.y + bounds.minY) }
}

public func activeDisplayIDs() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    return Array(ids.prefix(Int(n)))
}
