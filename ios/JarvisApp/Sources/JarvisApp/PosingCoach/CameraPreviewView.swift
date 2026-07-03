// Sources/JarvisApp/PosingCoach/CameraPreviewView.swift
import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Called on tap: (device point for focus POI, view-space point for the UI indicator).
    var onTapToFocus: ((CGPoint, CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.onTapToFocus = onTapToFocus
        let tap = UITapGestureRecognizer(target: v, action: #selector(PreviewUIView.handleTap(_:)))
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.onTapToFocus = onTapToFocus
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTapToFocus: ((CGPoint, CGPoint) -> Void)?

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            let viewPoint = g.location(in: self)
            let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
            onTapToFocus?(devicePoint, viewPoint)
        }
    }
}
