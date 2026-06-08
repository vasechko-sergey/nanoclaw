import SwiftUI

/// Server's response to a swap request, surfaced to the sheet via @Binding.
/// nil — no response yet (loading / initial state).
struct SwapResponse: Equatable {
    /// Server accepted user's proposed exercise. Sheet shows confirm CTA.
    var accepted: AcceptedSlug?
    /// Server rejected user's proposed exercise. Sheet shows reason + alternatives.
    var rejected: RejectedSlug?
    /// 2-3 alternative slugs server suggests (always present when responding).
    var alternatives: [Alternative]

    struct AcceptedSlug: Equatable {
        let slug: String
    }

    struct RejectedSlug: Equatable {
        let slug: String
        let reason: String
    }

    struct Alternative: Equatable, Identifiable {
        let slug: String
        let why: String
        var id: String { slug }
    }
}

/// Action the sheet asks the parent to perform over WS.
enum SwapAction {
    /// User asked Payne to suggest — parent sends `exercise_swap_request` with no `proposed`.
    case requestSuggestions
    /// User submitted their own choice — parent sends with `proposed: text`.
    case proposeOwn(text: String)
    /// User confirmed a slug — parent sends `exercise_swap_confirm`.
    case confirm(newSlug: String, persist: Bool)
    /// User dismissed.
    case cancel
}

struct SwapSheet: View {
    let originalSlug: String
    /// Server response, driven by parent (set when `exercise_swap_options` arrives).
    @Binding var response: SwapResponse?
    /// Whether a request is in flight (parent toggles around send + ack).
    @Binding var loading: Bool
    /// Sheet hands actions out; parent does WS send.
    let onAction: (SwapAction) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var proposed: String = ""
    @State private var persist: Bool = false
    @State private var selectedSlug: String? = nil

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Замена упражнения")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена") {
                            onAction(.cancel)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("swap-sheet")
    }

    @ViewBuilder
    private var content: some View {
        Form {
            Section {
                LabeledContent("Заменяем") {
                    Text(originalSlug)
                        .foregroundStyle(.secondary)
                }
                Toggle("Оставить в программе", isOn: $persist)
            }

            Section("Свой вариант") {
                TextField("например, жим гантелей сидя", text: $proposed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.send)
                    .onSubmit { sendProposed() }
                Button {
                    sendProposed()
                } label: {
                    HStack {
                        Text("Проверить")
                        if loading { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(proposed.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                .frame(minHeight: 44)
            }

            Section("Или попроси Пейна") {
                Button {
                    onAction(.requestSuggestions)
                } label: {
                    HStack {
                        Text("Предложи варианты")
                        if loading { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(loading)
                .frame(minHeight: 44)
            }

            if let resp = response {
                serverResponseSection(resp)
            }
        }
    }

    @ViewBuilder
    private func serverResponseSection(_ resp: SwapResponse) -> some View {
        if let accepted = resp.accepted {
            Section("Подходит") {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(accepted.slug)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Заменить") {
                        confirm(newSlug: accepted.slug)
                    }
                    .frame(minHeight: 44)
                }
            }
        }

        if let rejected = resp.rejected {
            Section("Не подойдёт") {
                Label(rejected.slug, systemImage: "xmark.circle")
                    .foregroundStyle(.red.opacity(0.8))
                Text(rejected.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if !resp.alternatives.isEmpty {
            Section("Альтернативы") {
                ForEach(resp.alternatives) { alt in
                    alternativeRow(alt)
                }
            }
        }
    }

    @ViewBuilder
    private func alternativeRow(_ alt: SwapResponse.Alternative) -> some View {
        Button {
            selectedSlug = alt.slug
            confirm(newSlug: alt.slug)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(alt.slug)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if selectedSlug == alt.slug {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(alt.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 56)
    }

    // MARK: - Actions

    private func sendProposed() {
        let text = proposed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onAction(.proposeOwn(text: text))
    }

    private func confirm(newSlug: String) {
        onAction(.confirm(newSlug: newSlug, persist: persist))
        dismiss()
    }
}
