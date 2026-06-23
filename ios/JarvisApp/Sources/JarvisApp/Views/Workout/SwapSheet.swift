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

/// Dark, visualized swap sheet: the current exercise + each alternative shown as
/// an image card (thumbnail + name + why). Themed to the app background.
struct SwapSheet: View {
    let originalSlug: String
    /// Russian display name of the exercise being replaced (for the header).
    var currentName: String = ""
    /// slug → cached thumbnail URL (manifest for the current exercise, latest
    /// blob for alternatives). nil → placeholder.
    var thumbnail: (_ slug: String) -> URL? = { _ in nil }
    /// Bumped by the parent when an image_blob lands, to re-resolve thumbnails.
    var refreshToken: Int = 0

    @Binding var response: SwapResponse?
    @Binding var loading: Bool
    let onAction: (SwapAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var proposed: String = ""
    @State private var persist: Bool = false
    @State private var selectedSlug: String? = nil

    var body: some View {
        let _ = refreshToken  // re-resolve thumbnails when a blob lands
        return ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    currentCard
                    ownVariant
                    if let resp = response { alternativesBlock(resp) } else { suggestButton }
                }
                .padding(16)
            }
            if let slug = selectedSlug {
                confirmBar(slug)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .accessibilityIdentifier("swap-sheet")
    }

    private var header: some View {
        HStack {
            Button("Отмена") { onAction(.cancel); dismiss() }
                .foregroundStyle(Theme.accent)
            Spacer()
            Text("Замена упражнения").font(.headline).foregroundStyle(Theme.textPrimary)
            Spacer()
            Color.clear.frame(width: 52)
        }
    }

    private var currentCard: some View {
        HStack(spacing: 10) {
            thumb(originalSlug, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("меняем").font(.caption2).foregroundStyle(.white.opacity(0.4))
                Text(currentName.isEmpty ? prettify(originalSlug) : currentName)
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
            }
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private var ownVariant: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("свой вариант…", text: $proposed)
                    .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                    .submitLabel(.send).onSubmit { sendProposed() }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                    .foregroundStyle(Theme.textPrimary)
                Button { sendProposed() } label: {
                    if loading { ProgressView().controlSize(.small) } else { Text("Проверить").foregroundStyle(Theme.accent) }
                }
                .disabled(proposed.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                .frame(minHeight: 44)
            }
            Toggle("Оставить в программе", isOn: $persist)
                .tint(Theme.accent).font(.subheadline).foregroundStyle(.white.opacity(0.7))
        }
    }

    private var suggestButton: some View {
        Button { onAction(.requestSuggestions) } label: {
            HStack {
                Text("Предложи варианты").foregroundStyle(Theme.accent)
                if loading { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.14)))
        }
        .disabled(loading)
    }

    @ViewBuilder
    private func alternativesBlock(_ resp: SwapResponse) -> some View {
        Text("ВАРИАНТЫ ОТ ПЕЙНА").font(.caption2).tracking(0.5).foregroundStyle(.white.opacity(0.4))
        ForEach(resp.alternatives) { alt in
            Button { selectedSlug = alt.slug } label: { alternativeRow(alt) }
                .buttonStyle(.plain)
        }
        if let rejected = resp.rejected {
            Text("Не подойдёт: \(prettify(rejected.slug)) — \(rejected.reason)")
                .font(.footnote).foregroundStyle(.white.opacity(0.5))
        }
    }

    private func alternativeRow(_ alt: SwapResponse.Alternative) -> some View {
        let selected = selectedSlug == alt.slug
        return HStack(spacing: 10) {
            thumb(alt.slug, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(prettify(alt.slug)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Text(alt.why).font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Theme.accent : .white.opacity(0.25))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.accent.opacity(0.5) : Color.white.opacity(0.07), lineWidth: selected ? 1 : 0.5))
    }

    private func confirmBar(_ slug: String) -> some View {
        VStack {
            Spacer()
            Button { confirm(newSlug: slug) } label: {
                Text("Заменить на «\(prettify(slug))»")
                    .font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(Theme.accent))
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func thumb(_ slug: String, size: CGFloat) -> some View {
        Group {
            if let url = thumbnail(slug), let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: size * 0.5)).foregroundStyle(Theme.accent.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - Helpers

    private func prettify(_ slug: String) -> String {
        let p = slug.replacingOccurrences(of: "-", with: " ")
        return p.prefix(1).uppercased() + p.dropFirst()
    }

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
