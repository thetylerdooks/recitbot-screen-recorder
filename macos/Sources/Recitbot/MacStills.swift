import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RecitbotCore

/// The Mac side of Stills (hello "keyframes", docs/keyframes.md): the final MP4's length and video track, and one still
/// per time through AVAssetImageGenerator (exact time, the track's transform applied), scaled down to Stills.maxWidth
/// when wider (never up, aspect kept) and written as JPEG by ImageIO at quality 0.75.
/// parity: WindowsFfmpegBackend.MediaInfo + Stills.Probe (probe), WindowsFfmpegBackend.Still + Stills.Encode (grab)
enum MacStills {
    static func probe(_ video: String) throws -> (seconds: Double, hasVideo: Bool) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: video))
        let done = Event(), out = Box<(Double, Bool)>(), failure = Box<Error>()
        Task {
            do {
                let (duration, tracks) = try await asset.load(.duration, .tracks)
                out.value = (duration.isNumeric ? duration.seconds : .nan, tracks.contains { $0.mediaType == .video })
            } catch { failure.value = error }
            done.set()
        }
        if !done.wait(30) { throw CaptureError("probe timed out") }
        if let e = failure.value { throw e }
        guard let r = out.value else { throw CaptureError("probe failed") }
        return (r.0, r.1)
    }

    static func grab(_ video: String, _ ms: Int64, _ jpg: String) throws {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: video)))
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        let done = Event(), img = Box<CGImage>(), failure = Box<Error>()
        g.generateCGImageAsynchronously(for: CMTime(value: ms, timescale: 1000)) { image, _, error in
            img.value = image
            failure.value = error
            done.set()
        }
        if !done.wait(30) { g.cancelAllCGImageGeneration(); throw CaptureError("frame grab timed out") }
        guard let full = img.value else { throw failure.value ?? CaptureError("frame grab failed") }
        let image = try scaled(full)
        try? FileManager.default.removeItem(atPath: jpg)
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: jpg) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CaptureError("no JPEG encoder")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: Double(Stills.quality) / 100] as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw CaptureError("JPEG not written") }
    }

    /// At most Stills.maxWidth wide, the height to the same scale (rounded, at least 1); a narrower image as it is.
    static func scaled(_ image: CGImage) throws -> CGImage {
        if image.width <= Stills.maxWidth { return image }
        let w = Stills.maxWidth, h = max(1, Int((Double(image.height) * Double(w) / Double(image.width)).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CaptureError("frame scale failed") }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw CaptureError("frame scale failed") }
        return out
    }
}
