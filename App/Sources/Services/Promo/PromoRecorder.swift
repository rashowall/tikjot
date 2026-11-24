#if DEBUG
import AppKit
import AVFoundation
import ScreenCaptureKit

/// Promo video (dev builds only): records this app's own windows — nothing else on the screen, transparent
/// around them — at 60 fps into ProRes 4444 with alpha. Times are host-clock seconds, the same clock the
/// director logs its clicks and keys with, so the edit can put the cursor exactly where the click happened.
final class PromoRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "tikjot.promo.recorder")
    private var started = false
    /// Host time (s) of the first written frame.
    private(set) var firstFrame: Double?

    /// `rect`: the recorded area in global AppKit coordinates (points, origin bottom-left of the main screen).
    func start(rect: NSRect, url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == num }) else { throw CocoaError(.featureUnsupported) }
        // The whole app, so windows that open later (the popover, a sheet) are in the picture too.
        guard let me = content.applications.first(where: { $0.processID == pid }) else { throw CocoaError(.featureUnsupported) }
        let filter = SCContentFilter(display: display, including: [me], exceptingWindows: [])
        let scale = Int(screen.backingScaleFactor)
        let cfg = SCStreamConfiguration()
        // Display-local, top-left origin.
        let r = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        cfg.sourceRect = CGRect(x: r.minX, y: screen.frame.height - r.maxY, width: r.width, height: r.height)
        cfg.width = Int(r.width) * scale
        cfg.height = Int(r.height) * scale
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.backgroundColor = .clear
        cfg.queueDepth = 8
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: cfg.width, AVVideoHeightKey: cfg.height,
        ])
        i.expectsMediaDataInRealTime = true
        w.add(i)
        writer = w; input = i
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = s
        try await s.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let writer, let input,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            firstFrame = sb.presentationTimeStamp.seconds
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sb) }
    }

    func stop() async {
        try? await stream?.stopCapture()
        let (w, i, ok) = queue.sync { (writer, input, started) }
        guard ok else { Log.info("promo recorder: no frames"); return }
        i?.markAsFinished()
        await w?.finishWriting()
    }

    static var hostNow: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
#endif
