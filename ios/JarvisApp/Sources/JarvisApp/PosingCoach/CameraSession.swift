// Sources/JarvisApp/PosingCoach/CameraSession.swift
@preconcurrency import AVFoundation
import CoreVideo

/// Owns the capture session and vends latest detected Skeleton on the main actor.
@MainActor
public final class CameraSession: NSObject, ObservableObject {
    @Published public private(set) var skeleton: Skeleton?
    @Published public private(set) var permissionDenied = false
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "posing.camera")
    private var configured = false

    public func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginRunning()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.beginRunning() } else { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    private func beginRunning() {
        permissionDenied = false
        configureIfNeeded()
        let s = session
        queue.async { if !s.isRunning { s.startRunning() } }
    }

    public func stop() {
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .high
        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
        }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    public nonisolated func captureOutput(_ output: AVCaptureOutput,
                                          didOutput sampleBuffer: CMSampleBuffer,
                                          from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let detected = try? PoseDetector.detect(pixelBuffer: pb, orientation: .right)
        Task { @MainActor [weak self] in self?.skeleton = detected }
    }
}
