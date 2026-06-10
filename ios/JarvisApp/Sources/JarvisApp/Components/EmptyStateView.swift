import SwiftUI

/// Empty-chat placeholder shown by `ChatView` when the active conversation has no messages.
/// Mirrors `OrbHomeView`'s central hub: a large orb surrounded by suggestion satellites.
/// The chat InputBar lives below this view, so no separate "Голосом"/"Текстом" pills are needed.
struct EmptyStateView: View {
    var onSuggestion: (String) -> Void
    var onStartVoice: () -> Void

    @State private var suggestions: [String] = SuggestionEngine.suggestions(count: 4)

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Доброе утро"
        case 12..<17: return "Добрый день"
        case 17..<22: return "Добрый вечер"
        default:      return "Доброй ночи"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            orbCluster

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Orb cluster

    private var orbCluster: some View {
        ZStack {
            // Suggestion satellites — laid out around the central orb the same way
            // OrbHomeView does it, just without the long-press action toggle.
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, text in
                let count = suggestions.count
                let angle = -.pi / 2 + (2 * .pi / Double(count)) * Double(index)
                let radius = Theme.scaled(130)
                let x = cos(angle) * radius
                let y = sin(angle) * radius

                EmptyStateSatelliteOrb(
                    icon: SuggestionEngine.icon(for: text),
                    label: text
                ) {
                    Theme.hapticSend()
                    SuggestionEngine.recordUsage(text)
                    onSuggestion(text)
                }
                .offset(x: x, y: y)
            }

            // Central orb + greeting
            VStack(spacing: Theme.scaled(8)) {
                OrbView(size: Theme.orbSize, mood: .welcoming)
                    .onTapGesture {
                        Theme.hapticSend()
                        onStartVoice()
                    }
                    .accessibilityLabel("Начать диалог голосом")
                    .accessibilityIdentifier("empty-state-orb")

                Text(greeting)
                    .font(.system(size: Theme.scaled(11), weight: .light))
                    .tracking(2)
                    .foregroundStyle(Theme.accentMedium.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        // maxHeight (not a rigid height) so the cluster can compress when the
        // software keyboard shrinks the available vertical space. With a rigid
        // height the column overflowed and pushed the chat input bar partially
        // under the keyboard in the empty state. The surrounding Spacers still
        // center the orb when there's room, so the no-keyboard look is unchanged.
        .frame(maxHeight: Theme.scaled(360))
    }
}

// MARK: – Satellite orb (mirrors OrbHomeView's private HomeSatelliteOrb)

private struct EmptyStateSatelliteOrb: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.scaled(6)) {
                ZStack {
                    // Outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Theme.accent.opacity(0.06),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: Theme.scaled(20),
                                endRadius: Theme.scaled(36)
                            )
                        )
                        .frame(width: Theme.scaled(60), height: Theme.scaled(60))

                    // Main circle
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Theme.surface.opacity(0.9),
                                    Theme.background.opacity(0.7)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: Theme.scaled(50), height: Theme.scaled(50))
                        .overlay(
                            Circle().stroke(
                                Theme.accent.opacity(0.15),
                                lineWidth: Theme.lineHairline
                            )
                        )
                    Image(systemName: icon)
                        .font(.system(size: Theme.scaled(20), weight: .light))
                        .foregroundStyle(Theme.accentMedium.opacity(0.8))
                }
                Text(label)
                    .font(.system(size: Theme.scaled(10), weight: .medium))
                    .foregroundStyle(Theme.accentMedium.opacity(0.7))
            }
        }
        .accessibilityLabel(label)
    }
}
