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
    @Published private(set) var calendar: CalendarManager
    @Published private(set) var speech: SpeechSynthesizer

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
        self.calendar = CalendarManager()
        self.speech = SpeechSynthesizer()

        wireUp()

        AppDelegate.onOpenConversation = { [weak self] id in
            self?.openConversation(id: id)
        }
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
        if settings.useCalendar { calendar.requestAndFetch()  }
    }

    func disconnect() {
        ws.disconnect()
        connectionPhase = .idle
    }

    // MARK: – Chat actions

    func sendMessage(_ text: String) {
        let ctx = ContextBuilder.build(settings: settings, location: location, health: health, calendar: calendar)
        ws.send(text: text, context: ctx)
    }

    func sendFeedback(messageId: String, value: Bool, messageText: String) {
        ws.sendFeedback(conversationId: ws.conversationId, messageId: messageId, value: value, messageText: messageText)
    }

    func sendHealthUpdate(_ data: [String: Any]) {
        ws.sendHealthUpdate(data)
    }

    func sendActionResponse(messageId: String, buttonId: String, buttonLabel: String) {
        ws.sendActionResponse(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
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

    /// Open a conversation by id (used by proactive-push deep-link).
    func openConversation(id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        store.activeConversationId = uuid
        ws.conversationId = uuid
        ws.loadMessages(from: store)
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

        // Auto-speak assistant text in the active conversation when enabled
        ws.onSpeakableText = { [weak self] text in
            guard let self, self.settings.autoSpeak else { return }
            self.speech.speak(text, voiceId: self.settings.voiceId)
        }

        // Persist messages that arrive for a non-active conversation
        ws.onBackgroundMessage = { [weak self] convId, message in
            guard let self else { return }
            var msgs = self.store.loadMessages(for: convId)
            msgs.append(message)
            self.store.saveMessages(msgs, for: convId)
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
