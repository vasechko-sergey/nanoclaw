// Sources/JarvisApp/PosingCoach/TiltProvider.swift
import CoreMotion
import Foundation

/// Publishes device roll for the horizon indicator, smoothed to kill jitter.
/// - `rollDegrees`: raw portrait-relative roll ∈ (-180, 180] — how the true horizon
///   is oriented in the (portrait-locked) UI, used to rotate the level line.
/// - `tiltDegrees`: deviation from the nearest level axis ∈ [-45, 45] — how far off
///   level, orientation-agnostic, used for the "is it level" check + text hint.
@MainActor
public final class TiltProvider: ObservableObject {
    @Published public private(set) var rollDegrees: Double = 0
    @Published public private(set) var tiltDegrees: Double = 0
    @Published public private(set) var pitchDegrees: Double = 0
    private let motion = CMMotionManager()
    private var smoothedRoll: Double = 0
    private var seeded = false
    /// Low-pass factor per sample (30 Hz). Lower = smoother but laggier.
    private let smoothing = 0.15

    public func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            let roll = atan2(g.x, -g.y) * 180 / .pi   // 0 upright portrait, ±90 landscape
            if !self.seeded { self.smoothedRoll = roll; self.seeded = true }
            // Angle-aware EMA: unwrap the shortest delta so ±180 wraparound doesn't glitch.
            var delta = roll - self.smoothedRoll
            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
            self.smoothedRoll += self.smoothing * delta
            let nearestAxis = (self.smoothedRoll / 90).rounded() * 90
            self.rollDegrees = self.smoothedRoll
            self.tiltDegrees = self.smoothedRoll - nearestAxis
            // Optical-axis pitch: ~0 upright portrait (level), positive when tilted down.
            self.pitchDegrees = -asin(max(-1, min(1, g.z))) * 180 / .pi
        }
    }

    public func stop() { motion.stopDeviceMotionUpdates() }
}
