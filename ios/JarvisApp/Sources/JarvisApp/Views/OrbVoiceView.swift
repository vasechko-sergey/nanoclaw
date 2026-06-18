import SwiftUI

/// Fullscreen voice mode. Presented over ChatView or OrbHomeView. Renders the
/// large orb, live partial transcript, and bottom controls. Drives a
/// `VoiceLoopController` and integrates SpeechManager (STT) + the shared
/// `coordinator.speech` (TTS).
struct OrbVoiceView: View {
    @Environment(AppSettings.self) var settings
    @Environment(ActiveAgentState.self) private var active
    @Environment(\.dismiss) private var dismiss
    var coordinator: AppCoordinator
    /// When non-nil, dismiss handoff goes here (e.g., "к чату" tap). When nil,
    /// dismiss just closes the cover and returns to the presenting screen.
    var onHandoffToChat: (() -> Void)?

    @State private var controller = VoiceLoopController()
    @State private var speech = SpeechManager()
    @State private var silenceTimer: Timer?
    /// Text of the latest assistant reply (cached so it survives TTS / audio playback).
    @State private var lastReplyText: String = ""
    /// Whether the "показать текст" panel is currently visible.
    @State private var showReplyText = false
    /// Pending wait for the asynchronous server voice note (see awaitServerVoice).
    @State private var voiceWaitTask: Task<Void, Never>?

    private var orbMood: OrbMood {
        switch controller.phase {
        case .calm:       return .calm
        case .listening:  return .listening
        case .processing: return .processing
        case .speaking:   return .speaking
        case .error:      return .error
        }
    }

    private var orbSize: CGFloat {
        min(UIScreen.main.bounds.width * 0.6, 280)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                statusRow
                    .padding(.horizontal, Theme.hPadding)
                    .padding(.top, Theme.scaled(12))

                Spacer()

                VStack(spacing: Theme.scaled(20)) {
                    OrbView(size: orbSize, mood: orbMood)
                        .onTapGesture {
                            if !settings.pushToTalk { handleOrbTap() }
                        }
                        .gesture(settings.pushToTalk ? holdGesture : nil)

                    transcriptText
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Theme.hPadding)
                }

                Spacer()

