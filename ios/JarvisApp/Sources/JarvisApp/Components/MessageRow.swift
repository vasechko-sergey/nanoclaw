import SwiftUI
import UIKit
import Photos

/// Bubbleless message renderer. Replaces MessageBubble.
struct MessageRow: View {
    let message: ChatMessage
    let isLast: Bool
    var onImageTap: ((UIImage) -> Void)? = nil
    var onFeedback: ((String, Bool) -> Void)? = nil
    var onActionTap: ((String, String, String) -> Void)? = nil
    var onSpeak: ((String) -> Void)? = nil
    var onRetry: ((String) -> Void)? = nil

    @State private var feedback: FeedbackState = .none

    private enum FeedbackState { case none, positive, negative }
    private var isUser: Bool { message.role == .user }

    var body: some View {
        Group {
            switch message.content {
            case .text(let text):
                textRow(text)
            case .image(let img, _):
                imageRow(img)
            case .file(let info):
                FileRow(info: info, isUser: isUser, isLast: isLast)
            case .action(let info):
                ActionRow(messageId: message.id, info: info, onTap: onActionTap, isLast: isLast)
            case .status(let info):
                StatusRow(info: info)
            }
        }
        .id(message.id)
    }

    // MARK: - Text row

    private func textRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                avatarDot
                VStack(alignment: .leading, spacing: 4) {
                    metaRow
                    Group {
                        if isUser {
                            Text(text).font(.system(size: 14))
                        } else {
                            MarkdownText(text, fontSize: 14)
                        }
                    }
                    .foregroundStyle(isUser ? .white : Theme.assistantText)
                    .lineSpacing(2)
                    .contextMenu {
                        contextMenuButtons(text)
                    }
                }
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, Theme.rowPadV)

            if !isLast {
                Rectangle()
                    .fill(Theme.hairlineColor)
                    .frame(height: 0.5)
                    .padding(.horizontal, Theme.rowPadH)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier(isUser ? "row-user-\(message.id)" : "row-assistant-\(message.id)")
    }

    // MARK: - Image row

    private func imageRow(_ img: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                avatarDot
                VStack(alignment: .leading, spacing: 4) {
                    metaRow
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
                        .onTapGesture { onImageTap?(img) }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.image = img
                                Theme.hapticSend()
                            } label: { Label("Копировать", systemImage: "doc.on.doc") }
                            Button {
                                Task {
                                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                                    guard status == .authorized || status == .limited else { return }
                                    try? await PHPhotoLibrary.shared().performChanges {
                                        PHAssetChangeRequest.creationRequestForAsset(from: img)
                                    }
                                }
                            } label: { Label("Сохранить в фото", systemImage: "square.and.arrow.down") }
                        }
                }
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, Theme.rowPadV)

            if !isLast {
                Rectangle()
                    .fill(Theme.hairlineColor)
                    .frame(height: 0.5)
                    .padding(.horizontal, Theme.rowPadH)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Building blocks

    private var avatarDot: some View {
        Circle()
            .fill(isUser
                  ? Theme.avatarUserDot
                  : Theme.accent)
            .frame(width: Theme.avatarDotSize, height: Theme.avatarDotSize)
            .shadow(color: isUser ? .clear : Theme.accent.opacity(0.5), radius: 3)
            .padding(.top, 7)
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(isUser ? "Я" : "JARVIS")
                .font(Theme.metaFont)
                .tracking(0.5)
                .foregroundStyle(Theme.accentMedium)
            Spacer()
            Text(message.timestamp, style: .time)
                .font(Theme.metaFont)
                .foregroundStyle(Theme.timestamp)
            if isUser {
                DeliveryChecks(status: message.deliveryStatus, onRetryTap: {
                    onRetry?(message.id)
                })
            }
            if !isUser && feedback != .none {
                Image(systemName: feedback == .positive ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(feedback == .positive ? Theme.accentMedium : Theme.offline.opacity(0.5))
            }
        }
        .textCase(.uppercase)
    }

    @ViewBuilder
    private func contextMenuButtons(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            Theme.hapticSend()
        } label: { Label("Копировать", systemImage: "doc.on.doc") }
        ShareLink(item: text) {
            Label("Поделиться", systemImage: "square.and.arrow.up")
        }
        if !isUser {
            Divider()
            Button {
                onSpeak?(text)
            } label: { Label("Проговорить", systemImage: "speaker.wave.2") }
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    feedback = feedback == .positive ? .none : .positive
                }
                if feedback == .positive { onFeedback?(message.id, true) }
            } label: {
                Label(feedback == .positive ? "Убрать оценку" : "Полезно",
                      systemImage: feedback == .positive ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    feedback = feedback == .negative ? .none : .negative
                }
                if feedback == .negative { onFeedback?(message.id, false) }
            } label: {
                Label(feedback == .negative ? "Убрать оценку" : "Не полезно",
                      systemImage: feedback == .negative ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
        }
    }

    private var accessibilityDescription: String {
        let role = isUser ? "Пользователь" : "Jarvis"
        let time = message.timestamp.formatted(date: .omitted, time: .shortened)
        switch message.content {
        case .text(let text):
            return "\(role): \(text). \(time)"
        case .image(_, let filename):
            return "\(role): изображение \(filename). \(time)"
        case .file(let info):
            return "\(role): файл \(info.name). \(time)"
        case .action(let info):
            return "Jarvis запрашивает: \(info.text). \(time)"
        case .status(let info):
            return "Система: \(info.text). \(time)"
        }
    }
}

// MARK: - File row

