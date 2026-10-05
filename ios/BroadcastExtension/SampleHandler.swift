import ReplayKit
import CoreImage
import UIKit

/// ReplayKit Broadcast Upload Extension entry point. This runs as its own
/// process (NOT inside the main app) once the user starts a broadcast via
/// RPSystemBroadcastPickerView (see ios/NOTES_XCODE_SETUP.md). Its only
/// job here is to throttle incoming video frames and drop the latest one
/// into the shared App Group container, where service_ios.dart's
/// `captureOnce()` picks it up.
///
/// IMPORTANT: extensions have a strict ~50MB memory ceiling. Do NOT
/// buffer frames or run OCR/AI calls in here — write-and-forget only.
class SampleHandler: RPBroadcastSampleHandler {

    private let appGroupId = "group.com.example.screentranslate"
    private let ciContext = CIContext() // reused across frames, not per-frame
    private var lastWriteTime: CFAbsoluteTime = 0
    private let minWriteInterval: CFAbsoluteTime = 1.0 // write at most 1 fps — this
    // is a "grab the current screen on demand" feature, not continuous
    // mirroring, so there's no reason to burn CPU/battery encoding PNGs
    // at 30-60fps.

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // Nothing to set up — container URL is resolved fresh per frame
        // via FileManager, which is cheap and avoids stale-handle bugs if
        // the app was reinstalled mid-broadcast.
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastWriteTime >= minWriteInterval else { return }
        lastWriteTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let width = cgImage.width
        let height = cgImage.height
        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else { return }

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return }

        let frameURL = containerURL.appendingPathComponent("latest_frame.png")
        let metaURL = containerURL.appendingPathComponent("latest_frame.json")

        do {
            // Write to a temp file then rename, so the Dart side never
            // reads a half-written PNG.
            let tmpURL = containerURL.appendingPathComponent("latest_frame.tmp")
            try pngData.write(to: tmpURL)
            _ = try? FileManager.default.removeItem(at: frameURL)
            try FileManager.default.moveItem(at: tmpURL, to: frameURL)

            let meta = "{\"width\":\(width),\"height\":\(height)}"
            try meta.write(to: metaURL, atomically: true, encoding: .utf8)
        } catch {
            // Extensions have no visible console in production; swallow
            // write errors rather than crashing the broadcast.
        }
    }

    override func broadcastFinished() {
        // Nothing to tear down — the last frame stays in the container
        // so the user can still translate "what was last on screen".
    }
}
