import SwiftUI
import UIKit
import Photos

struct MessageBubble: View {
    let message: ChatMessage
    var onImageTap: ((UIImage) -> Void)? = nil
    var onFeedback: ((String, Bool) -> Void)? = nil
    var onActionTap: ((String, String, String) -> Void)? = nil  // (messageId, buttonId, buttonLabel)
    var onSpeak: ((String) -> Void)? = nil

    @State private var feedback: FeedbackState = .none

    private enum FeedbackState { case none, positive, negative }
    private var isUser: Bool { message.role == .user }

    var body: some View {
        switch message.content {
        case .text(let text):
            textBubble(text)
        case .image(let img, _):
            imageBubble(img)
        case .file(let info):
            FileBubble(info: info, isUser: isUser)
        case .action(let info):
            ActionBubble(messageId: message.id, info: info, onTap: onActionTap)
        case .status(let info):
            StatusBanner(info: info)
        }
    }

    // MARK: – Text bubble

    private func textBubble(_ text: String) -> some View {
        HStack {
            if isUser { Spacer(minLength: Theme.scaled(48)) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Group {
                    if isUser {
                        Text(text)
                            .font(.system(size: Theme.fontBody))
                    } else {
                        MarkdownText(text, fontSize: Theme.fontBody)
                    }
                }
                .padding(.horizontal, Theme.messagePadH)
                .padding(.vertical, Theme.messagePadV)
                .background(isUser ? Theme.userBubble : Theme.assistantBubble)
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                        .stroke(
                            isUser
                                ? AnyShapeStyle(Theme.userBubbleBorder)
                                : AnyShapeStyle(
                                    LinearGradient(
                                        colors: [Theme.accent.opacity(0.12), Theme.accent.opacity(0.03)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                ),
                            lineWidth: 0.5
                        )
                )
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = text
                        Theme.hapticSend()
                    } label: {
                        Label("Копировать", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: text) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                    if !isUser {
                        Divider()
                        Button {
                            onSpeak?(text)
                        } label: {
                            Label("Проговорить", systemImage: "speaker.wave.2")
                        }
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
                } preview: {
                    Group {
                        if isUser {
                            Text(text).font(.system(size: Theme.fontBody))
                        } else {
                            MarkdownText(text, fontSize: Theme.fontBody)
                        }
                    }
                    .padding(.horizontal, Theme.messagePadH)
                    .padding(.vertical, Theme.messagePadV)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: Theme.scaled(300), alignment: .leading)
                    .background(isUser ? Theme.userBubble : Theme.assistantBubble)
                    .background(Theme.background)
                }
                .tint(Theme.accent)

                timestampRow
            }
            if message.role == .assistant { Spacer(minLength: Theme.scaled(48)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier(isUser ? "bubble-user-\(message.id)" : "bubble-assistant-\(message.id)")
    }

    // MARK: – Image bubble

    private func imageBubble(_ img: UIImage) -> some View {
        HStack {
            if isUser { Spacer(minLength: Theme.scaled(48)) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: Theme.scaled(260))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                    .onTapGesture { onImageTap?(img) }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.image = img
                            Theme.hapticSend()
                        } label: {
                            Label("Копировать", systemImage: "doc.on.doc")
                        }
                        Button {
                            Task {
                                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                                guard status == .authorized || status == .limited else { return }
                                try? await PHPhotoLibrary.shared().performChanges {
                                    PHAssetChangeRequest.creationRequestForAsset(from: img)
                                }
                            }
                            Theme.hapticSend()
                        } label: {
                            Label("Сохранить в фото", systemImage: "square.and.arrow.down")
                        }
                    }
                    .tint(Theme.accent)

                timestampRow
            }
            if message.role == .assistant { Spacer(minLength: Theme.scaled(48)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: – Timestamp row

    private var timestampRow: some View {
        HStack(spacing: Theme.scaled(6)) {
            Text(message.timestamp, style: .time)
                .font(.system(size: Theme.fontSmall))
                .foregroundStyle(Theme.timestamp)
                .accessibilityHidden(true)

            deliveryStatusIcon

            if !isUser && feedback != .none {
                Image(systemName: feedback == .positive ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.system(size: Theme.scaled(9)))
                    .foregroundStyle(feedback == .positive ? Theme.accentMedium : Theme.offline.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private var deliveryStatusIcon: some View {
        if message.role == .user {
            switch message.deliveryStatus {
            case .sending:
                Image(systemName: "clock")
                    .font(.system(size: Theme.scaled(10), weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.5))
            case .sent:
                Image(systemName: "checkmark")
                    .font(.system(size: Theme.scaled(10), weight: .semibold))
                    .foregroundStyle(Theme.accent.opacity(0.7))
            case .delivered:
                HStack(spacing: Theme.scaled(-3)) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                }
                .font(.system(size: Theme.scaled(10), weight: .semibold))
                .foregroundStyle(Theme.accent.opacity(0.7))
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: Theme.scaled(11)))
                    .foregroundStyle(.red)
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

// MARK: – File Bubble

struct FileBubble: View {
    let info: FileInfo
    let isUser: Bool

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: Theme.scaled(48)) }

            HStack(spacing: Theme.scaled(10)) {
                Image(systemName: iconForMime(info.mimeType))
                    .font(.system(size: Theme.scaled(24)))
                    .foregroundStyle(Theme.accent)
                    .frame(width: Theme.scaled(36))

                VStack(alignment: .leading, spacing: Theme.scaled(2)) {
                    Text(info.name)
                        .font(.system(size: Theme.fontSubhead, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(0.8))
                        .lineLimit(1)
                    Text(formattedSize(info.size))
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()
            }
            .padding(.horizontal, Theme.messagePadH)
            .padding(.vertical, Theme.messagePadV)
            .background(isUser ? Theme.userBubble : Theme.assistantBubble)
            .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                    .stroke(isUser ? Theme.userBubbleBorder : Theme.assistantBubbleBorder, lineWidth: 0.5)
            )
            .frame(maxWidth: Theme.scaled(280))

            if !isUser { Spacer(minLength: Theme.scaled(48)) }
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

// MARK: – Action Bubble

struct ActionBubble: View {
    let messageId: String
    let info: ActionInfo
    var onTap: ((String, String, String) -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.scaled(10)) {
                Text(info.text)
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))

                if info.answered {
                    // Show selected button as confirmed
                    if let selectedId = info.selectedId,
                       let btn = info.buttons.first(where: { $0.id == selectedId }) {
                        HStack(spacing: Theme.scaled(6)) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: Theme.scaled(14)))
                            Text(btn.label)
                                .font(.system(size: Theme.fontSubhead, weight: .medium))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Theme.scaled(12))
                        .padding(.vertical, Theme.scaled(6))
                        .background(Theme.accent.opacity(0.1))
                        .clipShape(Capsule())
                    }
                } else {
                    // Interactive buttons
                    FlowLayout(spacing: Theme.scaled(8)) {
                        ForEach(info.buttons) { btn in
                            Button {
                                Theme.hapticSend()
                                onTap?(messageId, btn.id, btn.label)
                            } label: {
                                Text(btn.label)
                                    .font(.system(size: Theme.fontSubhead, weight: .medium))
                                    .foregroundStyle(foregroundFor(btn.style))
                                    .padding(.horizontal, Theme.scaled(14))
                                    .padding(.vertical, Theme.scaled(8))
                                    .background(backgroundFor(btn.style))
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(borderFor(btn.style), lineWidth: 0.5)
                                    )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.messagePadH)
            .padding(.vertical, Theme.messagePadV)
            .background(Theme.assistantBubble)
            .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                    .stroke(Theme.assistantBubbleBorder, lineWidth: 0.5)
            )

            Spacer(minLength: Theme.scaled(48))
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

// MARK: – Status Banner  ──── icon text ────

struct StatusBanner: View {
    let info: StatusInfo

    var body: some View {
        HStack(alignment: .top, spacing: Theme.scaled(6)) {
            Image(systemName: icon)
                .font(.system(size: Theme.scaled(11)))
            Text(info.text)
                .font(.system(size: Theme.fontSmall, weight: .medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.scaled(12))
        .padding(.vertical, Theme.scaled(7))
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(color.opacity(0.18), lineWidth: 0.5)
        )
        .padding(.horizontal, Theme.hPadding)
        .padding(.vertical, Theme.scaled(4))
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

// MARK: – Flow Layout (for action buttons)

struct FlowLayout: Layout {
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
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

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

// MARK: – Typing Indicator

struct TypingIndicator: View {
    var body: some View {
        HStack {
            MiniOrbView(size: Theme.scaled(28), mood: .processing)
                .padding(8)
            Spacer()
        }
        .accessibilityLabel("Jarvis обрабатывает запрос")
    }
}
