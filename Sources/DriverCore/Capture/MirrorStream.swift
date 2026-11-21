import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Live stream of the virtual display into an AVSampleBufferDisplayLayer, for the mirror window.
/// Starting or stopping the stream never affects the display itself.
public final class MirrorStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let layer = AVSampleBufferDisplayLayer()
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "dev.macdriver.mirror")
    public private(set) var isRunning = false
    public var onError: (@Sendable (String) -> Void)?

    public override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0.08, alpha: 1)
    }

    /// Frame rates: the preview does not need to be smooth while a script works, and every frame
    /// costs capture, a copy and a redraw. It runs at the higher rate only while the user is
    /// working in the mirror themself.
    public static let previewFPS = 12
    public static let interactiveFPS = 30
    private var config: SCStreamConfiguration?

    /// `size` is the size the picture is shown at, in pixels. Capturing more than is shown is wasted work.
    public func start(displayID: CGDirectDisplayID, size: CGSize, fps: Int = MirrorStream.previewFPS) async throws {
        if isRunning { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let d = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "MirrorStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "Virtual display not capturable"])
        }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(size.width)
        cfg.height = Int(size.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 3
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        config = cfg
        isRunning = true
    }

    /// Changes the frame rate and picture size of a running stream.
    public func update(fps: Int? = nil, size: CGSize? = nil) async {
        guard let s = stream, let cfg = config else { return }
        if let fps { cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps)) }
        if let size, size.width >= 16, size.height >= 16 { cfg.width = Int(size.width); cfg.height = Int(size.height) }
        try? await s.updateConfiguration(cfg)
    }

    public func stop() async {
        guard let s = stream else { return }
        stream = nil
        isRunning = false
        try? await s.stopCapture()
        await layer.sampleBufferRenderer.flush(removingDisplayedImage: false)
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Skip status-only buffers (idle/blank frames carry no image).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        self.stream = nil
        onError?(error.localizedDescription)
    }
}
