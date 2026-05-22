import SwiftUI

/// Siri-style input: a central tappable orb with a row of satellite action orbs.
/// Tap the orb runs the user's primary action (voice or keyboard). Satellites
/// expose keyboard, camera, photo, document and commands — all visible at rest
/// so nothing is hidden behind a gesture. Reuses `OrbView` for the orb visual.
struct OrbInputBar: View {
    @Binding var text: String
    @Binding var inputViaVoice: Bool
    @Binding var drafts: [DraftAttachment]
    let commands: [BotCommand]
    var isDisabled: Bool = false
    var enterToSend: Bool = true
    /// "voice" → tap orb starts dictation; "text" → tap orb opens the keyboard.
    var orbPrimary: String = "voice"
    let onSend: () -> Void

    @StateObject private var speech = SpeechManager()
    @State private var showKeyboard = false
    @State private var showCommands = false
    @State private var listenPulse: CGFloat = 1
    @FocusState private var textFocused: Bool

    // Picker triggers driven by satellite taps.
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showDoc = false

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canSend: Bool { !isEmpty || !drafts.isEmpty }

    private var filteredCommands: [BotCommand] {
        if showCommands { return commands }
        guard text.hasPrefix("/") else { return [] }
        let q = text.lowercased()
        return q == "/" ? commands : commands.filter { $0.command.lowercased().hasPrefix(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !filteredCommands.isEmpty {
                CommandList(commands: filteredCommands) { cmd in
                    text = cmd
                    showCommands = false
                    openKeyboard()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !drafts.isEmpty {
                AttachmentChips(drafts: $drafts)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showKeyboard {
                composeRow
            } else {
                orbCluster
            }
        }
        .padding(.horizontal, Theme.scaled(8))
        .padding(.vertical, Theme.scaled(8))
        .background(Theme.background)
        .opacity(isDisabled ? 0.4 : 1.0)
        .allowsHitTesting(!isDisabled)
        .animation(.easeInOut(duration: 0.2), value: showKeyboard)
        .animation(.easeInOut(duration: 0.15), value: filteredCommands.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: drafts.isEmpty)
        .attachmentPickers(drafts: $drafts, showPhotos: $showPhotos, showCamera: $showCamera, showDoc: $showDoc)
        .onAppear {
            speech.onTranscript = { transcript in
                text = transcript
                inputViaVoice = true
            }
        }
        .onChange(of: speech.isRecording) {
            // When dictation ends with text, drop into compose so the user can edit + send.
            if !speech.isRecording && !isEmpty { openKeyboard() }
        }
    }

    // MARK: – Orb cluster (resting state)

    private var orbCluster: some View {
        VStack(spacing: Theme.scaled(10)) {
            HStack(spacing: Theme.scaled(14)) {
                SatelliteOrb(icon: "keyboard", label: "Текст") { openKeyboard() }
                if cameraAvailable {
                    SatelliteOrb(icon: "camera", label: "Камера") { showCamera = true }
                }
                SatelliteOrb(icon: "photo", label: "Фото") { showPhotos = true }
                SatelliteOrb(icon: "doc", label: "Документ") { showDoc = true }
                SatelliteOrb(icon: "slash.circle", label: "Команды", active: showCommands) {
                    showCommands.toggle()
                }
            }

            centralOrb
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.scaled(6))
        .padding(.bottom, Theme.scaled(4))
    }

    @ViewBuilder
    private var centralOrb: some View {
        Button(action: tapOrb) {
            ZStack {
                if canSend && !speech.isRecording {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: Theme.scaled(64)))
                        .foregroundStyle(Theme.accent)
                } else {
                    OrbView(size: Theme.scaled(84), brightness: speech.isRecording ? 1.0 : 0.7)
                    if speech.isRecording {
                        Circle()
                            .stroke(Theme.accent.opacity(0.5), lineWidth: 2)
                            .frame(width: Theme.scaled(84), height: Theme.scaled(84))
                            .scaleEffect(listenPulse)
                            .opacity(2 - listenPulse)
                    }
                    Image(systemName: orbPrimary == "voice" ? "mic.fill" : "keyboard")
                        .font(.system(size: Theme.scaled(18)))
                        .foregroundStyle(Theme.accent.opacity(0.9))
                        .opacity(speech.isRecording ? 0 : 0.85)
                }
            }
            .frame(width: Theme.scaled(92), height: Theme.scaled(92))
            .contentShape(Circle())
        }
        .accessibilityLabel(orbLabel)
        .onChange(of: speech.isRecording) {
            if speech.isRecording {
                listenPulse = 1
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    listenPulse = 1.6
                }
            }
        }
    }

    private var orbLabel: String {
        if speech.isRecording { return "Остановить запись" }
        if canSend { return "Отправить" }
        return orbPrimary == "voice" ? "Голосовой ввод" : "Открыть клавиатуру"
    }

    private func tapOrb() {
        Theme.hapticSend()
        if speech.isRecording { speech.stop(); return }
        if canSend { onSend(); collapse(); return }
        if orbPrimary == "voice" {
            if speech.isAvailable { speech.toggle() } else { openKeyboard() }
        } else {
            openKeyboard()
        }
    }

    // MARK: – Compose row (keyboard state)

    private var composeRow: some View {
        HStack(spacing: Theme.scaled(4)) {
            Button { collapse() } label: {
                Image(systemName: "chevron.down.circle")
                    .font(.system(size: Theme.scaled(26)))
                    .foregroundStyle(Theme.accentMedium)
                    .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            .accessibilityLabel("Свернуть клавиатуру")

            AttachmentMenuButton(drafts: $drafts, isDisabled: isDisabled)

            TextField("Спросить Jarvis...", text: $text, axis: .vertical)
                .font(.system(size: Theme.fontInput))
                .lineLimit(1...5)
                .focused($textFocused)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .padding(.horizontal, Theme.messagePadH)
                .padding(.vertical, Theme.messagePadV)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.inputRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.inputRadius)
                        .stroke(Theme.surfaceBorder, lineWidth: 0.5)
                )
                .onChange(of: text) {
                    if showCommands && !text.hasPrefix("/") { showCommands = false }
                    if enterToSend && text.contains("\n") {
                        text = text.replacingOccurrences(of: "\n", with: "")
                        if !isDisabled && canSend { Theme.hapticSend(); onSend(); collapse() }
                    }
                }
                .onSubmit {
                    if enterToSend && !isDisabled && canSend { Theme.hapticSend(); onSend(); collapse() }
                }
                .submitLabel(enterToSend ? .send : .return)

            Button {
                Theme.hapticSend()
                onSend()
                collapse()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: Theme.scaled(32)))
                    .foregroundStyle(Theme.accent)
                    .opacity(canSend ? 1.0 : 0.2)
            }
            .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            .disabled(!canSend || isDisabled)
            .accessibilityLabel("Отправить")
        }
    }

    // MARK: – Helpers

    private func openKeyboard() {
        showCommands = false
        showKeyboard = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { textFocused = true }
    }

    private func collapse() {
        textFocused = false
        showKeyboard = false
    }
}

/// Small satellite action orb: a circular button with an SF Symbol.
private struct SatelliteOrb: View {
    let icon: String
    let label: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.scaled(3)) {
                ZStack {
                    Circle()
                        .fill(Theme.surface)
                        .frame(width: Theme.scaled(40), height: Theme.scaled(40))
                        .overlay(
                            Circle().stroke(active ? Theme.accent : Theme.surfaceBorder,
                                            lineWidth: active ? 1 : 0.5)
                        )
                    Image(systemName: icon)
                        .font(.system(size: Theme.scaled(17)))
                        .foregroundStyle(active ? Theme.accent : Theme.accentMedium)
                }
                Text(label)
                    .font(.system(size: Theme.scaled(9)))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityLabel(label)
    }
}
