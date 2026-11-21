import Foundation
import ApplicationServices

/// Listens to one application's accessibility notifications for the duration of an action.
///
/// This is how the driver learns that an app reacted *when it reacts*: the app says "value
/// changed", "window moved" or "sheet created" itself, instead of the driver sleeping a fixed
/// time and comparing before/after. Apps with poor accessibility support simply stay silent, and
/// callers fall back to comparing the screen.
public final class AXNotificationWatch: @unchecked Sendable {
    /// Notification → the evidence name reported to the caller, and whether it proves an effect.
    /// Focus notifications are evidence only: making a window key (which the driver does itself
    /// before sending input) also produces them.
    static let known: [(name: String, evidence: String, confirms: Bool)] = [
        (kAXValueChangedNotification, "ax_value_changed", true),
        (kAXSelectedTextChangedNotification, "ax_selection_changed", true),
        (kAXSelectedChildrenChangedNotification, "ax_selection_changed", true),
        (kAXSelectedRowsChangedNotification, "ax_selection_changed", true),
        (kAXWindowMovedNotification, "window_frame_changed", true),
        (kAXWindowResizedNotification, "window_frame_changed", true),
        (kAXWindowCreatedNotification, "window_created", true),
        (kAXSheetCreatedNotification, "sheet_created", true),
        (kAXWindowMiniaturizedNotification, "window_minimized", true),
        (kAXWindowDeminiaturizedNotification, "window_restored", true),
        (kAXMenuOpenedNotification, "menu_opened", true),
        (kAXTitleChangedNotification, "title_changed", true),
        (kAXUIElementDestroyedNotification, "element_destroyed", false),
        (kAXFocusedUIElementChangedNotification, "focus_changed", false),
        (kAXFocusedWindowChangedNotification, "window_focus_changed", false),
        (kAXMainWindowChangedNotification, "window_focus_changed", false),
    ]

    /// What the C callback writes into. It is retained separately for the callback, so a
    /// notification that arrives while the watch is being torn down never touches freed memory.
    fileprivate final class Inbox: Sendable {
        private let state = Locked((names: [String](), lastAt: 0))
        func add(_ n: String) { state.withLock { $0.names.append(n); $0.lastAt = monotonicMs() } }
        var all: [String] { state.withLock { $0.names } }
        var count: Int { state.withLock { $0.names.count } }
        var last: Int { state.withLock { $0.lastAt } }
    }

    private let inbox = Inbox()
    private let lock = NSLock()
    private var observer: AXObserver?
    private var refcon: Unmanaged<Inbox>?
    private let app: AXUIElement
    private var registered: [String] = []

    /// Returns nil when the app cannot be observed (no accessibility permission, app gone).
    public init?(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
        var obs: AXObserver?
        guard AXObserverCreate(pid, axWatchCallback, &obs) == .success, let obs else { return nil }
        observer = obs
        let box = Unmanaged.passRetained(inbox)
        for k in Self.known where AXObserverAddNotification(obs, app, k.name as CFString, box.toOpaque()) == .success {
            registered.append(k.name)
        }
        guard !registered.isEmpty else { box.release(); return nil }
        refcon = box
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    deinit { stop() }

    /// Notifications received so far, in order.
    public var notifications: [String] { inbox.all }
    public var count: Int { inbox.count }

    /// Evidence names for what was received, and whether any of it proves an effect.
    public var evidence: (names: [String], confirms: Bool) {
        let got = Set(notifications)
        var out: [String] = [], confirms = false
        for k in Self.known where got.contains(k.name) {
            if !out.contains(k.evidence) { out.append(k.evidence) }
            confirms = confirms || k.confirms
        }
        return (out, confirms)
    }

    /// Returns as soon as more than `count` notifications have arrived (true), or at the timeout.
    /// The wait checks a local counter every few milliseconds; no accessibility calls are made.
    @discardableResult
    public func waitForEvent(after count: Int = 0, timeoutMs: Int) async -> Bool {
        let deadline = monotonicMs() + timeoutMs
        while true {
            if self.count > count { return true }
            if monotonicMs() >= deadline || Task.isCancelled { return false }
            try? await sleepMs(8)
        }
    }

    /// Waits until the app has been silent for `quietMs` (it finished reacting) or the budget ends.
    public func waitQuiet(quietMs: Int = 60, budgetMs: Int) async {
        let deadline = monotonicMs() + budgetMs
        while monotonicMs() < deadline, !Task.isCancelled {
            if monotonicMs() - inbox.last >= quietMs { return }
            try? await sleepMs(10)
        }
    }

    public func stop() {
        lock.lock(); let obs = observer; observer = nil; let box = refcon; refcon = nil; lock.unlock()
        guard let obs else { return }
        for n in registered { AXObserverRemoveNotification(obs, app, n as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        // Callbacks run on the main run loop: releasing there, after removal, means none is in flight.
        DispatchQueue.main.async { box?.release() }
    }
}

private func axWatchCallback(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<AXNotificationWatch.Inbox>.fromOpaque(refcon).takeUnretainedValue().add(name as String)
}
