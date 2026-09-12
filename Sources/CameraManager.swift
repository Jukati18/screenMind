import AVFoundation
import CoreVideo
import UIKit

protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutput pixelBuffer: CVPixelBuffer)
}

final class CameraManager: NSObject, ObservableObject {

    @Published var isAuthorized = false
    @Published var permissionDenied = false

    let session = AVCaptureSession()

    // CHANGE: weak reference to the actual preview layer, set by
    // CameraPreviewView once it creates one. Used by focus(atNormalizedPoint:)
    // to convert on-screen points into device focus coordinates via
    // AVFoundation's own captureDevicePointConverted(fromLayerPoint:) —
    // this replaces the hand-rolled coordinate formula that was getting the
    // mapping wrong and locking focus on the wrong part of the scene.
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let videoQueue = DispatchQueue(label: "camera.video.queue", qos: .userInitiated)
    private var currentDevice: AVCaptureDevice?

    weak var delegate: CameraManagerDelegate?

    var isAdjustingFocus: Bool {
        currentDevice?.isAdjustingFocus ?? false
    }

    // MARK: - Permissions 

    func checkPermissionsAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isAuthorized = granted
                    self?.permissionDenied = !granted
                }
                if granted { self?.configureSession() }
            }
        case .denied, .restricted:
            isAuthorized = false
            permissionDenied = true
        @unknown default:
            isAuthorized = false
            permissionDenied = true
        }
    }

    // MARK: - Session configuration 

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            } else if self.session.canSetSessionPreset(.hd1280x720) {
                self.session.sessionPreset = .hd1280x720
            }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                return
            }
            self.currentDevice = device

            if self.session.canAddInput(input) {
                self.session.addInput(input)
            }

            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            if let connection = self.videoOutput.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }

            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Focus (CHANGE: rewritten — fixes the regression)

    /// Continuously focuses/exposes around a specific on-screen point.
    ///
    /// FIX: the previous version (a) computed the device-space point with a
    /// hand-written formula guessing at the sensor/orientation mapping, and
    /// (b) used `.autoFocus` — a ONE-SHOT mode that adjusts focus once and
    /// then freezes, so a wrong point (or the phone moving afterward) left
    /// the camera permanently out of focus. That combination is what made
    /// scanning noticeably worse than plain continuous autofocus.
    ///
    /// This version instead:
    /// 1. Uses `AVCaptureVideoPreviewLayer.captureDevicePointConverted` —
    ///    Apple's own orientation-aware conversion — instead of manual math.
    /// 2. Uses `.continuousAutoFocus` with a focus *point of interest* set,
    ///    so the camera keeps re-adjusting around that point as distance or
    ///    lighting changes, the way tap-to-focus works in Apple's own
    ///    Camera app.
    ///
    /// - Parameter normalizedPoint: a point in the SAME coordinate space
    ///   ContentView already uses for `regionOfInterest`: 0...1, x
    ///   increasing right, y increasing down, origin at the preview's
    ///   top-left.
    func focus(atNormalizedPoint normalizedPoint: CGPoint) {
        // CHANGE: captureDevicePointConverted touches the UIKit layer, so
        // it must run on the main thread — then hop to sessionQueue for the
        // actual device configuration.
        guard let previewLayer, previewLayer.bounds.width > 0, previewLayer.bounds.height > 0 else { return }

        let layerPoint = CGPoint(
            x: normalizedPoint.x * previewLayer.bounds.width,
            y: normalizedPoint.y * previewLayer.bounds.height
        )
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)

        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                // CHANGE: continuousAutoFocus (not one-shot autoFocus) so
                // the camera keeps adjusting around this point instead of
                // freezing after a single pass.
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                // Best-effort — if this fails, whatever focus mode was
                // already active just keeps running.
            }
        }
    }

    // MARK: - Lifecycle

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                        didOutput sampleBuffer: CMSampleBuffer,
                        from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        delegate?.cameraManager(self, didOutput: pixelBuffer)
    }
}