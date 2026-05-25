import SwiftUI

/// Empty chat state: a central orb with suggestion satellites.
/// Tap orb → triggers voice input. Tap suggestion → sends it directly.
/// Mirrors the home screen aesthetic but in-chat context.
struct EmptyStateView: View {
    var onSuggestion: (String) -> Void
    var onStartVoice: () -> Void
    var onStartText: () -> Void

    @State private var showActions = false

    private var suggestions: [String] {
        SuggestionEngine.suggestions(count: 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                // Suggestion satellites
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, text in
                    let count = suggestions.count
                    let angle = -.pi / 2 + (2 * .pi / Double(count)) * Double(index)
                    let radius = Theme.scaled(110)
                    let x = cos(angle) * radius
                    let y = sin(angle) * radius

                    EmptySatellite(icon: SuggestionEngine.icon(for: text), label: text) {
                        Theme.hapticSend()
                        SuggestionEngine.recordUsage(text)
                        onSuggestion(text)
                    }
                    .offset(x: showActions ? 0 : x, y: showActions ? 0 : y)
                    .scaleEffect(showActions ? 0.3 : 1.0)
                    .opacity(showActions ? 0 : 1.0)
                    .animation(
                        .spring(duration: 0.4, bounce: 0.25).delay(Double(index) * 0.06),
                        value: showActions
                    )
                }

                // Central orb + label
                VStack(spacing: Theme.scaled(8)) {
                    OrbView(size: Theme.scaled(100), mood: .welcoming)
                        .onTapGesture {
                            Theme.hapticSend()
                            onStartVoice()
                        }
                        .onLongPressGesture(minimumDuration: 0.3) {
                            Theme.hapticMedium()
                            onStartText()
                        }
                        .accessibilityLabel("Начать диалог")

                    Text("К вашим услугам")
                        .font(.system(size: Theme.scaled(11), weight: .light))
                        .tracking(1.5)
                        .foregroundStyle(Theme.accentMedium.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.scaled(320))

            // Keyboard shortcut hint
            HStack {
                Spacer()
                Button { onStartText() } label: {
                    HStack(spacing: Theme.scaled(4)) {
                        Image(systemName: "keyboard")
                            .font(.system(size: Theme.scaled(12)))
                        Text("или введите запрос")
                            .font(.system(size: Theme.scaled(11)))
                    }
                    .foregroundStyle(Theme.accentMedium.opacity(0.4))
                }
                .frame(minHeight: Theme.minTapSize)
                Spacer()
            }

            Spacer()
        }
    }
}

// MARK: – Empty State Satellite

private struct EmptySatellite: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.scaled(5)) {
                ZStack {
                    // Subtle glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Theme.accent.opacity(0.05), Color.clear],
                                center: .center,
                                startRadius: Theme.scaled(16),
                                endRadius: Theme.scaled(30)
                            )
                        )
                        .frame(width: Theme.scaled(50), height: Theme.scaled(50))
                    // Main circle
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Theme.surface.opacity(0.9), Theme.background.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: Theme.scaled(44), height: Theme.scaled(44))
                        .overlay(
                            Circle().stroke(Theme.accent.opacity(0.12), lineWidth: 0.5)
                        )
                    Image(systemName: icon)
                        .font(.system(size: Theme.scaled(18), weight: .light))
                        .foregroundStyle(Theme.accentMedium.opacity(0.8))
                }
                Text(label)
                    .font(.system(size: Theme.scaled(10), weight: .medium))
                    .foregroundStyle(Theme.accentMedium.opacity(0.6))
            }
        }
        .accessibilityLabel(label)
    }
}
