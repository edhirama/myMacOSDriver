import Foundation
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import DriverProtocol

/// Fresh captures via ScreenCaptureKit. Nothing is cached: every call reflects the screen as it
/// is at that moment.
public final class ScreenshotService: @unchecked Sendable {
    public init() {}

    private func content() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw DriverError(.permissionMissing,
                              "Screen Recording permission is required (System Settings > Privacy & Security > Screen & System Audio Recording): \(error.localizedDescription)")
        }
    }

    /// Captures a whole display at `outputSize` pixels.
    public func captureDisplay(_ displayID: CGDirectDisplayID, outputSize: CGSize) async throws -> CGImage {
        let c = try await content()
        guard let d = c.displays.first(where: { $0.displayID == displayID }) else {
            throw DriverError(.targetUnavailable, "Display \(displayID) is not available for capture")
        }
        let filter = SCContentFilter(display: d, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(outputSize.width))
        cfg.height = max(1, Int(outputSize.height))
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.scalesToFit = true
        return try await capture(filter, cfg)
    }

    /// Captures a single window, independent of what covers it.
    public func captureWindow(_ windowID: CGWindowID, outputSize: CGSize) async throws -> CGImage {
        let c = try await content()
        guard let w = c.windows.first(where: { $0.windowID == windowID }) else {
            throw DriverError(.unknownWindow, "Window \(windowID) is not on screen (it may be minimized or closed)")
        }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(outputSize.width))
        cfg.height = max(1, Int(outputSize.height))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.scalesToFit = true
        return try await capture(filter, cfg)
    }

    private func capture(_ filter: SCContentFilter, _ cfg: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            let ns = error as NSError
            if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue {
                throw DriverError(.permissionMissing, "Screen Recording permission was declined")
            }
            throw DriverError(.actionFailed, "Capture failed: \(error.localizedDescription)")
        }
    }

    // MARK: Encoding

    public static func encode(_ image: CGImage, format: String) throws -> Data {
        let data = NSMutableData()
        let type = (format == "jpeg" ? UTType.jpeg : UTType.png).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw DriverError(.internalError, "Could not create image encoder")
        }
        let props: [CFString: Any] = format == "jpeg" ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DriverError(.internalError, "Image encoding failed") }
        return data as Data
    }

    // MARK: Change detection

    /// A tiny perceptual fingerprint of an image: draws it into 64x36 grayscale and hashes the bytes.
    public static func fingerprint(_ image: CGImage) -> UInt64 {
        let w = 64, h = 36
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        for b in buf { hash ^= UInt64(b >> 2); hash = hash &* 0x100000001b3 } // drop low bits: ignore noise
        return hash
    }

    /// Low-resolution capture used for before/after comparison and settling.
    public func displayFingerprint(_ displayID: CGDirectDisplayID) async -> UInt64? {
        guard let img = try? await captureDisplay(displayID, outputSize: CGSize(width: 320, height: 180)) else { return nil }
        return Self.fingerprint(img)
    }

    /// Waits until two consecutive fingerprints match (screen stopped changing) or the budget runs
    /// out. Returns the final fingerprint.
    public func waitForSettle(_ displayID: CGDirectDisplayID, budgetMs: Int = 1200, intervalMs: Int = 90) async -> UInt64? {
        let start = monotonicMs()
        var last = await displayFingerprint(displayID)
        while monotonicMs() - start < budgetMs {
            if Task.isCancelled { break }
            try? await sleepMs(intervalMs)
            let cur = await displayFingerprint(displayID)
            if cur == last { return cur }
            last = cur
        }
        return last
    }
}
