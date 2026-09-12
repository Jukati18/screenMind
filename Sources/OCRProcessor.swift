import Vision
import CoreVideo
import CoreImage
import UIKit

// CHANGE: new — recognizeText now returns both the reconstructed text and
// Vision's own average confidence across all recognized lines, so callers
// can decide whether a scan is reliable enough to act on instead of
// silently trusting whatever Vision returned.
struct OCRResult {
    let text: String
    let averageConfidence: Float
}

/// Wraps VNRecognizeTextRequest. Stateless and cheap to call repeatedly —
/// the throttling/frequency control lives in the view model, not here.
final class OCRProcessor {

    private let ciContext = CIContext()

    /// Runs OCR on a single pixel buffer.
    /// - Returns: an OCRResult with the joined text and Vision's average
    ///   per-line confidence. CHANGE: was previously a bare String.
    func recognizeText(
        in pixelBuffer: CVPixelBuffer,
        regionOfInterest: CGRect? = nil,
        recognitionLevel: VNRequestTextRecognitionLevel = .fast,
        minimumTextHeight: Float = 0.02,
        cropToRegion: Bool = false
    ) async -> OCRResult {

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
                    // CHANGE: matches new OCRResult return type.
                    continuation.resume(returning: OCRResult(text: "", averageConfidence: 0))
                    return
                }
                // CHANGE: collect each line's top-candidate string AND its
                // confidence, so an overall average can be reported
                // alongside the joined text.
                var lines: [String] = []
                var confidences: [Float] = []
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    lines.append(candidate.string)
                    confidences.append(candidate.confidence)
                }
                let text = lines.joined(separator: "\n")
                let averageConfidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Float(confidences.count)
                continuation.resume(returning: OCRResult(text: text, averageConfidence: averageConfidence))
            }

            request.recognitionLevel = recognitionLevel
            request.recognitionLanguages = ["vi-VN", "en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = minimumTextHeight

            if let visionROI {
                request.regionOfInterest = visionROI
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: bufferToAnalyze, orientation: .right, options: [:])
            do {
                try handler.perform([request])
            } catch {
                // CHANGE: matches new OCRResult return type.
                continuation.resume(returning: OCRResult(text: "", averageConfidence: 0))
            }
        }
    }

    // MARK: - Cropping

    private static func cropPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        toNormalizedRect normalizedRect: CGRect,
        using context: CIContext
    ) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent

        let pixelRect = CGRect(
            x: normalizedRect.minX * extent.width,
            y: normalizedRect.minY * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        ).integral

        guard pixelRect.width > 0, pixelRect.height > 0 else { return nil }

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