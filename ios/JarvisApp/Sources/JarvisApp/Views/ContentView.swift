import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var coordinator: AppCoordinator

    @State private var appPhase: AppPhase = .splash
    @State private var showSetupOnSplash = false

    enum AppPhase {
        case splash, chat
    }

    var body: some View {
        ZStack {
            // Main content always underneath
            ChatView(coordinator: coordinator)
                .opacity(appPhase == .chat ? 1 : 0)

            // Splash overlay
            if appPhase == .splash {
                SplashView(
                    coordinator: coordinator,
                    settings: settings,
                    showSetup: $showSetupOnSplash,
                    onReady: {
                        withAnimation(.easeOut(duration: 0.6)) {
                            appPhase = .chat
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .onAppear {
            // If configured, start connecting immediately during splash
            if settings.isConfigured {
                coordinator.connect()
            } else {
                showSetupOnSplash = true
            }
        }
    }
}

// MARK: – Splash

struct SplashView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @Binding var showSetup: Bool
    var onReady: () -> Void

    @State private var phase: SplashPhase = .loading
    @State private var titleOpacity: Double = 0
    @State private var statusOpacity: Double = 0
    @State private var orbBrightness: Double = 0.5
    @State private var timeoutTask: DispatchWorkItem?

    private enum SplashPhase {
        case loading, connecting, ready, waitingSetup, failed
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                OrbView(size: Theme.scaled(140), brightness: orbBrightness)

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
        .onChange(of: coordinator.connectionPhase) { _, newPhase in
            switch newPhase {
            case .connected:
                timeoutTask?.cancel()
                withAnimation(.easeInOut(duration: 0.4)) {
                    phase = .ready
                    orbBrightness = 1.0
                    titleOpacity = 0.7
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    onReady()
                }
            case .failed:
                timeoutTask?.cancel()
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = .failed
                    orbBrightness = 0.3
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
            Text("инициализация...")
                .foregroundStyle(Theme.accent.opacity(0.25))
        case .connecting:
            Text("подключение...")
                .foregroundStyle(Theme.accent.opacity(0.35))
        case .ready:
            Text("системы активны")
                .foregroundStyle(Theme.online.opacity(0.6))
        case .waitingSetup:
            Text("необходима настройка")
                .foregroundStyle(Theme.accent.opacity(0.3))
        case .failed:
            Text("ошибка подключения")
                .foregroundStyle(Theme.offline.opacity(0.7))
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
                        orbBrightness = 0.5
                    }
                    coordinator.connect()
                    startTimeout()
                } label: {
                    Text("Повторить")
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
                    Text("Продолжить оффлайн")
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.accent.opacity(0.5))
                }
                .frame(minHeight: Theme.minTapSize)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var setupCard: some View {
        VStack(spacing: Theme.scaled(16)) {
            // Server URL
            VStack(alignment: .leading, spacing: Theme.scaled(4)) {
                Text("Сервер")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.accent.opacity(0.4))
                TextField("100.x.x.x:3001", text: $settings.serverURL)
                    .font(.system(size: Theme.fontInput))
                    .foregroundStyle(Theme.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .tint(Theme.accent)
                    .padding(.horizontal, Theme.messagePadH)
                    .padding(.vertical, Theme.messagePadV)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .stroke(Theme.surfaceBorder, lineWidth: 0.5)
                    )
            }

            // Token
            VStack(alignment: .leading, spacing: Theme.scaled(4)) {
                Text("Токен")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.accent.opacity(0.4))
                SecureField("Bearer token", text: $settings.bearerToken)
                    .font(.system(size: Theme.fontInput))
                    .foregroundStyle(Theme.textPrimary)
                    .textContentType(.none)
                    .tint(Theme.accent)
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
                guard settings.isConfigured else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    showSetup = false
                    phase = .connecting
                }
                coordinator.connect()
                startTimeout()
            } label: {
                Text("Подключиться")
                    .font(.system(size: Theme.fontSubhead, weight: .medium))
                    .foregroundStyle(settings.isConfigured ? Theme.background : Theme.accent.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.scaled(14))
                    .background(settings.isConfigured ? Theme.accent : Theme.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            }
            .disabled(!settings.isConfigured)
        }
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
            titleOpacity = 0.5
            statusOpacity = 1
        }

        if showSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = .waitingSetup
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = .connecting
                }
            }
            startTimeout()
        }
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        let task = DispatchWorkItem {
            guard phase == .connecting else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                phase = .failed
                orbBrightness = 0.3
            }
            Theme.hapticError()
        }
        timeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: task)
    }
}
