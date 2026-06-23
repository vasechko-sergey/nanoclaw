import Foundation
import Combine

/// Events derived from inbound v2 workout envelopes. UI layers (WorkoutView,
/// SwapSheet, ChatView) subscribe to relevant cases via the shared subject
/// on AppCoordinator.
///
/// Wired by `TransportV2.handleIncoming` (workout-typed branches) →
/// `AppCoordinator.workoutBus.events.send(...)` → SwiftUI `.onReceive`.
enum WorkoutInboundEvent {
    case planReceived(WorkoutPlan)
    case coachMessage(text: String, workoutId: String?)
    case swapOptions(SwapResponse, originalSlug: String, workoutId: String)
    case imageReceived(slug: String)  // an image_blob landed → refresh thumbnails
    case programUpdated  // raw JSON not surfaced today — logged only
}

/// MainActor-bound publisher hub. Owns a `PassthroughSubject` so subscribers
/// can compose Combine + SwiftUI `.onReceive` without going through
/// NotificationCenter.
@MainActor
final class WorkoutInboundBus {
    let events = PassthroughSubject<WorkoutInboundEvent, Never>()
}
