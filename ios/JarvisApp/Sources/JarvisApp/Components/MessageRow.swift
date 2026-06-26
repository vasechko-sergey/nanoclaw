import SwiftUI
import UIKit
import Photos
import AVFoundation

/// Bubbleless message renderer. Replaces MessageBubble.
struct MessageRow: View {
    let message: ChatMessage
    let isLast: Bool
    var onImageTap: ((_ thumbnail: UIImage, _ sha: String?) -> Void)? = nil
    var onFeedback: ((String, Bool) -> Void)? = nil
    var onActionTap: ((String, String, String) -> Void)? = nil
    var onWorkoutStart: ((WorkoutPlan, String) -> Void)? = nil
    var onWorkoutCancel: ((String) -> Void)? = nil
    var onRetry: ((String) -> Void)? = nil
    /// Shared player so a voice-note bubble can play/stop its own audio and
    /// reflect which note is currently playing.
    var audioPlayer: AudioPlaybackService? = nil

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
            case .audio(let info):
                // Audio note from server — render as a small file-style row with
                // an audio icon. Actual playback is driven by AppCoordinator /
                // OrbVoiceView; the row is display-only.
                FileRow(info: info, isUser: isUser, isLast: isLast)
            case .action(let info):
                ActionRow(messageId: message.id, info: info, onTap: onActionTap, isLast: isLast)
            case .workoutPlan(let info):
                WorkoutPlanRow(messageId: message.id, info: info, onStart: onWorkoutStart, onCancel: onWorkoutCancel, isLast: isLast)
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
                    if message.voiceOnly && message.attachedAudio == nil {
                        // Pending: render is in flight, hide text behind a placeholder.
                        VoicePendingView()
                    } else if message.voiceOnly, let audio = message.attachedAudio {
                        // Ready: voice note + collapsed (tap-to-expand) transcript.
                        AudioNoteView(info: audio, messageId: message.id, player: audioPlayer)
                        if !text.isEmpty {
                            CollapsibleTranscript(text: text, isUser: isUser)
                        }
                    } else {
                        // Normal: voice note (if any) above always-visible text.
                        if let audio = message.attachedAudio {
                            AudioNoteView(info: audio, messageId: message.id, player: audioPlayer)
                        }
                        if !(text.isEmpty && message.attachedAudio != nil) {
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
                        .onTapGesture { onImageTap?(img, message.imageSHA) }
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
        let color = isUser ? Theme.avatarUserDot : senderAccentColor
        return Circle()
            .fill(color)
            .frame(width: Theme.avatarDotSize, height: Theme.avatarDotSize)
            .shadow(color: isUser ? .clear : color.opacity(0.5), radius: 3)
            .padding(.top, 7)
    }

    private var senderLabel: String {
        if isUser { return "Я" }
        if let slug = message.agentId,
           let agent = AgentIdentity(rawValue: slug) {
            return agent.displayName.uppercased()
        }
        return "JARVIS"
    }

    private var senderAccentColor: Color {
        guard !isUser,
              let slug = message.agentId,
              let agent = AgentIdentity(rawValue: slug) else { return Theme.accentMedium }
        return agent.accentColor
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(senderLabel)
                .font(Theme.metaFont)
                .tracking(0.5)
                .foregroundStyle(senderAccentColor)
            Spacer()
            if message.edited {
                Text("ред.")
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.timestamp)
            }
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
        case .audio(let info):
            return "\(role): аудио \(info.name). \(time)"
        case .action(let info):
            return "Jarvis запрашивает: \(info.text). \(time)"
        case .workoutPlan(let info):
            return "Payne: тренировка \(info.dayName), \(info.intensityLabel), \(info.exerciseCount) упражнений. \(time)"
        case .status(let info):
            return "Система: \(info.text). \(time)"
        }
    }
}

// MARK: - Voice note (server-rendered)

/// A compact play/stop control for a server-rendered voice note. No filename
/// caption — just a tappable waveform. Playback goes through the shared
/// `AudioPlaybackService` so only one note plays at a time and the button
/// reflects whether THIS note is the one playing.
struct AudioNoteView: View {
    let info: FileInfo
    let messageId: String
    var player: AudioPlaybackService?