struct FileRow: View {
    let info: FileInfo
    let isUser: Bool
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(isUser ? Theme.avatarUserDot : Theme.accent)
                    .frame(width: Theme.avatarDotSize, height: Theme.avatarDotSize)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(isUser ? "Я" : "JARVIS")
                            .font(Theme.metaFont)
                            .tracking(0.5)
                            .foregroundStyle(Theme.accentMedium)
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Image(systemName: iconForMime(info.mimeType))
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                                .lineLimit(1)
                            Text(formattedSize(info.size))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Theme.accent.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
                    .frame(maxWidth: 280)
                }
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, Theme.rowPadV)

            if !isLast {
                Rectangle()
                    .fill(Theme.hairlineColor)
                    .frame(height: 0.5)
                    .padding(.horizontal, Theme.rowPadH)
            }
        }
    }

    private func iconForMime(_ mime: String) -> String {
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "play.rectangle" }
        if mime.contains("pdf")     { return "doc.richtext" }
        if mime.contains("zip") || mime.contains("tar") { return "doc.zipper" }
        if mime.contains("spreadsheet") || mime.contains("excel") { return "tablecells" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "rectangle.on.rectangle" }
        if mime.contains("word") || mime.contains("document") { return "doc.text" }
        return "doc"
    }

    private func formattedSize(_ bytes: Int64) -> String {
        if bytes == 0 { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Action row

struct ActionRow: View {
    let messageId: String
    let info: ActionInfo
    var onTap: ((String, String, String) -> Void)?
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: Theme.avatarDotSize, height: Theme.avatarDotSize)
                    .shadow(color: Theme.accent.opacity(0.5), radius: 3)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("JARVIS")
                            .font(Theme.metaFont)
                            .tracking(0.5)
                            .foregroundStyle(Theme.accentMedium)
                        Spacer()
                    }

                    Text(info.text)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.assistantText)

                    if info.answered, let sid = info.selectedId,
                       let btn = info.buttons.first(where: { $0.id == sid }) {
                        HStack(spacing: 6) {
                            CheckmarkShape()
                                .stroke(Theme.accent, style: StrokeStyle(lineWidth: Theme.lineAccent, lineCap: .round, lineJoin: .round))
                                .frame(width: 10, height: 6)
                            Text(btn.label)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.12))
                        .clipShape(Capsule())
                    } else {
                        FlowLayoutRow(spacing: 8) {
                            ForEach(info.buttons) { btn in
                                Button {
                                    Theme.hapticSend()
                                    onTap?(messageId, btn.id, btn.label)
                                } label: {
                                    Text(btn.label)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(foregroundFor(btn.style))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(backgroundFor(btn.style))
                                        .clipShape(Capsule())
                                        .overlay(Capsule().stroke(borderFor(btn.style), lineWidth: Theme.lineHairline))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, Theme.rowPadV)

            if !isLast {
                Rectangle()
                    .fill(Theme.hairlineColor)
                    .frame(height: 0.5)
                    .padding(.horizontal, Theme.rowPadH)
            }
        }
    }

    private func foregroundFor(_ style: ActionButton.Style) -> Color {
        switch style {
        case .primary:   return Theme.accent
        case .danger:    return Theme.offline
        case .secondary: return Theme.textSecondary
        }
    }
    private func backgroundFor(_ style: ActionButton.Style) -> Color {
        switch style {
        case .primary:   return Theme.accent.opacity(0.12)
        case .danger:    return Theme.offline.opacity(0.12)
        case .secondary: return Theme.surface
        }
    }
    private func borderFor(_ style: ActionButton.Style) -> Color {
        switch style {
        case .primary:   return Theme.accent.opacity(0.3)
        case .danger:    return Theme.offline.opacity(0.3)
        case .secondary: return Theme.surfaceBorder
        }
    }
}

// MARK: - Status row

struct StatusRow: View {
    let info: StatusInfo

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(info.text)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 280, alignment: .leading)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall)
                .stroke(color.opacity(0.18), lineWidth: Theme.lineHairline)
        )
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch info.kind {
        case "cost":   return "dollarsign.circle"
        case "health": return "heart.fill"
        case "alert":  return "exclamationmark.triangle.fill"
        case "system": return "gear"
        default:
            switch info.level {
            case .warning: return "exclamationmark.triangle"
            case .error:   return "xmark.circle"
            case .info:    return "info.circle"
            }
        }
    }
    private var color: Color {
        switch info.level {
        case .info:    return Theme.accent
        case .warning: return .orange
        case .error:   return Theme.offline
        }
    }
}

// MARK: - Thinking row (busy indicator)

struct ThinkingRow: View {
    let detail: String?
    @State private var dots: String = ""
    @State private var dotTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            MiniOrbView(size: 14, mood: .processing)
                .padding(.leading, 1)
            Text(label + dots)
                .font(.system(size: 13, design: .default).italic())
                .foregroundStyle(Theme.accent.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, Theme.rowPadV)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Jarvis обрабатывает запрос")
        .accessibilityIdentifier("thinking-row")
        .onAppear { startDots() }
        .onDisappear { dotTask?.cancel(); dotTask = nil }
    }

    private var label: String {
        detail ?? "обдумываю"
    }

    private func startDots() {
        dotTask?.cancel()
        dotTask = Task { @MainActor in
            let cycle = ["", ".", "..", "..."]
            var i = 0
            while !Task.isCancelled {
                dots = cycle[i % cycle.count]
                i += 1
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }
}

// MARK: - FlowLayoutRow (renamed from FlowLayout to avoid conflict with MessageBubble)

struct FlowLayoutRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? .infinity, subviews: subviews)
        return result.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, pos) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                                  proposal: .unspecified)
        }
    }
    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
