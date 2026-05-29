import SwiftUI

/// Unified input bar (Alice-style): text field with "+" inside for attachments,
/// one button on the right — mic when empty, send arrow when text exists.
/// During voice recording the mic becomes a stop button and transcript fills the field.
struct UnifiedInputBar: View {
    @Binding var text: String
    @Binding var inputViaVoice: Bool
    @Binding var drafts: [DraftAttachment]
    let commands: [BotCommand]
    var isDisabled: Bool = false
    var enterToSend: Bool = true
    @Binding var autoStartVoice: Bool
    let onSend: () -> Void
    var onPinchOut: (() -> Void)? = nil

    @State private var speech = SpeechManager()
    @State private var showCommands = false
    @FocusState private var textFocused: Bool

    // Picker triggers
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
            // Command suggestions
            if !filteredCommands.isEmpty {
                CommandList(commands: filteredCommands) { cmd in
                    text = cmd
                    showCommands = false
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // Attachment chips
            if !drafts.isEmpty {
                AttachmentChips(drafts: $drafts)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Main input row
            HStack(spacing: Theme.scaled(6)) {
                // The text field with "+" inside
                HStack(spacing: 0) {
                    // "+" attachment menu
                    attachmentPlus

                    // Text field
                    TextField("Спросить Jarvis...", text: $text, axis: .vertical)
                        .font(.system(size: Theme.fontInput))
                        .lineLimit(1...5)
                        .focused($textFocused)
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .padding(.trailing, Theme.messagePadH)
                        .padding(.vertical, Theme.messagePadV)
                        .onChange(of: text) {
                            if showCommands && !text.hasPrefix("/") { showCommands = false }
                            if enterToSend && text.contains("\n") {
                                text = text.replacingOccurrences(of: "\n", with: "")
                                if !isDisabled && canSend { Theme.hapticSend(); onSend() }
                            }
                        }
                        .onSubmit {
                            if enterToSend && !isDisabled && canSend { Theme.hapticSend(); onSend() }
                        }
                        .submitLabel(enterToSend ? .send : .return)
                        .accessibilityIdentifier("message-input")
                }
                .background(Theme.inputBg)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.inputBarRadius)
                        .stroke(Theme.accent.opacity(0.15), lineWidth: Theme.lineHairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.inputBarRadius))

                // Single right button: mic / stop / send
                rightButton
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onEnded { value in
                                if value.magnification > 1.4 {
                                    onPinchOut?()
                                }
                            }
                    )
            }
            .padding(.horizontal, Theme.scaled(8))
            .padding(.vertical, Theme.scaled(8))
            .background(Theme.background)
            .opacity(isDisabled ? 0.4 : 1.0)
            .allowsHitTesting(!isDisabled)
        }
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
            // When recording stops and there's text, focus the field so user can edit/send
            if !speech.isRecording && !isEmpty {
                textFocused = true
            }
        }
        .onChange(of: autoStartVoice) {
            if autoStartVoice {
                autoStartVoice = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    if speech.isAvailable && !speech.isRecording {
                        speech.toggle()
                    } else if !speech.isAvailable {
                        // Voice unavailable (e.g. simulator) — focus text field instead
                        textFocused = true
                    }
                }
            }
        }
    }

    // MARK: – "+" button inside text field

    private var attachmentPlus: some View {
        Menu {
            if cameraAvailable {
                Button { showCamera = true } label: { Label("Камера", systemImage: "camera") }
            }
            Button { showPhotos = true } label: { Label("Фото", systemImage: "photo") }
            Button { showDoc = true } label: { Label("Документ", systemImage: "doc") }
            Button { showCommands.toggle() } label: { Label("Команды", systemImage: "slash.circle") }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: Theme.scaled(22)))
                .foregroundStyle(Theme.accentMedium)
                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
        }
        .disabled(isDisabled)
        .accessibilityLabel("Прикрепить")
    }

    // MARK: – Right button (mic / send)

    private var rightButton: some View {
        VoiceButton(
            isRecording: speech.isRecording,
            canSend: canSend,
            isAvailable: speech.isAvailable,
            onTap: {
                if speech.isRecording {
                    speech.stop()
                } else if canSend {
                    Theme.hapticSend()
                    onSend()
                } else if speech.isAvailable {
                    Theme.hapticSend()
                    speech.toggle()
                }
            }
        )
    }
}

// MARK: – Orb Voice Button

/// A single button that morphs between two visual states:
/// 1. Orb (idle / recording) — mini OrbView, mood changes with state
/// 2. Send — accent circle with arrow up, when text is present
///
/// The orb IS the mic button. Tap to start/stop recording. When text appears it becomes send.
private struct VoiceButton: View {
    let isRecording: Bool
    let canSend: Bool
    let isAvailable: Bool
    let onTap: () -> Void

    private let orbSize: CGFloat = Theme.scaled(36)
    private var buttonSize: CGFloat { Theme.minTapSize }

    private var orbMood: OrbMood {
        isRecording ? .listening : .calm
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if canSend && !isRecording {
                    // Send mode — accent circle + arrow
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: orbSize, height: orbSize)

                    Image(systemName: "arrow.up")
                        .font(.system(size: Theme.scaled(18), weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    // Orb mode — mini orb as the button
                    MiniOrbView(size: orbSize, mood: orbMood)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
        }
        .disabled(!isAvailable && !canSend && !isRecording)
        .accessibilityLabel(
            isRecording ? "Остановить запись" :
            canSend ? "Отправить" : "Голосовой ввод"
        )
        .accessibilityIdentifier("send-btn")
        .animation(.easeInOut(duration: 0.25), value: canSend)
        .animation(.easeInOut(duration: 0.25), value: isRecording)
    }
}
