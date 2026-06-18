import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) var settings
    @Environment(ActiveAgentState.self) private var active
    var coordinator: AppCoordinator

    @State private var appPhase: AppPhase = .splash
    @State private var showSetupOnSplash = false
    @State private var pendingMessage: String? = nil
    @State private var autoStartVoice = false

    enum AppPhase {
        case splash, home, chat
    }

    var body: some View {
        ZStack {
            // Chat — always mounted, opacity-driven
            ChatView(coordinator: coordinator, onGoHome: goHome, autoStartVoice: $autoStartVoice)
                .opacity(appPhase == .chat ? 1 : 0)
                .allowsHitTesting(appPhase == .chat)

            // Home — orb hub
            if appPhase == .home {
                OrbHomeView(
                    coordinator: coordinator,
                    onStartChat: { message in
                        if let msg = message {
                            coordinator.sendMessage(msg, agentId: active.active.rawValue)
                        }
                        autoStartVoice = false
                        withAnimation(.easeOut(duration: 0.4)) {
                            appPhase = .chat
                        }
                    },
                    onStartVoiceChat: {
                        autoStartVoice = true
                        withAnimation(.easeOut(duration: 0.4)) {
                            appPhase = .chat
                        }
                    },
                    onContinueChat: {
                        withAnimation(.easeOut(duration: 0.4)) {
                            appPhase = .chat
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(0.5)
            }

            // Splash overlay
            if appPhase == .splash {
                SplashView(
                    coordinator: coordinator,
                    settings: settings,
                    showSetup: $showSetupOnSplash,
                    onReady: {
                        withAnimation(.easeOut(duration: 0.6)) {
                            appPhase = .home
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .onAppear {
            if settings.isConfigured {
                coordinator.connect()
            } else {
                showSetupOnSplash = true
            }
        }
    }

    private func goHome() {
        withAnimation(.easeOut(duration: 0.35)) {
            appPhase = .home
        }
    }
}

// MARK: – Splash

struct SplashView: View {
    var coordinator: AppCoordinator
    @Bindable var settings: AppSettings
    @Binding var showSetup: Bool
    var onReady: () -> Void

    @State private var phase: SplashPhase = .loading
    @State private var titleOpacity: Double = 0
    @State private var statusOpacity: Double = 0
    @State private var orbMood: OrbMood = .calm
    @State private var timeoutTask: Task<Void, Never>?
    // Local input for the setup card. bearerToken is @ObservationIgnored @AppStorage,
    // so binding the field straight to it never re-evaluates the button's
    // .disabled(!isConfigured) — the button stays greyed even with a token typed.
    // Drive the field + button off this @State, commit to settings on connect.
    @State private var tokenInput = ""

    private enum SplashPhase {
        case loading, connecting, ready, waitingSetup, failed
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                OrbView(size: Theme.scaled(140), mood: orbMood)

                VStack(spacing: Theme.scaled(12)) {
                    Text("J A R V I S")
                        .font(.system(size: Theme.fontSmall, weight: .light))
                        .tracking(Theme.titleTracking)
                        .foregroundStyle(Theme.accent)
                        .opacity(titleOpacity)

                    statusText
                        .font(.system(size: Theme.scaled(9), weight: .regular, design: .monospaced))
                        .opacity(statusOpacity)
                }
                .padding(.top, Theme.scaled(24))

                // Error actions
                errorActions
                    .padding(.top, Theme.scaled(20))

                // Setup card appears inline on splash if no settings
                if showSetup {
                    setupCard
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .padding(.top, Theme.scaled(32))
                }

                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { startAnimation() }
        .onChange(of: coordinator.connectionPhase) {
            switch coordinator.connectionPhase {
            case .connected:
                timeoutTask?.cancel()
                withAnimation(.easeInOut(duration: 0.4)) {
                    phase = .ready
                    orbMood = .heroic
                    titleOpacity = 1.0
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    onReady()
                }
            case .failed:
                timeoutTask?.cancel()
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = .failed
                    orbMood = .error
                }
                Theme.hapticError()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch phase {
        case .loading:
            Text("инициализация систем...")
                .foregroundStyle(Theme.accentMedium)
        case .connecting:
            Text("устанавливаю связь...")
                .foregroundStyle(Theme.accentMedium)
        case .ready:
            Text("к вашим услугам")
                .foregroundStyle(Theme.online.opacity(0.8))
        case .waitingSetup:
            Text("ожидаю параметры подключения")
                .foregroundStyle(Theme.accentMedium)
        case .failed:
            Text("не удалось установить связь")
                .foregroundStyle(Theme.offline)
        }
    }

    // MARK: – Error actions (shown below status when failed)
    @ViewBuilder
    private var errorActions: some View {
        if phase == .failed {
            VStack(spacing: Theme.scaled(10)) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        phase = .connecting
                        orbMood = .processing
                    }
                    coordinator.connect()
                    startTimeout()
                } label: {
                    Text("Повторить попытку")
                        .font(.system(size: Theme.fontSubhead, weight: .medium))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, Theme.scaled(32))
                        .padding(.vertical, Theme.scaled(12))
                        .background(Theme.accent)
                        .clipShape(Capsule())
                }
                .frame(minHeight: Theme.minTapSize)

                Button {
                    onReady()
                } label: {
                    Text("Продолжить автономно")
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.accentMedium)
                }
                .frame(minHeight: Theme.minTapSize)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// Commit the typed token (trimmed — pasted tokens often carry whitespace)
    /// and start connecting. Single entry point for the button and field submit.
    private func connectWithToken() {
        let t = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        settings.bearerToken = t
        withAnimation(.easeInOut(duration: 0.3)) {
            showSetup = false
            phase = .connecting
        }
        coordinator.connect()
        startTimeout()
    }

    private var setupCard: some View {
        let canConnect = !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: Theme.scaled(16)) {
            // Token
            VStack(alignment: .leading, spacing: Theme.scaled(4)) {
                Text("Токен")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.accentMedium)
                SecureField("Bearer token", text: $tokenInput)
                    .font(.system(size: Theme.fontInput))
                    .foregroundStyle(Theme.textPrimary)
                    .textContentType(.none)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .tint(Theme.accent)
                    .submitLabel(.go)
                    .onSubmit { connectWithToken() }
                    .padding(.horizontal, Theme.messagePadH)
                    .padding(.vertical, Theme.messagePadV)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .stroke(Theme.surfaceBorder, lineWidth: 0.5)
                    )
            }

            // Connect button
            Button {
                connectWithToken()
            } label: {
                Text("Подключиться")
                    .font(.system(size: Theme.fontSubhead, weight: .medium))
                    .foregroundStyle(canConnect ? Theme.background : Theme.accentMedium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.scaled(14))
                    .background(canConnect ? Theme.accent : Theme.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            }
            .disabled(!canConnect)
        }
        .onAppear { if tokenInput.isEmpty { tokenInput = settings.bearerToken } }
        .padding(Theme.hPadding)
        .background(Theme.background.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: Theme.scaled(20)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.scaled(20))
                .stroke(Theme.accent.opacity(0.1), lineWidth: 0.5)
        )
        .padding(.horizontal, Theme.scaled(32))
    }

    private func startAnimation() {
        withAnimation(.easeOut(duration: 0.6)) {
            titleOpacity = 0.7
            statusOpacity = 1
        }

        // UI-testing fast-path: there is no WebSocket server in the test environment,
        // so the splash would otherwise sit on "connecting" for 10s before falling
        // into the .failed state. Skip straight to .ready and fire onReady.
        if JarvisApp.isUITesting {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.easeInOut(duration: 0.2)) {
                    phase = .ready
                }
                try? await Task.sleep(for: .milliseconds(200))
                onReady()
            }
            return
        }

        if showSetup {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = .waitingSetup
                }
            }
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = .connecting
                }
            }
            startTimeout()
        }
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, phase == .connecting else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                phase = .failed
                orbMood = .error
            }
            Theme.hapticError()
        }
    }
}
