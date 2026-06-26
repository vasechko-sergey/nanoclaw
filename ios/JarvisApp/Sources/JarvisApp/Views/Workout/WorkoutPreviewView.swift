import SwiftUI
import Combine

/// Pure refresh logic for the preview: when an updated plan arrives (same
/// workoutId, e.g. after a swap), replace the displayed plan and clamp the
/// current page into the new exercise range. A different workoutId is ignored.
enum WorkoutPreviewUpdate {
    static func apply(current: WorkoutPlan, incoming: WorkoutPlan, page: Int) -> (plan: WorkoutPlan, page: Int) {
        guard incoming.workoutId == current.workoutId else { return (current, page) }
        let clampedPage = min(max(0, page), max(0, incoming.exercises.count - 1))
        return (incoming, clampedPage)
    }
}

/// Paged preview of a workout plan, shown BEFORE the live runner. Swipe between
/// exercises, see images, replace an exercise (drives the Payne swap flow), then
/// "Поехали" to start. Refreshes in place when an updated plan arrives.
struct WorkoutPreviewView: View {
    @State private var plan: WorkoutPlan
    @State private var page: Int = 0
    /// Bumped on every arrived image so the visible card re-resolves its URL —
    /// a freshly-delivered gif then replaces the stale jpg in place.
    @State private var imageRefresh = 0

    let imageResolver: (_ slug: String) -> URL?
    /// Stream of inbound plans (workoutBus `.planReceived`); used to refresh after a swap.
    let planUpdates: AnyPublisher<WorkoutPlan, Never>
    /// Stream of arrived-image slugs (workoutBus `.imageReceived`) → forces a re-resolve.
    let imageUpdates: AnyPublisher<String, Never>
    /// Fired on appear so the host prefetches this plan's images. Without it the
    /// preview never requests gifs and shows stale jpgs (only the runner pulled).
    var onAppearPrefetch: () -> Void = {}
    /// Hands the CURRENT (possibly swapped) plan to the runner — not the original.
    let onStart: (WorkoutPlan) -> Void
    let onSwap: (_ exerciseSlug: String) -> Void
    let onClose: () -> Void

    init(plan: WorkoutPlan,
         imageResolver: @escaping (_ slug: String) -> URL?,
         planUpdates: AnyPublisher<WorkoutPlan, Never>,
         imageUpdates: AnyPublisher<String, Never>,
         onAppearPrefetch: @escaping () -> Void = {},
         onStart: @escaping (WorkoutPlan) -> Void,
         onSwap: @escaping (_ exerciseSlug: String) -> Void,
         onClose: @escaping () -> Void) {
        _plan = State(initialValue: plan)
        self.imageResolver = imageResolver
        self.planUpdates = planUpdates
        self.imageUpdates = imageUpdates
        self.onAppearPrefetch = onAppearPrefetch
        self.onStart = onStart
        self.onSwap = onSwap
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            progressDots
            TabView(selection: $page) {
                ForEach(Array(plan.exercises.enumerated()), id: \.element.id) { idx, exercise in
                    ScrollView {
                        ExerciseCardView(
                            exercise: exercise,
                            imageURL: imageResolver(exercise.exerciseSlug),
                            onSwap: { onSwap(exercise.exerciseSlug) }
                        )
                        .id("\(exercise.exerciseSlug)-\(imageRefresh)")
                        .padding()
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            startBar
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onReceive(planUpdates) { incoming in
            let r = WorkoutPreviewUpdate.apply(current: plan, incoming: incoming, page: page)
            plan = r.plan
            page = r.page
        }
        .onReceive(imageUpdates) { _ in imageRefresh += 1 }
        .onAppear { onAppearPrefetch() }
        .accessibilityIdentifier("workout-preview")
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(plan.dayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("нед. \(plan.week) · \(plan.intensityLabel)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<plan.exercises.count, id: \.self) { i in
                Circle()
                    .fill(i == page ? Theme.accent : Theme.accent.opacity(0.2))
                    .frame(width: 8, height: 8)
            }
            Text("\(min(page + 1, plan.exercises.count)) из \(plan.exercises.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)
        }
        .padding(.vertical, 12)
    }

    private var startBar: some View {
        Button(action: { onStart(plan) }) {
            Text("Поехали")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(Theme.accent))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