                if showReplyText && !lastReplyText.isEmpty {
                    replyTextPanel
                        .padding(.horizontal, Theme.hPadding)
                        .padding(.bottom, Theme.scaled(12))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                bottomControls
                    .padding(.horizontal, Theme.hPadding)
                    .padding(.bottom, Theme.scaled(28))
            }
        }
        .accessibilityIdentifier("orb-voice-view")
        .onAppear { onAppear() }
        .onDisappear { onDisappear() }
        .onChange(of: coordinator.ws.messages.last?.id) {
            handleNewAssistantMessage()
        }
    }

    // MARK: – Subviews

    private var statusRow: some View {
        HStack(spacing: Theme.scaled(8)) {
            Circle()
                .fill(coordinator.ws.isConnected ? Theme.online : Theme.offline)
                .frame(width: 6, height: 6)
            Text(coordinator.ws.isConnected ? "online" : "offline")
                .font(.system(size: Theme.fontSmall, design: .monospaced))
                .foregroundStyle(Theme.accentMedium)
            Spacer()
            Text(Date(), style: .time)
                .font(.system(size: Theme.fontSmall, design: .monospaced))
                .foregroundStyle(Theme.accentMedium)
        }
    }

    private var transcriptText: some View {
        Text(controller.transcript)
            .font(.system(size: Theme.scaled(16), design: .monospaced))
            .foregroundStyle(Theme.textPrimary.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .animation(.easeOut(duration: 0.2), value: controller.transcript)
    }

    private var replyTextPanel: some View {
        ScrollView {
            Text(lastReplyText)
                .font(.system(size: Theme.scaled(14)))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.scaled(12))
        }
        .frame(maxHeight: Theme.scaled(160))
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.accent.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var bottomControls: some View {
        HStack {
            Button {
                handoff()
            } label: {
                Label("к чату", systemImage: "arrow.up")
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundStyle(Theme.accentMedium)
            }
            .accessibilityIdentifier("voice-handoff-btn")

            Spacer()

            if !lastReplyText.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showReplyText.toggle()
                    }
                } label: {
                    Image(systemName: showReplyText ? "text.bubble.fill" : "text.bubble")
                        .font(.system(size: Theme.scaled(22)))
                        .foregroundStyle(showReplyText ? Theme.accent : Theme.accentMedium)
                }
                .accessibilityIdentifier("voice-show-text-btn")
                .accessibilityLabel(showReplyText ? "Скрыть текст" : "Показать текст")

                Spacer()
            }

            Button {
                handleClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Theme.scaled(32)))
                    .foregroundStyle(Theme.accentMedium)
            }
            .accessibilityIdentifier("voice-close-btn")
        }
    }

    // MARK: – Lifecycle

    private func onAppear() {
        speech.onTranscript = { [controller, speech] partial in
            Task { @MainActor in
                let isFinal = !speech.isRecording
                controller.handleTranscript(partial, isFinal: isFinal)
            }
        }
        if !settings.pushToTalk {
            controller.start()
            speech.start()
        }
        startSilenceTimer()
    }

    private func onDisappear() {
        speech.stop()
        coordinator.speech.stop()
        coordinator.audioPlayer.stop()
        silenceTimer?.invalidate()
        silenceTimer = nil
        voiceWaitTask?.cancel()
        voiceWaitTask = nil
        controller.stop()
    }

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard let last = controller.lastPartialAt else { return }
                let elapsed = Date().timeIntervalSince(last)
                controller.tickSilence(elapsed: elapsed,
                                       threshold: TimeInterval(settings.silenceTimeoutSec))
            }
        }
    }

    // MARK: – Orb interactions

    private func handleOrbTap() {
        switch controller.phase {
        case .calm, .error:
            controller.start()
            speech.start()
        case .listening:
            speech.stop()
            controller.handleTranscript(controller.transcript, isFinal: true)
            sendIfReady()
        case .processing, .speaking:
            break
        }
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if controller.phase != .listening {
                    controller.holdStart()
                    speech.start()
                }
            }
            .onEnded { _ in
                speech.stop()
                controller.holdEnd()
                sendIfReady()
            }
    }

    private func sendIfReady() {
        guard controller.phase == .processing, !controller.transcript.isEmpty else { return }
        // Orb fullscreen always wants a server voice reply — pass forceVoice: true so
        // the autoSpeak gate in AppCoordinator is bypassed for this path.
        coordinator.sendMessage(controller.transcript, viaVoice: true, forceVoice: true, agentId: active.active.rawValue)
    }

    private func handleNewAssistantMessage() {
        guard let msg = coordinator.ws.messages.last,
              msg.role == .assistant else { return }

        // Cache the reply text so «показать текст» can reveal it.
        if !msg.text.isEmpty { lastReplyText = msg.text }

        if let audioInfo = msg.audioInfo,
           let b64 = audioInfo.url,
           let data = Data(base64Encoded: b64) {
            // Server-rendered Jarvis voice (the .audio message) — the real reply
            // audio. Cancel any pending wait and play it.
            voiceWaitTask?.cancel()
            controller.handleAssistantTextArrived(msg.text)
            coordinator.audioPlayer.play(data: data)
            observeAudioFinish()
        } else if coordinator.lastSendWantedServerVoice {
            // Text arrived first; the server voice note follows asynchronously as
            // a separate .audio message (handled above). Do NOT fall back to
            // on-device Apple TTS — voice is server-side now. Stay in .processing
            // (orb keeps "thinking") and wait for the audio.
            awaitServerVoice()
        } else {
            // No server voice was requested for this reply — keep the on-device
            // fallback so the orb still talks.
            guard !msg.text.isEmpty else { return }
            controller.handleAssistantTextArrived(msg.text)
            coordinator.speech.speak(msg.text)
            observeSynthesizerFinish()
        }
    }

    /// Await the asynchronous server voice note. If it never lands (render
    /// failure / sidecar down), park the loop after a timeout instead of
    /// spinning on .processing forever. No on-device TTS — the text stays
    /// readable via «показать текст».
    private func awaitServerVoice() {
        voiceWaitTask?.cancel()
        voiceWaitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(240))
            guard !Task.isCancelled, controller.phase == .processing else { return }
            controller.handleSynthesizerDidFinish(autoResume: settings.autoResumeListening)
            if settings.autoResumeListening { speech.start() }
        }
    }

    private func observeAudioFinish() {
        Task { @MainActor in
            while coordinator.audioPlayer.isPlaying {
                try? await Task.sleep(for: .milliseconds(150))
            }
            controller.handleSynthesizerDidFinish(autoResume: settings.autoResumeListening)
            if settings.autoResumeListening {
                speech.start()
            }
        }
    }

    private func observeSynthesizerFinish() {
        Task { @MainActor in
            while coordinator.speech.isSpeaking {
                try? await Task.sleep(for: .milliseconds(150))
            }
            controller.handleSynthesizerDidFinish(autoResume: settings.autoResumeListening)
            if settings.autoResumeListening {
                speech.start()
            }
        }
    }

    private func handoff() {
        speech.stop()
        coordinator.speech.stop()
        dismiss()
        onHandoffToChat?()
    }

    private func handleClose() {
        dismiss()
    }
}
