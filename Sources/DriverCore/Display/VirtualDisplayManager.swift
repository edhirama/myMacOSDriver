import Foundation
import CoreGraphics
import CPrivate

/// Owns the single virtual display for the lifetime of the host process.
///
/// Lifecycle guarantees:
/// - Created once in `start()` and released only in `stop()` (or when the process exits, at which
///   point macOS removes it and moves its windows to a remaining display).
/// - Opening/closing the mirror, pausing, or changing control never touches it.
/// - All display configuration uses `.forAppOnly`, so if the host crashes, macOS reverts the
///   arrangement automatically.
///
/// Arrangement guard: macOS inserts a new display into the arrangement and shifts physical
/// displays to make room (observed on macOS 26: an external monitor moved from x=1512 to x=3432).
/// After creation, and after every reconfiguration, the guard restores the physical displays'
/// original origins and parks the virtual display diagonally off the far corner of the physical
/// layout, so it touches the physical layout at a single point and has no shared edge.
public final class VirtualDisplayManager: @unchecked Sendable {
    public struct Config: Sendable {
        public var name = "MacDriver Virtual Monitor"
        public var width = 1920
        public var height = 1080
        public var hiDPI = true
        public var refreshRate = 60.0
        public init() {}
    }

    public enum State: Equatable, Sendable {
        case idle
        case starting
        case ready(displayID: CGDirectDisplayID)
        case failed(String)
        case stopped
    }

    public let config: Config
    private let lock = NSLock()
    private var display: CGVirtualDisplay?
    private var _state: State = .idle
    /// Physical arrangement recorded before creation: display id -> global origin.
    private var physicalOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var originalMain: CGDirectDisplayID = 0
    private var reconfigRegistered = false
    private var guardScheduled = false
    public var onStateChange: (@Sendable (State) -> Void)?
    public var onGuardEvent: (@Sendable (String) -> Void)?

    public init(config: Config = Config()) { self.config = config }

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    public var displayID: CGDirectDisplayID? {
        if case .ready(let id) = state { return id }
        return nil
    }

    public var geometry: DisplayGeometry? { displayID.map { DisplayGeometry.of($0) } }

    private func setState(_ s: State) {
        lock.lock(); _state = s; lock.unlock()
        onStateChange?(s)
    }

    /// Creates the display (idempotent: returns the existing one if already running).
    @discardableResult
    public func start() throws -> CGDirectDisplayID {
        if let id = displayID { return id }
        setState(.starting)
        // The classes are weakly linked: on a macOS without them, fail with a reason instead of crashing.
        guard Capabilities.virtualDisplay else {
            setState(.failed("This macOS version does not provide CGVirtualDisplay, so the virtual monitor cannot be created"))
            throw DisplayError.creationFailed
        }

        originalMain = CGMainDisplayID()
        physicalOrigins = Dictionary(uniqueKeysWithValues: activeDisplayIDs().map { ($0, CGDisplayBounds($0).origin) })

        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.global(qos: .userInitiated)
        desc.name = config.name
        let scale = config.hiDPI ? 2 : 1
        desc.maxPixelsWide = UInt32(config.width * scale)
        desc.maxPixelsHigh = UInt32(config.height * scale)
        // ~24" panel: keeps macOS's DPI heuristics sane.
        desc.sizeInMillimeters = CGSize(width: 527, height: 296)
        desc.vendorID = 0x4D44   // "MD"
        desc.productID = 0x0001
        desc.serialNum = 0x0001
        desc.terminationHandler = { [weak self] _, _ in
            self?.setState(.failed("Virtual display was terminated by the system"))
        }

        guard let vd = CGVirtualDisplay(descriptor: desc) else {
            setState(.failed("CGVirtualDisplay could not be created"))
            throw DisplayError.creationFailed
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(config.width), height: UInt(config.height), refreshRate: config.refreshRate)]
        guard vd.apply(settings) else {
            setState(.failed("CGVirtualDisplay rejected its settings"))
            throw DisplayError.settingsRejected
        }
        lock.lock(); display = vd; lock.unlock()

