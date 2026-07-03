// Sources/JarvisApp/PosingCoach/PosingCoachScreen.swift
import SwiftUI

public struct PosingCoachScreen: View {
    @StateObject private var camera = CameraSession()
    @StateObject private var tilt = TiltProvider()
    @Environment(\.dismiss) private var dismiss
    @State private var stabilizer = HintStabilizer()
    @State private var hints: [Hint] = []
    @State private var frameSize: CGSize = .zero

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreviewView(session: camera.session).ignoresSafeArea()
                PosingOverlay(hints: hints).ignoresSafeArea()
                if camera.permissionDenied { permissionOverlay }
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title).foregroundStyle(.white.opacity(0.9))
                        }
                        Spacer()
                        Text("\(camera.fps) fps")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                    .padding()
                    Spacer()
                }
            }
            .onAppear { frameSize = geo.size; camera.start(); tilt.start() }
            .onChange(of: geo.size) { _, newValue in frameSize = newValue }
            .onDisappear { camera.stop(); tilt.stop() }
            .onReceive(camera.$skeleton) { recompute(skeleton: $0) }
        }
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

    private func recompute(skeleton: Skeleton?) {
        let frame = FrameInfo(size: frameSize, tiltDegrees: tilt.tiltDegrees)
        var raw = skeleton.map { CompositionEngine.hints(skeleton: $0, frame: frame) } ?? []
        if skeleton == nil, let t = CompositionEngine.tiltHint(frame) {
            raw.append(t)
        }
        hints = stabilizer.step(raw)
    }
}
