import Vision
import CoreVideo
import CoreImage // needed to crop the pixel buffer ourselves before OCR, instead of letting Vision scan the whole frame and only filter results afterward.
import UIKit

/// Wraps VNRecognizeTextRequest. Stateless and cheap to call repeatedly —
/// the throttling/frequency control lives in the view model, not here.
final class OCRProcessor {

    // One reusable CIContext for cropping, created once rather than per-call
    // (CIContext setup has real overhead). Cropping itself is still cheap in
    // practice since it only runs on the manual "Ask" tap, not on every
    // live-preview frame.
    private let ciContext = CIContext()

    /// Runs OCR on a single pixel buffer.
    /// - Parameters:
    ///   - pixelBuffer: raw camera frame (BGRA), always in the sensor's
    ///     native landscape orientation — CameraManager no longer pre-rotates it.
    ///   - regionOfInterest: optional crop in Vision's normalized, bottom-left-origin
    ///     coordinate space (0...1), defined against the UPRIGHT (post-rotation)
    ///     image. Pass nil to scan the full frame.
    ///   - recognitionLevel: the live preview passes `.fast` (cheap, runs every
    ///     ~1s); the manual "Ask" action passes `.accurate` since it only runs
    ///     once per tap and needs to read smaller multiple-choice text.
    ///   - minimumTextHeight: fraction of the FULL analyzed image height —
    ///     when cropToRegion is true, "full" means the small cropped image,
    ///     so this can be set low without risking false positives elsewhere.
    ///   - cropToRegion: when true (and a regionOfInterest is given), the
    ///     pixel buffer is physically rotated upright and cropped to that
    ///     rectangle before Vision ever sees it, so the target text occupies
    ///     nearly the whole analyzed image.
    func recognizeText(
        in pixelBuffer: CVPixelBuffer,
        regionOfInterest: CGRect? = nil,
        recognitionLevel: VNRequestTextRecognitionLevel = .fast,
        minimumTextHeight: Float = 0.02,
        cropToRegion: Bool = false
    ) async -> String {

        var bufferToAnalyze = pixelBuffer
        var visionROI = regionOfInterest

        // FIX: orientation is now resolved to exactly one value depending on
        // path, instead of always hardcoding `.right`.
        // - Full-frame path (cropToRegion false, or crop fails): the buffer
        //   is still raw sensor landscape, so `.right` is correct here, same
        //   as before.
        // - Cropped path: cropPixelBuffer (below) now rotates the image to
        //   upright itself, BEFORE cropping, so by the time Vision sees the
        //   cropped buffer it is already correctly oriented — telling the
        //   handler `.right` again here would rotate it a second time. This
        //   double rotation was the actual root cause of garbage OCR results
        //   like "i" or "f 7,1" even when the ROI box was positioned correctly.
        var handlerOrientation: CGImagePropertyOrientation = .right

        if cropToRegion,
           let roi = regionOfInterest,
           let cropped = Self.cropPixelBuffer(pixelBuffer, toNormalizedRect: roi, using: ciContext) {
            bufferToAnalyze = cropped
            visionROI = nil
            handlerOrientation = .up // FIX: crop already rotated the image upright — don't rotate again.
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }

            request.recognitionLevel = recognitionLevel
            request.recognitionLanguages = ["vi-VN", "en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = minimumTextHeight

            // Only set Vision's regionOfInterest when we did NOT already
            // crop the buffer ourselves above.
            if let visionROI {
                request.regionOfInterest = visionROI
            }

            // FIX: orientation hint now comes from handlerOrientation
            // (resolved above) instead of always being `.right`.
            let handler = VNImageRequestHandler(cvPixelBuffer: bufferToAnalyze, orientation: handlerOrientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: - Cropping

    /// Crops `pixelBuffer` to `normalizedRect` (bottom-left-origin, 0...1 —
    /// the same coordinate space Vision's regionOfInterest uses) and returns
    /// a new, smaller CVPixelBuffer containing just that region, already
    /// rotated upright.
    private static func cropPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        toNormalizedRect normalizedRect: CGRect,
        using context: CIContext
    ) -> CVPixelBuffer? {
        let rawImage = CIImage(cvPixelBuffer: pixelBuffer)

        // FIX: rotate the raw sensor-orientation image to upright FIRST,
        // using the same rotation Vision would normally apply via the
        // `.right` handler hint on the full-frame path. Previously this
        // cropped the RAW, unrotated buffer using a rect defined in
        // upright/bottom-left-origin coordinates — on a still-landscape
        // buffer that rectangle lands on entirely the wrong pixels, which is
        // why the crop silently grabbed nonsense instead of the question.
        let ciImage = rawImage.oriented(.right)
        let extent = ciImage.extent

        // CIImage's coordinate space is already bottom-left-origin, matching
        // the normalizedRect convention, so no extra Y-flip is needed here.
        let pixelRect = CGRect(
            x: normalizedRect.minX * extent.width,
            y: normalizedRect.minY * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        ).integral

        guard pixelRect.width > 0, pixelRect.height > 0 else { return nil }

        // Move the cropped region's origin back to (0,0) — cropped(to:) keeps
        // the original offset, but the destination buffer we render into
        // starts at (0,0), so without this translation the render would land
        // in the wrong spot (or clip entirely).
        let translated = ciImage
            .cropped(to: pixelRect)
            .transformed(by: CGAffineTransform(translationX: -pixelRect.origin.x, y: -pixelRect.origin.y))

        var outputBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(pixelRect.width),
            Int(pixelRect.height),
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            attrs as CFDictionary,
            &outputBuffer
        )
        guard status == kCVReturnSuccess, let outputBuffer else { return nil }

        context.render(translated, to: outputBuffer)
        return outputBuffer
    }
}