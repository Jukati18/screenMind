import SwiftUI
import AVFoundation

/// Thin UIViewRepresentable that hosts an AVCaptureVideoPreviewLayer.
/// No image processing happens here — it's purely the live viewfinder.
struct CameraPreviewView: UIViewRepresentable {
    // CHANGE: now takes the CameraManager itself (was just its session), so
    // this view can hand CameraManager a live reference to the preview
    // layer it creates. CameraManager needs that layer to do correct
    // point-of-interest conversion in focus(atNormalizedPoint:) — see the
    // fix in CameraManager.swift for why the old manual math was wrong.
    let cameraManager: CameraManager

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = cameraManager.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        cameraManager.previewLayer = view.videoPreviewLayer // CHANGE: expose the layer for focus conversion.
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Nothing to update; the session reference doesn't change after creation.
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}