    /// Real per-bucket amplitude of THIS note, extracted from the audio once it
    /// loads (nil → show a flat placeholder profile meanwhile).
    @State private var peaks: [CGFloat]? = nil

    private var isThisPlaying: Bool {
        player?.playingId == messageId && player?.isPlaying == true
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isThisPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.accent)
                WaveformBars(active: isThisPlaying, peaks: peaks ?? WaveformExtractor.placeholder, player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isThisPlaying ? "Остановить голос" : "Прослушать голос")
        .task(id: messageId) {
            guard peaks == nil, let b64 = info.url else { return }
            let computed = await Task.detached(priority: .utility) {
                WaveformExtractor.peaks(fromBase64: b64, id: messageId)
            }.value
            if let computed { peaks = computed }
        }
    }

    private func toggle() {
        guard let player else { return }
        if isThisPlaying {
            player.stop()
            return
        }
        guard let b64 = info.url else { return }
        // Decode the base64 audio off the main thread (large clips would freeze
        // the tap), then hand the bytes to the player on the main actor.
        Task { @MainActor in
            let data = await Task.detached(priority: .userInitiated) {
                Data(base64Encoded: b64)
            }.value
            guard let data else { return }
            player.play(data: data, id: messageId)
        }
    }
}

/// A wide audio-track strip whose bar heights match the actual audio (like a
/// messenger voice note). While THIS note plays, the played portion fills in;
/// the fill sweep is driven by a paused TimelineView so only the active note
/// re-renders.
private struct WaveformBars: View {
    let active: Bool
    let peaks: [CGFloat]
    var player: AudioPlaybackService?

    var body: some View {
        GeometryReader { geo in
            // Reading `player.progress` only when active means idle bubbles don't
            // subscribe to it — only the playing note re-renders as it advances.
            let progress = active ? (player?.progress ?? 0) : 0
            let n = max(1, peaks.count)
            let spacing: CGFloat = 3
            let barW = max(2, (geo.size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<n, id: \.self) { i in
                    let played = active && Double(i) / Double(max(1, n - 1)) <= progress
                    Capsule()
                        .fill(Theme.accent.opacity(played ? 1.0 : 0.32))
                        .frame(width: barW, height: max(3, geo.size.height * peaks[i]))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .animation(.linear(duration: 0.05), value: progress)
        }
    }
}

/// Decodes a voice note's audio (base64 m4a/aac) into a small array of
/// normalized amplitude buckets for the waveform. Runs off the main actor;
/// results are cached by message id so scrolling doesn't re-decode.
enum WaveformExtractor {
    /// Flat-ish placeholder shown until the real waveform is extracted.
    static let placeholder: [CGFloat] = Array(repeating: 0.35, count: 40)

    private static let cache = NSCache<NSString, NSArray>()

    static func peaks(fromBase64 b64: String, id: String, buckets: Int = 40) -> [CGFloat]? {
        if let hit = cache.object(forKey: id as NSString) as? [CGFloat] { return hit }
        guard let data = Data(base64Encoded: b64) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp)
            let file = try AVAudioFile(forReading: tmp)
            let format = file.processingFormat
            let frames = AVAudioFrameCount(file.length)
            guard frames > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
            try file.read(into: buf)
            guard let ch = buf.floatChannelData?[0] else { return nil }
            let n = Int(buf.frameLength)
            guard n > 0 else { return nil }
            let bucket = max(1, n / buckets)
            var out: [CGFloat] = []
            out.reserveCapacity(buckets)
            var i = 0
            while i < n {
                let end = min(i + bucket, n)
                var peak: Float = 0
                var j = i
                while j < end { peak = max(peak, abs(ch[j])); j += 1 }
                out.append(CGFloat(peak))
                i = end
            }
            let maxP = out.max() ?? 1
            if maxP > 0 { out = out.map { $0 / maxP } }
            // Keep a visible floor so quiet stretches still show a sliver.
            out = out.map { max(0.1, $0) }
            cache.setObject(out as NSArray, forKey: id as NSString)
            return out
        } catch {
            return nil
        }
    }
}

/// Placeholder shown for a voice-only reply while the server renders the audio.
/// The text is withheld until the voice note lands; this fills the wait.
private struct VoicePendingView: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accent)
                .opacity(pulse ? 1.0 : 0.35)
            Text("записывает голосовое…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.assistantText.opacity(0.7))
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("Записывается голосовое сообщение")
    }
}

