import Foundation
import ApplicationServices
import CoreGraphics
import DriverProtocol

/// What a screenshot id refers to, so later `in + x + y` positions can be mapped back to the
/// screen exactly as the caller saw it.
public struct ScreenshotRecord: Sendable {
    public let id: String
    public let targetID: String
    public let displayID: CGDirectDisplayID
    /// nil for a full-display capture.
    public let windowID: CGWindowID?
    /// Window frame at capture time (global points) for window captures.
    public let windowFrame: CGRect?
    /// Top-left of the image in target-display coordinates (points).
    public let origin: CGPoint
    /// Image size in pixels.
    public let pixelSize: CGSize
    /// Image pixels per point.
    public let scale: CGFloat
    public let capturedAt: Date
}

public final class ScreenshotRegistry: Sendable {
    private let store = Locked(LRUCache<String, ScreenshotRecord>(capacity: 256))
    private let counter = Locked(0)
    private let session = String(UUID().uuidString.prefix(6)).lowercased()

    public init() {}

    public func newID() -> String { "shot:\(session).\(counter.withLock { $0 += 1; return $0 })" }

    public func add(_ r: ScreenshotRecord) { store.withLock { $0[r.id] = r } }

    public func get(_ id: String) throws -> ScreenshotRecord {
        guard let r = store.withLock({ $0[id] }) else {
            throw DriverError(.unknownScreenshot, "Unknown screenshot '\(id)'; take a new computer_screenshot")
        }
        return r
    }
}

/// The input location established by the last valid click on each target. Typing and keys go
/// only to this location; if it is no longer valid, input is rejected rather than redirected.
public struct InputFocus: Sendable {
    public let pid: pid_t
    public let windowID: CGWindowID
    /// The element that held keyboard focus right after the click (when readable).
    public let element: AXUIElement?
    public let setAt: Date
    public let via: String
}

public final class FocusRegistry: Sendable {
    private let store = Locked<[String: InputFocus]>([:])
    public init() {}
    public func set(_ target: String, _ f: InputFocus) { store.withLock { $0[target] = f } }
    public func get(_ target: String) -> InputFocus? { store.get[target] }
    public func clear(_ target: String) { store.withLock { $0[target] = nil } }
    public func clearAll() { store.withLock { $0.removeAll() } }
}
