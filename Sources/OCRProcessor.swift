import Vision
import CoreVideo
import UIKit

/// Wraps VNRecognizeTextRequest. Stateless and cheap to call repeatedly —
/// the throttling/frequency control lives in the view model, not here.
final class OCRProcessor {

    /// Runs OCR on a single pixel buffer.
    /// - Parameters:
    ///   - pixelBuffer: raw camera frame (BGRA).
    ///   - regionOfInterest: optional crop in Vision's normalized, bottom-left-origin
    ///     coordinate space (0...1). Pass nil to scan the full frame.
    func recognizeText(in pixelBuffer: CVPixelBuffer, regionOfInterest: CGRect? = nil) async -> String {
        await withCheckedContinuation { continuation in
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

            // .fast is required by spec — good enough for change-detection and
            // still cheap on-device; final answer quality is recovered by
            // asking Gemini to reconstruct noisy OCR (see GeminiService).
            request.recognitionLevel = .fast
            request.recognitionLanguages = ["vi-VN", "en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.02

            if let roi = regionOfInterest {
                request.regionOfInterest = roi
            }

            // Back camera in portrait orientation needs `.right` so Vision reads
            // the sensor's landscape buffer as upright text.
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
