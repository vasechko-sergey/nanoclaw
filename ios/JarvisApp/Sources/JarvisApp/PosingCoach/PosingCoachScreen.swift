// Sources/JarvisApp/PosingCoach/PosingCoachScreen.swift
import SwiftUI

public struct PosingCoachScreen: View {
    @StateObject private var camera = CameraSession()
    @StateObject private var tilt = TiltProvider()
    @Environment(\.dismiss) private var dismiss
    private let stabilizer = HintStabilizer()
    @State private var hints: [Hint] = []

    public init() {}

    public var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session).ignoresSafeArea()
            PosingOverlay(hints: hints).ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title).foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
        .onAppear { camera.start(); tilt.start() }
        .onDisappear { camera.stop(); tilt.stop() }
        .onReceive(camera.$skeleton) { recompute(skeleton: $0) }
        .onReceive(tilt.$tiltDegrees) { _ in recompute(skeleton: camera.skeleton) }
    }

    private func recompute(skeleton: Skeleton?) {
        let frame = FrameInfo(size: UIScreen.main.bounds.size, tiltDegrees: tilt.tiltDegrees)
        let raw = skeleton.map { CompositionEngine.hints(skeleton: $0, frame: frame) } ?? []
        hints = stabilizer.step(raw)
    }
}
