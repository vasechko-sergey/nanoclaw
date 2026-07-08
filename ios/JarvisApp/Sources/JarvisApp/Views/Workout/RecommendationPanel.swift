import SwiftUI

/// The ⅓-screen panel under the image showing Payne's recommendation for the
/// (previewed) exercise. Chips come from the plan — nothing computed here.
/// Plain language, no abbreviations (house style).
///
/// A second row carries Payne's latest *coach line* (a `coach_message` without a
/// `set_ref` — abort ack, tempo hint, warmup nudge). It sits inside the same
/// panel, truncated to two lines; tapping opens the full text. The line persists
/// until the next coach message replaces it (`coachHint == nil` → row hidden).
struct RecommendationPanel: View {
    let exercise: ExercisePlan
    var coachHint: String? = nil

    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)
    @State private var showCoachDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chipsRow
            if let hint = coachHint, !hint.isEmpty {
                coachRow(hint)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.08, green: 0.078, blue: 0.06))
        .overlay(alignment: .top) { Rectangle().fill(copper.opacity(0.35)).frame(height: 1) }
        .sheet(isPresented: $showCoachDetail) {
            CoachHintDetailView(text: coachHint ?? "")
        }
    }

    private var chipsRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(copper)
            Text("ПЕЙН").font(.caption2).foregroundStyle(copper)
            if let w = exercise.weightKgTarget { chip("\(WorkoutSetFormat.weight(w)) кг") }
            if exercise.targetSets > 0 { chip("\(exercise.targetSets)×\(exercise.targetReps)") }
            chip("запас \(exercise.targetRir)")
            if exercise.restSec > 0 { chip(restLabel(exercise.restSec)) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Coach line. Whole row taps through to the full text; the native tail "…"
    /// on a long message is the "there's more" cue, so no extra chevron.
    private func coachRow(_ hint: String) -> some View {
        Button { showCoachDetail = true } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 11)).foregroundStyle(copper)
                    .padding(.top, 1)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(copper.opacity(0.10))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(copper.opacity(0.18)).frame(height: 1) }
        .accessibilityIdentifier("coach-hint-row")
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
    }

    private func restLabel(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}

/// Full-text sheet for a Payne coach line, opened by tapping the truncated row.
struct CoachHintDetailView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill").foregroundStyle(copper)
                Text("Пейн").font(.headline).foregroundStyle(copper)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundStyle(.white.opacity(0.4))
                }
                .accessibilityLabel("Закрыть")
            }
            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("coach-hint-detail")
    }
}
