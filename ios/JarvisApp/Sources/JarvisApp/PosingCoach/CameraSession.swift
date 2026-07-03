// Sources/JarvisApp/PosingCoach/CameraSession.swift
@preconcurrency import AVFoundation
import CoreVideo
import QuartzCore
import Photos

/// Owns the capture session: live pose detection + standard camera controls
/// (zoom, front/back, tap focus/exposure, flash/torch, shutter → Photos).
@MainActor
public final class CameraSession: NSObject, ObservableObject {
    @Published public private(set) var skeleton: Skeleton?
    @Published public private(set) var permissionDenied = false
    /// Vision body-pose throughput (frames/sec), measured on the capture queue.
    @Published public private(set) var fps: Int = 0
    /// Current DISPLAY zoom factor (1.0 = wide lens, 0.5 = ultra-wide), like the stock camera.
    @Published public private(set) var zoomFactor: CGFloat = 1
    /// Tappable zoom presets available on the active camera (e.g. [0.5, 1, 2, 3]).
    @Published public private(set) var zoomPresets: [CGFloat] = [1]
    /// Active camera position.
    @Published public private(set) var position: AVCaptureDevice.Position = .back
    /// Photo flash mode (off/auto/on) applied at capture.
    @Published public private(set) var flashMode: AVCaptureDevice.FlashMode = .off
    /// Continuous torch state.
    @Published public private(set) var torchOn = false
    /// Set when a capture couldn't be saved (e.g. no Photos access).
    @Published public var captureError: String?

    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "posing.camera")
    private var configured = false
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    /// videoZoomFactor of the wide (1×) lens on the active device (>1 when an ultra-wide exists).
    private var baselineZoom: CGFloat = 1
    /// Display-zoom ceiling exposed to pinch/presets.
    private let maxUserZoom: CGFloat = 8

    // Touched only from the serial capture queue in captureOutput — single-threaded there.
    private nonisolated(unsafe) var frameCount = 0
    private nonisolated(unsafe) var windowStart = CACurrentMediaTime()
    // Read on capture queue, written on main during switchCamera — benign single-frame skew.
    private nonisolated(unsafe) var detectOrientation: CGImagePropertyOrientation = .right

    // MARK: - Session lifecycle

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
        if torchOn { setTorch(false) }
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .high
        addVideoInput(position: .back)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
    }

    private func addVideoInput(position newPosition: AVCaptureDevice.Position) {
        guard let dev = bestDevice(position: newPosition),
              let input = try? AVCaptureDeviceInput(device: dev) else { return }
        if let existing = videoInput { session.removeInput(existing) }
        guard session.canAddInput(input) else {
            if let existing = videoInput { session.addInput(existing) }  // restore
            return
        }
        session.addInput(input)
        videoInput = input
        device = dev
        position = newPosition
        detectOrientation = (newPosition == .front) ? .leftMirrored : .right
        configureZoom(for: dev)
    }

    /// Pick the richest multi-lens virtual device for the back so presets get real optical zoom.
    private func bestDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            let types: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
            ]
            for t in types {
                if let d = AVCaptureDevice.default(t, for: .video, position: .back) { return d }
            }
            return nil
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Compute the wide-lens baseline + available presets, then reset to 1×.
    private func configureZoom(for dev: AVCaptureDevice) {
        let switchOvers = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = dev.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        baselineZoom = hasUltraWide ? (switchOvers.first ?? 1) : 1

        let maxDisplay = min(dev.maxAvailableVideoZoomFactor / baselineZoom, maxUserZoom)
        var presets: [CGFloat] = []
        if hasUltraWide { presets.append(0.5) }
        presets.append(1)
        if maxDisplay >= 2 { presets.append(2) }
        if maxDisplay >= 3 { presets.append(3) }
        zoomPresets = presets
        setZoom(1)
    }

    // MARK: - Controls

    /// Set zoom by DISPLAY factor (1.0 = wide, 0.5 = ultra-wide), clamped to the device range.
    public func setZoom(_ displayFactor: CGFloat) {
        guard let device else { return }
        let target = displayFactor * baselineZoom
        let lo = device.minAvailableVideoZoomFactor
        let hi = min(device.maxAvailableVideoZoomFactor, maxUserZoom * baselineZoom)
        let clamped = max(lo, min(target, hi))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            zoomFactor = clamped / baselineZoom
        } catch { /* zoom is non-critical */ }
    }

    public func switchCamera() {
        guard configured else { return }
        if torchOn { setTorch(false) }
        session.beginConfiguration()
        addVideoInput(position: position == .back ? .front : .back)
        session.commitConfiguration()
    }

    /// Focus + expose at a device point (normalized, from previewLayer conversion).
    public func focus(atDevicePoint p: CGPoint) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = p
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = p
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        } catch { /* ignore transient lock failure */ }
    }

    /// Cycle photo flash off → auto → on.
    public func cycleFlash() {
        switch flashMode {
        case .off: flashMode = .auto
        case .auto: flashMode = .on
        default: flashMode = .off
        }
    }

    public func toggleTorch() { setTorch(!torchOn) }

    private func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            torchOn = on
        } catch { /* ignore */ }
    }

    // MARK: - Capture

    public func capturePhoto() {
        ensurePhotoAccess { [weak self] granted in
            guard let self else { return }
            guard granted else { self.captureError = "Нет доступа к Фото"; return }
            let settings = AVCapturePhotoSettings()
            if self.photoOutput.supportedFlashModes.contains(self.flashMode) {
                settings.flashMode = self.flashMode
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func ensurePhotoAccess(_ done: @escaping (Bool) -> Void) {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            done(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                Task { @MainActor in done(status == .authorized || status == .limited) }
            }
        default:
            done(false)
        }
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    public nonisolated func captureOutput(_ output: AVCaptureOutput,
                                          didOutput sampleBuffer: CMSampleBuffer,
                                          from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let detected = try? PoseDetector.detect(pixelBuffer: pb, orientation: detectOrientation)
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

extension CameraSession: AVCapturePhotoCaptureDelegate {
    public nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                        didFinishProcessingPhoto photo: AVCapturePhoto,
                                        error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
        } completionHandler: { _, _ in /* best-effort save */ }
    }
}
