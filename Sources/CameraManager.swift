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

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let videoQueue = DispatchQueue(label: "camera.video.queue", qos: .userInitiated)
    private var currentDevice: AVCaptureDevice?

    weak var delegate: CameraManagerDelegate?

    // CHANGE: exposes whether the camera is still adjusting focus, so the
    // view model could factor this into its blur-retry loop if desired.
    // Reading AVCaptureDevice properties from any thread is safe per
    // Apple's docs — only *changes* need lockForConfiguration.
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

    // MARK: - Focus (CHANGE: new)

    /// Locks focus (and exposure) on a specific point instead of relying
    /// purely on continuous autofocus, which can keep "hunting" and never
    /// settle sharply on close-up text like a worksheet or screen.
    /// - Parameter point: normalized 0...1 in AVFoundation's device
    ///   coordinate space — NOT the same convention as Vision's
    ///   regionOfInterest. See MainViewModel.focusCameraOnROI for the
    ///   conversion from our on-screen ROI to this coordinate space.
    func focus(on point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                // CHANGE: focus lock is a best-effort enhancement — if it
                // fails, just keep whatever focus mode was already active
                // rather than surfacing an error to the user.
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