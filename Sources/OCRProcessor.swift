import Vision
import CoreVideo
import CoreImage // CHANGE: needed to crop the pixel buffer ourselves before OCR, instead of letting Vision scan the whole frame and only filter results afterward.
import UIKit

/// Wraps VNRecognizeTextRequest. Stateless and cheap to call repeatedly —
/// the throttling/frequency control lives in the view model, not here.
final class OCRProcessor {

    // CHANGE: one reusable CIContext for cropping, created once rather than
    // per-call (CIContext setup has real overhead). Cropping itself is still
    // cheap in practice since it only runs on the manual "Ask" tap, not on
    // every live-preview frame.
    private let ciContext = CIContext()

    /// Runs OCR on a single pixel buffer.
    /// - Parameters:
    ///   - pixelBuffer: raw camera frame (BGRA).
    ///   - regionOfInterest: optional crop in Vision's normalized, bottom-left-origin
    ///     coordinate space (0...1). Pass nil to scan the full frame.
    ///   - recognitionLevel: CHANGE — now a parameter instead of a hardcoded
    ///     `.fast`. The live preview keeps passing `.fast` (cheap, runs every
    ///     ~1s); the manual "Ask" action now passes `.accurate` since it only
    ///     runs once per tap and needs to read smaller multiple-choice text.
    ///   - minimumTextHeight: CHANGE — now a parameter instead of a hardcoded
    ///     0.02. Vision measures this as a fraction of the FULL analyzed
    ///     image height, not the ROI box — so small answer-option text was
    ///     being silently discarded before recognition even started.
    ///   - cropToRegion: CHANGE — new flag. When true (and a regionOfInterest
    ///     is given), the pixel buffer is physically cropped to that
    ///     rectangle before Vision ever sees it, rather than asking Vision
    ///     to scan the whole frame and filter results down to the ROI
    ///     afterward. This makes the target text occupy nearly the whole
    ///     analyzed image, so `minimumTextHeight` is checked against a far
    ///     more favorable scale.
    func recognizeText(
        in pixelBuffer: CVPixelBuffer,
        regionOfInterest: CGRect? = nil,
        recognitionLevel: VNRequestTextRecognitionLevel = .fast, // CHANGE: default preserves old behavior for existing call sites.
        minimumTextHeight: Float = 0.02, // CHANGE: default preserves old behavior for existing call sites.
        cropToRegion: Bool = false // CHANGE: default false — existing preview call sites are unaffected unless they opt in.
    ) async -> String {

        // CHANGE: if asked to crop, do it up front and drop Vision's own
        // regionOfInterest entirely — the cropped buffer IS the region now,
        // so there's nothing left for Vision to filter.
        var bufferToAnalyze = pixelBuffer
        var visionROI = regionOfInterest
        if cropToRegion,
           let roi = regionOfInterest,
           let cropped = Self.cropPixelBuffer(pixelBuffer, toNormalizedRect: roi, using: ciContext) {
            bufferToAnalyze = cropped
            visionROI = nil
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

            // CHANGE: recognitionLevel now comes from the caller instead of
            // always being `.fast`.
            request.recognitionLevel = recognitionLevel
            request.recognitionLanguages = ["vi-VN", "en-US"]
            request.usesLanguageCorrection = true
            // CHANGE: minimumTextHeight now comes from the caller instead
            // of always being 0.02.
            request.minimumTextHeight = minimumTextHeight

            // CHANGE: only set Vision's regionOfInterest when we did NOT
            // already crop the buffer ourselves above.
            if let visionROI {
                request.regionOfInterest = visionROI
            }

            // Back camera in portrait orientation needs `.right` so Vision reads
            // the sensor's landscape buffer as upright text. Still correct after
            // cropping — the crop happens in the buffer's own pixel space
            // before this orientation hint is applied.
            let handler = VNImageRequestHandler(cvPixelBuffer: bufferToAnalyze, orientation: .right, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: - Cropping (CHANGE: new)

    /// Crops `pixelBuffer` to `normalizedRect` (bottom-left-origin, 0...1 —
    /// the same coordinate space Vision's regionOfInterest uses) and returns
    /// a new, smaller CVPixelBuffer containing just that region.
    private static func cropPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        toNormalizedRect normalizedRect: CGRect,
        using context: CIContext
    ) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
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