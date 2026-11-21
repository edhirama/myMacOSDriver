import Foundation
import CoreGraphics
import DriverProtocol

/// A `computer` target: the local virtual monitor (default) or an explicitly named physical display.
public struct Target: Sendable, Equatable {
    public let id: String
    public let displayID: CGDirectDisplayID
    public let isVirtual: Bool

    public var geometry: DisplayGeometry { DisplayGeometry.of(displayID) }

    public var json: JSONValue {
        let g = geometry
        return ["id": .string(id), "kind": .string(isVirtual ? "virtual" : "physical"),
                "display_id": .number(Double(displayID)),
                "size": ["width": .number(g.bounds.width), "height": .number(g.bounds.height)],
                "scale": .number(Double(g.scale))]
    }
}

public final class TargetRegistry: Sendable {
    private let display: VirtualDisplayManager
    public static let virtualID = "virtual"

    public init(display: VirtualDisplayManager) { self.display = display }

    /// Resolves the `computer` argument. Omitted means the virtual monitor; physical displays must
    /// be named explicitly. Never falls back to another target.
    public func resolve(_ computer: String?) throws -> Target {
        let name = computer ?? Self.virtualID
        if name == Self.virtualID {
            guard let id = display.displayID else {
                throw DriverError(.targetUnavailable, "The virtual monitor is not running (state: \(display.state))")
            }
            return Target(id: Self.virtualID, displayID: id, isVirtual: true)
        }
        if name.hasPrefix("display:"), let n = UInt32(name.dropFirst(8)) {
            guard activeDisplayIDs().contains(n) else {
                throw DriverError(.unknownTarget, "Display \(n) is not connected", details: ["available": .array(all().map { .string($0.id) })])
            }
            if n == display.displayID {
                throw DriverError(.invalidArgument, "Use computer: \"virtual\" for the virtual monitor")
            }
            return Target(id: name, displayID: n, isVirtual: false)
        }
        throw DriverError(.unknownTarget, "Unknown computer '\(name)'", details: ["available": .array(all().map { .string($0.id) })])
    }

    public func all() -> [Target] {
        var out: [Target] = []
        if let v = display.displayID { out.append(Target(id: Self.virtualID, displayID: v, isVirtual: true)) }
        for id in activeDisplayIDs() where id != display.displayID {
            out.append(Target(id: "display:\(id)", displayID: id, isVirtual: false))
        }
        return out
    }
}
