import SwiftUI

/// Collapsed technique row under the runner's header: «Техника · 3 шага».
/// Tapping it opens `TechniqueText` over the image and the ПЕЙН panel.
struct TechniqueRow: View {
    let technique: ExerciseTechnique
    @Binding var expanded: Bool

    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)

    static func label(steps: Int) -> String {
        guard steps > 0 else { return "Техника" }
        let mod10 = steps % 10, mod100 = steps % 100
        let word = (mod10 == 1 && mod100 != 11) ? "шаг"
            : ((2...4).contains(mod10) && !(12...14).contains(mod100)) ? "шага" : "шагов"
        return "Техника · \(steps) \(word)"
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "book").font(.system(size: 12)).foregroundStyle(copper)
                Text(Self.label(steps: technique.steps.count)).font(.caption).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.08, green: 0.078, blue: 0.06))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("technique-row")
    }
}

/// The expanded technique: numbered steps (title in copper), then warnings.
/// Lives in an overlay over the image + panel, so the set card keeps its place;
/// scrolls when longer than that area.
struct TechniqueText: View {
    let technique: ExerciseTechnique

    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)

    /// The copper prefix of a step: «1. Title. », «1. Title: » (the card's own
    /// closing punctuation stays as it is), «1. » for an empty title. The
    /// trailing space separates it from the step text.
    static func stepLine(index: Int, title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "\(index). " }
        let closed = [".", ":", "!", "?"].contains { t.hasSuffix($0) }
        return "\(index). \(t)\(closed ? "" : ".") "
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(technique.steps.enumerated()), id: \.offset) { i, step in
                    (Text(Self.stepLine(index: i + 1, title: step.title)).foregroundColor(copper).bold()
                     + Text(step.text).foregroundColor(.white.opacity(0.92)))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(technique.warnings.enumerated()), id: \.offset) { _, w in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.94, green: 0.62, blue: 0.15))
                            .padding(.top, 2)
                        Text(w).font(.footnote).foregroundStyle(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(red: 0.08, green: 0.078, blue: 0.06))
        .accessibilityIdentifier("technique-text")
    }
}
