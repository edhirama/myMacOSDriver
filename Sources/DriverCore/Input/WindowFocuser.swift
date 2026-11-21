import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

/// Makes a window the key window *of its own application* without activating that application.
///
/// AppKit treats a click on a non-key window of an inactive app as an activation click and
/// swallows it, so a synthetic click alone never reaches the view. Activating the app would steal
/// the user's focus. Instead we send the window server's private "key window changed" event
/// records to the target process (the technique yabai uses for focus-without-raise). The user's
/// frontmost app is unchanged and keeps receiving their real keyboard input.
///
/// Symbols are resolved at runtime; if they are unavailable the driver reports a warning and
/// proceeds with plain per-process events.
///
/// A key window alone does not get clicks delivered while the app knows it is inactive; see
/// `ensureBelievesActive` for the second half.
public enum WindowFocuser {
    private typealias PostEventRecordTo = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> CGError
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let postRecord: PostEventRecordTo? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let s = dlsym(h, "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(s, to: PostEventRecordTo.self)
    }()
    private static let getPSN: GetProcessForPID? = {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(s, to: GetProcessForPID.self)
    }()

    public static var isAvailable: Bool { postRecord != nil && getPSN != nil }

    /// Returns true when the records were delivered.
    @discardableResult
    public static func makeKey(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let post = postRecord, let psnFor = getPSN else { return false }
        var psn = ProcessSerialNumber()
        guard psnFor(pid, &psn) == noErr else { return false }
        var ok = true
        for kind: UInt8 in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0xF8)
            bytes[0x04] = 0xF8
            bytes[0x08] = kind
            bytes[0x3A] = 0x10
            var wid = windowID
            withUnsafeBytes(of: &wid) { for i in 0..<4 { bytes[0x3C + i] = $0[i] } }
            for i in 0x20..<0x30 { bytes[i] = 0xFF }
            ok = ok && bytes.withUnsafeBufferPointer { post(&psn, $0.baseAddress!) } == .success
        }
        return ok
    }

    // MARK: Believed-active

    /// Apps the driver has told "you are active", so the belief can be withdrawn later.
    private static let believed = Locked<Set<pid_t>>([])

    /// AppKit applies its first-click rule whenever the *app* knows it is inactive: a click on
    /// a view that does not accept first clicks (the default) is discarded. Making a window key
    /// is not enough. So the app is told it became active, with the same AppKit-defined event the
    /// window server sends on a real activation, delivered to that process only.
    ///
    /// Nothing changes outside that process: the window server's frontmost app, the menu bar and
    /// the destination of the user's real keystrokes all stay as they were. Only the app's own
    /// view of itself changes, which is what AppKit consults.
    ///
    /// The belief is left in place between actions (withdrawing it would close menus and
    /// popovers an action has just opened) and withdrawn by `withdrawActiveBelief`.
    @discardableResult
    public static func ensureBelievesActive(pid: pid_t) -> Bool {
        // The app answers this attribute itself, from its own idea of whether it is active.
        if AX.bool(AX.app(pid), kAXFrontmostAttribute) == true { return true }
        guard postActivation(true, pid: pid) else { return false }
        believed.withLock { _ = $0.insert(pid) }
        return true
    }

    /// Tells every app the driver marked active (or just `pid`) that it is inactive again,
    /// unless it really is the frontmost app by now.
    public static func withdrawActiveBelief(pid only: pid_t? = nil) {
        let pids = believed.withLock { set -> [pid_t] in
            let out = only.map { set.contains($0) ? [$0] : [] } ?? Array(set)
            for p in out { set.remove(p) }
            return out
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for p in pids where p != front { _ = postActivation(false, pid: p) }
    }

    /// AppKit-defined event, subtype 1 (application activated) or 2 (deactivated).
    private static func postActivation(_ active: Bool, pid: pid_t) -> Bool {
        guard let e = NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: 0, context: nil, subtype: active ? 1 : 2, data1: 0, data2: 0)?.cgEvent else { return false }
        e.postToPid(pid)
        return true
    }

    /// Whether `windowID` is currently the focused (key) window of its app, per accessibility.
    public static func isKey(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let fw = AX.element(AX.app(pid), kAXFocusedWindowAttribute) else { return false }
        return AX.windowID(fw) == windowID
    }

    /// Ensures the window is key within its app; returns a description of what was done.
    /// Always re-sent before pointer input: it is cheap and idempotent, and the app's notion of its
    /// key window can change at any time (the user, a sheet, another script call).
    public static func ensureKey(pid: pid_t, windowID: CGWindowID, axWindow: AXUIElement?) -> Bool {
        if let w = axWindow { AX.set(w, kAXMainAttribute, kCFBooleanTrue) }
        return makeKey(pid: pid, windowID: windowID)
    }
}
