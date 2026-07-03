// Sources/JarvisApp/PosingCoach/TiltProvider.swift
import CoreMotion
import Foundation

/// Publishes device roll (degrees from horizontal) for the tilt composition rule.
@MainActor
public final class TiltProvider: ObservableObject {
    @Published public private(set) var tiltDegrees: Double = 0
    private let motion = CMMotionManager()

    public func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.gravity else { return }
            // Roll around the vertical shooting axis: 0 when upright portrait.
            self?.tiltDegrees = atan2(g.x, -g.y) * 180 / .pi
        }
    }

    public func stop() { motion.stopDeviceMotionUpdates() }
}
