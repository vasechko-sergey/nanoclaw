import Foundation
import Combine

/// Central coordinator that owns all services and wires them together.
/// Views observe this instead of owning services directly.
@MainActor
final class AppCoordinator: ObservableObject {

    // MARK: – Services (owned)
    @Published private(set) var ws: WebSocketClient
    @Published private(set) var store: ConversationStore
    @Published private(set) var location: LocationManager
    @Published private(set) var health: HealthManager

    // MARK: – Connection state
    @Published var connectionPhase: ConnectionPhase = .idle

    enum ConnectionPhase: Equatable {
        case idle
        case connecting
        case connected
        case failed
    }

    private var settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    // MARK: – Haptic callback (keeps Service layer UI-free)
    var onMessageReceived: (() -> Void)?

    // MARK: – Init

    init(settings: AppSettings) {
        self.settings = settings
        self.ws = WebSocketClient()
        self.store = ConversationStore()
        self.location = LocationManager()
        self.health = HealthManager()

        wireUp()
    }

    /// Replace settings reference (needed because ContentView gets @EnvironmentObject after init).
    func updateSettings(_ s: AppSettings) {
        self.settings = s
    }

    // MARK: – Lifecycle

    /// Begin connection. Call from splash when settings are configured.
    func connect() {
        guard settings.isConfigured else { return }
        connectionPhase = .connecting
        ws.connect(settings: settings)
        if settings.useLocation { location.requestAndUpdate() }
        if settings.useHealth   { health.requestAndFetch()    }
    }

    func disconnect() {
        ws.disconnect()
        connectionPhase = .idle
    }

    // MARK: – Chat actions

    func sendMessage(_ text: String) {
        let ctx = ContextBuilder.build(settings: settings, location: location, health: health)
        ws.send(text: text, context: ctx)
    }

    func handleAction(_ action: ConversationAction) {
        switch action {
        case .newChat:
            let conv = store.createNew()
            ws.conversationId = conv.id
            ws.sendNewConversation(id: conv.id)
            ws.messages = []

        case .newChatWithContext(let context):
            let conv = store.createNew()
            ws.conversationId = conv.id
            ws.sendNewConversation(id: conv.id)
            ws.messages = []
            // Small delay so the new conversation is established
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.sendMessage("/context Ранее мы обсуждали: \(context)")
            }

        case .open(let conversation):
            store.activeConversationId = conversation.id
            ws.conversationId = conversation.id
            ws.loadMessages(from: store)
        }
    }

    // MARK: – Wiring

    private func wireUp() {
        // Forward nested objectWillChange so SwiftUI sees updates
        // to ws.messages, ws.isTyping, store.conversations, etc.
        ws.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Set initial conversation
        ws.conversationId = store.activeConversationId
        ws.loadMessages(from: store)

        // Persist messages when they change
        ws.onMessagesChanged = { [weak self] messages in
            guard let self, let cid = self.store.activeConversationId else { return }
            self.store.saveMessages(messages, for: cid)
        }

        // Forward haptic callback when a message arrives from assistant
        ws.onAssistantMessage = { [weak self] in
            self?.onMessageReceived?()
        }

        // Track connection state
        ws.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    self.connectionPhase = .connected
                } else if self.connectionPhase == .connecting || self.connectionPhase == .connected {
                    self.connectionPhase = .failed
                }
            }
            .store(in: &cancellables)
    }
}