/// Voice-only transcript: collapsed behind a "Показать текст" control, expands
/// in place. Mirrors Telegram hiding the transcription under the voice note.
private struct CollapsibleTranscript: View {
    let text: String
    let isUser: Bool
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.up" : "text.bubble")
                        .font(.system(size: 11, weight: .semibold))
                    Text(expanded ? "Скрыть текст" : "Показать текст")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            if expanded {
                Group {
                    if isUser { Text(text).font(.system(size: 14)) }
                    else { MarkdownText(text, fontSize: 14) }
                }
                .foregroundStyle(isUser ? .white : Theme.assistantText)
                .lineSpacing(2)
                .transition(.opacity)
            }
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

                    // Buttons stay visible after the tap. The chosen one keeps its
                    // accent fill + a checkmark + a thicker outline; the rest go
                    // grey/cleared/dimmed; all become non-tappable. So it's clear
                    // which option was picked (and what the alternatives were).
                    FlowLayoutRow(spacing: 8) {
                        ForEach(info.buttons) { btn in
                            let isSelected = info.selectedId == btn.id
                            let dimmed = info.answered && !isSelected
                            Button {
                                Theme.hapticSend()
                                onTap?(messageId, btn.id, btn.label)
                            } label: {
                                HStack(spacing: 5) {
                                    if info.answered && isSelected {
                                        CheckmarkShape()
                                            .stroke(foregroundFor(btn.style), style: StrokeStyle(lineWidth: Theme.lineAccent, lineCap: .round, lineJoin: .round))
                                            .frame(width: 9, height: 6)
                                    }
                                    Text(btn.label)
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(dimmed ? Theme.textSecondary.opacity(0.6) : foregroundFor(btn.style))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(dimmed ? Color.clear : backgroundFor(btn.style))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(
                                        (info.answered && isSelected) ? foregroundFor(btn.style)
                                            : (dimmed ? Theme.surfaceBorder.opacity(0.5) : borderFor(btn.style)),
                                        lineWidth: (info.answered && isSelected) ? Theme.lineAccent : Theme.lineHairline
                                    )
                                )
                                .opacity(dimmed ? 0.6 : 1)
                            }
                            .disabled(info.answered)
                            .animation(.easeOut(duration: 0.2), value: info.answered)
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

// MARK: - Workout-plan row

struct WorkoutPlanRow: View {
    let messageId: String
    let info: WorkoutPlanCardInfo
    var onStart: ((WorkoutPlan, String) -> Void)?
    var onCancel: ((String) -> Void)?
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
                    Text("PAYNE")
                        .font(Theme.metaFont)
                        .tracking(0.5)
                        .foregroundStyle(Theme.accentMedium)

                    HStack(spacing: 6) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.system(size: 13))
                        Text("\(info.dayName) · \(info.intensityLabel) · \(info.exerciseCount) упр.")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(Theme.assistantText)

                    HStack(spacing: 8) {
                        Button {
                            Theme.hapticSend()
                            onStart?(info.plan, messageId)
                        } label: {
                            HStack(spacing: 5) {
                                if info.done {
                                    CheckmarkShape()
                                        .stroke(Theme.textSecondary.opacity(0.6), style: StrokeStyle(lineWidth: Theme.lineAccent, lineCap: .round, lineJoin: .round))
                                        .frame(width: 9, height: 6)
                                }
                                Text("Посмотреть тренировку")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(info.done ? Theme.textSecondary.opacity(0.6) : Theme.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(info.done ? Color.clear : Theme.accent.opacity(0.16))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(
                                    info.done ? Theme.surfaceBorder.opacity(0.5) : Theme.accent.opacity(0.35),
                                    lineWidth: info.done ? Theme.lineHairline : Theme.lineAccent
                                )
                            )
                            .opacity(info.done ? 0.6 : 1)
                        }
                        .disabled(info.done)

                        if !info.done {
                            Button {
                                Theme.hapticSend()
                                onCancel?(info.plan.workoutId)
                            } label: {
                                Text("Отменить")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .overlay(Capsule().stroke(Theme.surfaceBorder, lineWidth: Theme.lineHairline))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: info.done)
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
