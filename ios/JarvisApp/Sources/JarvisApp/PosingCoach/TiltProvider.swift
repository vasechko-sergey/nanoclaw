// Sources/JarvisApp/PosingCoach/TiltProvider.swift
import CoreMotion
import Foundation

/// Publishes how far the device is rolled off level, in degrees ∈ [-45, 45].
/// Orientation-agnostic: measures deviation from the NEAREST level axis, so both
/// portrait and landscape read ~0 when the horizon is level (only true roll shows).
@MainActor
public final class TiltProvider: ObservableObject {
    @Published public private(set) var tiltDegrees: Double = 0
    private let motion = CMMotionManager()

    public func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.gravity else { return }
            // Roll around the shooting axis: 0 upright portrait, ±90 landscape.
            let roll = atan2(g.x, -g.y) * 180 / .pi
            // Fold onto the nearest quarter-turn so landscape isn't read as 90° of tilt.
            let nearestAxis = (roll / 90).rounded() * 90
            self?.tiltDegrees = roll - nearestAxis
        }
    }

    public func stop() { motion.stopDeviceMotionUpdates() }
}
