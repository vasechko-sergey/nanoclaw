// Sources/JarvisApp/PosingCoach/CameraSession.swift
@preconcurrency import AVFoundation
import CoreVideo
import QuartzCore

/// Owns the capture session and vends latest detected Skeleton on the main actor.
@MainActor
public final class CameraSession: NSObject, ObservableObject {
    @Published public private(set) var skeleton: Skeleton?
    @Published public private(set) var permissionDenied = false
    /// Vision body-pose throughput (frames processed per second). Measured on the
    /// capture queue where `detect` actually runs, so it reflects the real pipeline rate.
    @Published public private(set) var fps: Int = 0
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "posing.camera")
    private var configured = false

    // Touched only from the serial capture queue in captureOutput — single-threaded there.
    private nonisolated(unsafe) var frameCount = 0
    private nonisolated(unsafe) var windowStart = CACurrentMediaTime()

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
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - windowStart
        if elapsed >= 1 {
            let measured = Int((Double(frameCount) / elapsed).rounded())
            frameCount = 0
            windowStart = now
            Task { @MainActor [weak self] in self?.fps = measured }
        }
        Task { @MainActor [weak self] in self?.skeleton = detected }
    }
}