        // Wait for the display to become active.
        let id = vd.displayID
        let deadline = Date().addingTimeInterval(5)
        while !activeDisplayIDs().contains(id) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard activeDisplayIDs().contains(id) else {
            lock.lock(); display = nil; lock.unlock()
            setState(.failed("Virtual display never became active"))
            throw DisplayError.neverActivated
        }
        physicalOrigins.removeValue(forKey: id)
        setState(.ready(displayID: id))
        try enforceArrangement()
        registerReconfigurationCallback()
        Log.display.info("Virtual display \(id) ready at \(String(describing: CGDisplayBounds(id)))")
        return id
    }

    /// Releases the display. macOS moves any remaining windows to a physical display.
    public func stop() {
        unregisterReconfigurationCallback()
        lock.lock(); display = nil; lock.unlock()
        setState(.stopped)
    }

    // MARK: Arrangement guard

    public enum DisplayError: Error, CustomStringConvertible {
        case creationFailed, settingsRejected, neverActivated, configurationFailed(Int32), arrangementChanged(String)
        public var description: String {
            switch self {
            case .creationFailed: return "CGVirtualDisplay could not be created"
            case .settingsRejected: return "CGVirtualDisplay rejected its settings"
            case .neverActivated: return "Virtual display never became active"
            case .configurationFailed(let e): return "Display configuration failed (CGError \(e))"
            case .arrangementChanged(let s): return "Physical arrangement could not be restored: \(s)"
            }
        }
    }

    /// Where the virtual display should live: diagonally off the bottom-right corner of the
    /// physical layout's bounding box, touching it at a single point.
    func parkingOrigin() -> CGPoint {
        var union = CGRect.null
        for (id, origin) in physicalOrigins {
            let b = CGDisplayBounds(id)
            union = union.union(CGRect(origin: origin, size: b.size))
        }
        return CGPoint(x: union.maxX, y: union.maxY)
    }

    /// Returns a human-readable list of deviations from the desired arrangement (empty when correct).
    public func arrangementDeviations() -> [String] {
        guard let vid = displayID else { return [] }
        var out: [String] = []
        let active = Set(activeDisplayIDs())
        for (id, origin) in physicalOrigins where active.contains(id) {
            let now = CGDisplayBounds(id).origin
            if now != origin { out.append("display \(id) at \(now) instead of \(origin)") }
        }
        let park = parkingOrigin()
        if CGDisplayBounds(vid).origin != park { out.append("virtual display at \(CGDisplayBounds(vid).origin) instead of \(park)") }
        if active.contains(originalMain), CGMainDisplayID() != originalMain {
            out.append("main display is \(CGMainDisplayID()) instead of \(originalMain)")
        }
        return out
    }

    public func enforceArrangement() throws {
        guard let vid = displayID else { return }
        // Physical hardware changed (monitor plugged/unplugged): adopt the new physical layout as
        // the one to preserve, but never reposition physical displays based on a stale record.
        let active = activeDisplayIDs()
        let currentPhysical = Set(active.filter { $0 != vid })
        if currentPhysical != Set(physicalOrigins.keys) {
            physicalOrigins = Dictionary(uniqueKeysWithValues: currentPhysical.map { ($0, CGDisplayBounds($0).origin) })
            if !currentPhysical.contains(originalMain) { originalMain = CGMainDisplayID() }
            onGuardEvent?("Physical displays changed; preserving the new arrangement")
        }
        let deviations = arrangementDeviations()
        if deviations.isEmpty { return }

        var cfg: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&cfg)
        guard err == .success, let cfg else { throw DisplayError.configurationFailed(err.rawValue) }
        for (id, origin) in physicalOrigins {
            CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
        }
        let park = parkingOrigin()
        CGConfigureDisplayOrigin(cfg, vid, Int32(park.x), Int32(park.y))
        err = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
        guard err == .success else { throw DisplayError.configurationFailed(err.rawValue) }

        let remaining = arrangementDeviations()
        if remaining.isEmpty {
            onGuardEvent?("Arrangement restored: \(deviations.joined(separator: "; "))")
        } else {
            onGuardEvent?("Arrangement still deviates: \(remaining.joined(separator: "; "))")
            throw DisplayError.arrangementChanged(remaining.joined(separator: "; "))
        }
    }

    private func registerReconfigurationCallback() {
        guard !reconfigRegistered else { return }
        reconfigRegistered = true
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }

    private func unregisterReconfigurationCallback() {
        guard reconfigRegistered else { return }
        reconfigRegistered = false
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Debounced: our own configuration changes also trigger callbacks, so the guard re-checks
    /// (idempotently) once things settle instead of fighting each intermediate step.
    fileprivate func scheduleGuard() {
        lock.lock()
        if guardScheduled { lock.unlock(); return }
        guardScheduled = true
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.guardScheduled = false; self.lock.unlock()
            do { try self.enforceArrangement() } catch {
                Log.display.error("Arrangement guard failed: \(String(describing: error))")
            }
        }
    }
}

private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
    let mgr = Unmanaged<VirtualDisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
    mgr.scheduleGuard()
}
