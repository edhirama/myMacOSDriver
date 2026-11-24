import Foundation
import CoreGraphics
import CPrivate
import DriverProtocol

/// What this macOS actually provides of the things MacDriver cannot get from public API.
///
/// Each one is probed instead of assumed, so a system update that removes one shows up as a
/// named, reported limitation (in the log and in `status`) rather than a crash or silent
/// misbehaviour.
public struct Capability: Sendable, Equatable {
    public let name: String
    public let available: Bool
    /// What it is for, and what happens without it.
    public let purpose: String
    public let withoutIt: String

    public init(name: String, available: Bool, purpose: String, withoutIt: String) {
        self.name = name; self.available = available; self.purpose = purpose; self.withoutIt = withoutIt
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["available": .bool(available), "purpose": .string(purpose)]
        if !available { o["without_it"] = .string(withoutIt) }
        return .object(o)
    }
}

public enum Capabilities {
    /// The private CGVirtualDisplay classes exist.
    public static var virtualDisplay: Bool {
        ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
            .allSatisfy { NSClassFromString($0) != nil }
    }
    /// SkyLight's event-record call, used to make a window key without activating its app.
    public static var makeKey: Bool { WindowFocuser.isAvailable }
    /// HIServices' AX element → CGWindowID lookup.
    public static var axWindowLookup: Bool { MDHasAXWindowLookup() }

    /// Stage Manager is on (System Settings > Desktop & Dock). It is the user's setting: the
    /// driver only reads it. Seen on macOS 26.2 with it on: windows do not minimize although the
    /// app accepts the request, and the app asked to minimize can come to the front.
    public static var stageManagerOn: Bool {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)   // the user can switch it while the host runs
        return CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain) as? Bool ?? false
    }

    /// Probed at call time (cheap), plus anything the host registered at runtime.
    public static func all(extra: [Capability] = []) -> [Capability] {
        [
            Capability(name: "virtual_display", available: virtualDisplay,
                       purpose: "Creates the virtual monitor (CGVirtualDisplay)",
                       withoutIt: "No virtual monitor can be created; only explicitly named physical displays can be driven"),
            Capability(name: "make_window_key", available: makeKey,
                       purpose: "Makes a window key inside a background app without activating it (SkyLight)",
                       withoutIt: "Mouse events and keystrokes sent to a background app may be ignored; accessibility actions still work"),
            Capability(name: "stage_manager_off", available: !stageManagerOn,
                       purpose: "With Stage Manager off, windows minimize and restore normally",
                       withoutIt: "Stage Manager is on: computer_window cannot minimize (the window stays 'normal'), and the app asked to minimize may come to the front on the user's screen. Turn Stage Manager off in Control Center or System Settings > Desktop & Dock"),
            Capability(name: "event_window_stamp", available: EventPoster.canSetWindowLocation,
                       purpose: "Marks posted mouse events with their position inside the target window (CGEventSetWindowLocation)",
                       withoutIt: "Mouse events reach background apps without a position, so custom views ignore them; accessibility actions still work"),
            Capability(name: "ax_window_lookup", available: axWindowLookup,
                       purpose: "Maps an accessibility window to its window-server id (_AXUIElementGetWindow)",
                       withoutIt: "Windows are matched by owner and frame instead, which can confuse windows with identical frames"),
        ] + extra
    }
}
