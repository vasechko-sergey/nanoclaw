import SwiftUI

/// Orb-centric input: a central tappable orb with orbital satellite actions.
/// Tap = primary action (voice or send). Long press = reveal satellites in a circle.
/// Reuses `OrbView` for the orb visual.
struct OrbInputBar: View {
    @Binding var text: String
    @Binding var inputViaVoice: Bool
    @Binding var drafts: [DraftAttachment]
    let commands: [BotCommand]
    var isDisabled: Bool = false
    var enterToSend: Bool = true
    var showKeyboardShortcut: Bool = true
    /// "voice" → tap orb starts dictation; "text" → tap orb opens the keyboard.
    var orbPrimary: String = "voice"
    /// When set to true from outside (e.g. home screen tap), auto-start voice recording.
    @Binding var autoStartVoice: Bool
    let onSend: () -> Void

    @State private var speech = SpeechManager()
    @State private var showKeyboard = false
    @State private var showSatellites = false
    @State private var showCommands = false
    @FocusState private var textFocused: Bool
    @Namespace private var orbTransition

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

    // Satellite definitions
    private var satellites: [(icon: String, label: String, action: () -> Void)] {
        var items: [(String, String, () -> Void)] = [
            ("keyboard", "Текст", { openKeyboard() }),
        ]
        if cameraAvailable {
            items.append(("camera", "Камера", { showCamera = true }))
        }
        items.append(contentsOf: [
            ("photo", "Фото", { showPhotos = true }),
            ("doc", "Файл", { showDoc = true }),
            ("slash.circle", "Команды", { showCommands.toggle() }),
        ])
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            if !filteredCommands.isEmpty {
                CommandList(commands: filteredCommands, onClose: showCommands ? { showCommands = false } : nil) { cmd in
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
        .animation(.easeInOut(duration: 0.25), value: showKeyboard)
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
            if !speech.isRecording && !isEmpty { openKeyboard() }
        }
        .onChange(of: autoStartVoice) {
            if autoStartVoice {
                autoStartVoice = false
                // Small delay to let the view settle after transition
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    if speech.isAvailable && !speech.isRecording {
                        speech.toggle()
                    }
                }
            }
        }
    }

    // MARK: – Orb cluster (resting state)

    private var orbCluster: some View {
        ZStack {
            // Orbital satellites (shown on long press)
            ForEach(Array(satellites.enumerated()), id: \.offset) { index, sat in
                let count = satellites.count
                let angle = -.pi / 2 + (2 * .pi / Double(count)) * Double(index)
                let radius = Theme.scaled(70)
                let x = cos(angle) * radius
                let y = sin(angle) * radius

                SatelliteOrb(icon: sat.icon, label: sat.label, active: sat.icon == "slash.circle" && showCommands) {
                    sat.action()
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                        showSatellites = false
                    }
                }
                .offset(x: showSatellites ? x : 0, y: showSatellites ? y : 0)
                .scaleEffect(showSatellites ? 1.0 : 0.3)
                .opacity(showSatellites ? 1.0 : 0)
                .animation(
                    .spring(duration: 0.4, bounce: 0.25).delay(Double(index) * 0.06),
                    value: showSatellites
                )
            }

            // Central orb
            centralOrb

            // Optional keyboard shortcut button (left of orb)
            if showKeyboardShortcut && !showSatellites && !speech.isRecording {
                Button { openKeyboard() } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: Theme.scaled(14)))
                        .foregroundStyle(Theme.accentMedium)
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
                .offset(x: -Theme.scaled(62))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.scaled(160))
        .contentShape(Rectangle())
        .onTapGesture {
            // Dismiss satellites if tapped outside
            if showSatellites {
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                    showSatellites = false
                }
            }
        }
    }

    /// Current mood derived from state.
    private var currentOrbMood: OrbMood {
        if speech.isRecording { return .listening }
        if showSatellites { return .heroic }
        return .ready
    }

    @ViewBuilder
    private var centralOrb: some View {
        ZStack {
            if canSend && !speech.isRecording {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: Theme.scaled(64)))
                    .foregroundStyle(Theme.accent)
                    .matchedGeometryEffect(id: "orbInput", in: orbTransition)
            } else {
                MiniOrbView(size: Theme.scaled(84), mood: currentOrbMood)
                    .matchedGeometryEffect(id: "orbInput", in: orbTransition)
                Image(systemName: orbPrimary == "voice" ? "mic.fill" : "keyboard")
                    .font(.system(size: Theme.scaled(18)))
                    .foregroundStyle(Theme.accent.opacity(0.9))
                    .opacity(speech.isRecording ? 0 : 0.85)
            }
        }
        .frame(width: Theme.scaled(92), height: Theme.scaled(92))
        .contentShape(Circle())
        .scaleEffect(showSatellites ? 1.05 : 1.0)
        .animation(.spring(duration: 0.3), value: showSatellites)
        .onTapGesture {
            tapOrb()
        }
        .onLongPressGesture(minimumDuration: 0.3) {
            Theme.hapticMedium()
            withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
                showSatellites.toggle()
            }
        }
        .accessibilityLabel(orbLabel)
    }

    private var orbLabel: String {
        if speech.isRecording { return "Остановить запись" }
        if canSend { return "Отправить" }
        return orbPrimary == "voice" ? "Голосовой ввод" : "Открыть клавиатуру"
    }

    private func tapOrb() {
        if showSatellites {
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                showSatellites = false
            }
            return
        }
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
                    .matchedGeometryEffect(id: "orbInput", in: orbTransition)
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
                .accessibilityIdentifier("message-input")

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
            .accessibilityIdentifier("send-btn")
        }
    }

    // MARK: – Helpers

    private func openKeyboard() {
        showCommands = false
        showSatellites = false
        showKeyboard = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            textFocused = true
        }
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
                            Circle().stroke(active ? Theme.accent : Theme.accent.opacity(0.2),
                                            lineWidth: active ? 1 : 0.5)
                        )
                        .shadow(color: Theme.accent.opacity(0.15), radius: 6)
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
