// Sources/JarvisApp/PosingCoach/PosingCoachScreen.swift
import SwiftUI
import AVFoundation

public struct PosingCoachScreen: View {
    @StateObject private var camera = CameraSession()
    @StateObject private var tilt = TiltProvider()
    @Environment(\.dismiss) private var dismiss
    @State private var stabilizer = HintStabilizer()
    @State private var hints: [Hint] = []
    @State private var frameSize: CGSize = .zero
    @State private var zoomBase: CGFloat = 1
    @State private var focusPoint: CGPoint?
    @State private var focusVisible = false

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreviewView(session: camera.session) { devicePoint, viewPoint in
                    camera.focus(atDevicePoint: devicePoint)
                    showFocus(at: viewPoint)
                }
                .ignoresSafeArea()

                PosingOverlay(hints: hints, tiltDegrees: tilt.tiltDegrees, rollDegrees: tilt.rollDegrees)
                    .ignoresSafeArea()

                if let fp = focusPoint {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .position(fp)
                        .opacity(focusVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }

                if camera.permissionDenied { permissionOverlay }

                controls
            }
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .onChanged { scale in camera.setZoom(zoomBase * scale) }
                    .onEnded { _ in zoomBase = camera.zoomFactor }
            )
            .onAppear { frameSize = geo.size; camera.start(); tilt.start() }
            .onChange(of: geo.size) { _, newValue in frameSize = newValue }
            .onDisappear { camera.stop(); tilt.stop() }
            .onReceive(camera.$skeleton) { recompute(skeleton: $0) }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title).foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(spacing: 14) {
                        iconButton(flashIcon) { camera.cycleFlash() }
                        iconButton(camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                            camera.toggleTorch()
                        }
                    }
                    pill("\(camera.fps) fps")
                }
            }
            .padding()

            Spacer()

            VStack(spacing: 16) {
                zoomCluster
                ZStack {
                    shutterButton
                    HStack {
                        Spacer()
                        iconButton("arrow.triangle.2.circlepath.camera") { camera.switchCamera() }
                            .font(.title2)
                    }
                    .padding(.horizontal, 32)
                }
            }
            .padding(.bottom, 28)
        }
    }

    private var zoomCluster: some View {
        HStack(spacing: 6) {
            ForEach(camera.zoomPresets, id: \.self) { preset in
                let active = preset == activePreset
                Button {
                    camera.setZoom(preset)
                    zoomBase = camera.zoomFactor
                } label: {
                    Text(active ? String(format: "%.1f×", camera.zoomFactor) : zoomLabel(preset))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(active ? .yellow : .white)
                        .frame(minWidth: active ? 44 : 34, minHeight: 34)
                        .background(Circle().fill(.black.opacity(active ? 0.6 : 0.35)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Capsule().fill(.black.opacity(0.25)))
    }

    /// Preset nearest the current zoom — the one shown as active.
    private var activePreset: CGFloat? {
        camera.zoomPresets.min { abs($0 - camera.zoomFactor) < abs($1 - camera.zoomFactor) }
    }

    private func zoomLabel(_ p: CGFloat) -> String {
        p < 1 ? String(format: "%.1f", p) : String(format: "%.0f", p)
    }

    private var shutterButton: some View {
        Button { camera.capturePhoto() } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 72, height: 72)
                Circle().fill(Color.white).frame(width: 58, height: 58)
            }
        }
        .buttonStyle(.plain)
    }

    private var flashIcon: String {
        switch camera.flashMode {
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.a.fill"
        default: return "bolt.slash.fill"
        }
    }

    private func iconButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
    }

    private var permissionOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.white)
            Text("Нужен доступ к камере").font(.headline).foregroundStyle(.white)
            Text("Разреши доступ к камере в Настройках, чтобы получать подсказки по кадру.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85).ignoresSafeArea())
    }

    // MARK: - Logic

    private func showFocus(at p: CGPoint) {
        focusPoint = p
        withAnimation(.easeOut(duration: 0.15)) { focusVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeIn(duration: 0.3)) { focusVisible = false }
        }
    }

    private func recompute(skeleton: Skeleton?) {
        let frame = FrameInfo(size: frameSize, tiltDegrees: tilt.tiltDegrees)
        var raw = skeleton.map { CompositionEngine.hints(skeleton: $0, frame: frame) } ?? []
        if skeleton == nil, let t = CompositionEngine.tiltHint(frame) {
            raw.append(t)
        }
        hints = stabilizer.step(raw)
    }
}
