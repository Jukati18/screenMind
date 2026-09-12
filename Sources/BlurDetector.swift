import CoreVideo

/// CHANGE: new file — computes a lightweight "sharpness score" for a camera
/// frame using a manual grayscale downsample + Laplacian edge-energy
/// calculation (the standard "variance of Laplacian" blur metric), so the
/// app can gate OCR on "is this frame sharp enough" instead of running the
/// expensive accurate OCR pass — and possibly a Gemini call — on a frame
/// that's still in motion or out of focus.
///
/// Implemented with plain CVPixelBuffer access rather than Accelerate/vImage
/// convolution APIs on purpose: this only needs to run once per "Ask" tap
/// (plus once a second for the live preview badge), so the extra API-surface
/// risk of vImage isn't worth it for the performance it would save.
enum BlurDetector {

    /// Downsample grid size. Small on purpose — sharpness detection doesn't
    /// need full resolution, and a fixed grid keeps cost independent of the
    /// actual camera resolution (1080p vs 4K score the same way).
    private static let gridSize = 64

    /// - Returns: a Laplacian-variance sharpness score, or nil if the buffer
    ///   couldn't be read. Higher = sharper, lower = blurrier. This is a
    ///   *relative* score, not a universal constant — watch the live
    ///   "sharp: N" badge in the app (added in ContentView below) while
    ///   testing in your real conditions, and set
    ///   `MainViewModel.minimumSharpnessScore` to a value that separates
    ///   your obviously-sharp frames from your obviously-blurry ones.
    static func sharpnessScore(for pixelBuffer: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 1, height > 1 else { return nil }

        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // Step 1: downsample to a fixed-size grayscale grid via point
        // sampling (not averaging — cheap, and fine for a relative metric).
        var gray = [Double](repeating: 0, count: gridSize * gridSize)
        for gy in 0..<gridSize {
            let srcY = min(height - 1, gy * height / gridSize)
            for gx in 0..<gridSize {
                let srcX = min(width - 1, gx * width / gridSize)
                // CHANGE: our camera buffers are always 32BGRA (see
                // CameraManager's videoSettings) — byte order per pixel is
                // B, G, R, A.
                let offset = srcY * bytesPerRow + srcX * 4
                let b = Double(bytes[offset])
                let g = Double(bytes[offset + 1])
                let r = Double(bytes[offset + 2])
                gray[gy * gridSize + gx] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }

        // Step 2: discrete Laplacian on every interior grid cell — an
        // edge-energy filter that's near-zero on flat/blurred regions and
        // large-magnitude at sharp edges.
        var laplacian: [Double] = []
        laplacian.reserveCapacity((gridSize - 2) * (gridSize - 2))
        for gy in 1..<(gridSize - 1) {
            for gx in 1..<(gridSize - 1) {
                let center = gray[gy * gridSize + gx]
                let up = gray[(gy - 1) * gridSize + gx]
                let down = gray[(gy + 1) * gridSize + gx]
                let left = gray[gy * gridSize + gx - 1]
                let right = gray[gy * gridSize + gx + 1]
                laplacian.append(up + down + left + right - 4 * center)
            }
        }

        // Step 3: variance of the Laplacian response = the sharpness score.
        let mean = laplacian.reduce(0, +) / Double(laplacian.count)
        let variance = laplacian.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(laplacian.count)
        return variance
    }
}