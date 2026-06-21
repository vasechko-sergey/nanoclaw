import Foundation
import GRDB

/// The result of `AppV2Bootstrap.build` — the production wiring of the v2
/// transport stack. Downstream callers (Phase 5.2b's `WebSocketClientFacade`)
/// hold this struct and drive `transport.connect()` + `transport.tickDispatcher()`.
struct AppV2Stack {
    let store: ConversationStoreV2
    let transport: TransportV2
    let coordinator: AppContextCoordinator
    let dbq: DatabaseQueue
    /// Canonical persistent queue of un-delivered `set_log` events. The
    /// `WorkoutCoordinator` writes here on each logged set; on WS connect
    /// the transport drains it. UI layers must build their `WorkoutCoordinator`
    /// from this reference so the producer and the drain share one GRDB writer.
    let setLogQueue: SetLogQueue
}

/// Builds the v2 stack: opens (and migrates) the on-disk SQLite and
/// instantiates the WebSocket + TransportV2 actor + ContextCoordinator. Pure
/// construction — no network IO happens here. Callers are responsible for
/// calling `transport.connect()` once they're ready.
enum AppV2Bootstrap {
    /// Build the storage half of the stack (DB queue + migrated schema + the
    /// UI-facing `MessageTimeline`). Separated from `build` so the
    /// `AppCoordinator` can construct the timeline before the user has
    /// finished configuring the WebSocket URL — otherwise the splash + chat
    /// views would have no message stream to render until the first
    /// successful `connect()`.
    @MainActor
    static func buildStorage() throws -> (dbq: DatabaseQueue, store: ConversationStoreV2, timeline: MessageTimeline) {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbURL = docs.appendingPathComponent("jarvis-v2.sqlite")
        let dbq = try DatabaseQueue(path: dbURL.path)

        // Point the shared image store at its on-disk home before the schema
        // migration / one-shot data migration touch it.
        ChatImageStore.shared = ChatImageStore(baseURL: ChatImageStore.defaultBaseURL())

        try Schema.migrate(dbq)

        // One-shot: move any legacy inline-base64 image rows into the store.
        // Guarded so it only walks the table once per install.
        let flag = "didMigrateChatImagesToStore"
        if !UserDefaults.standard.bool(forKey: flag) {
            try? AttachmentMigration.run(writer: dbq, store: ChatImageStore.shared)
            UserDefaults.standard.set(true, forKey: flag)
        }

        let store = ConversationStoreV2(writer: dbq)
        let timeline = MessageTimeline(store: store, dbq: dbq)
        return (dbq, store, timeline)
    }

    @MainActor
    static func build(
        serverURL: URL,
        token: String,
        location: LocationManager? = nil,
        health: HealthManager? = nil,
        calendar: CalendarManager? = nil
    ) throws -> AppV2Stack {
        let (dbq, store, _) = try buildStorage()

        let socket = URLSessionWebSocket(url: serverURL)
        let coordinator = AppContextCoordinator(
            location: location,
            health: health,
            calendar: calendar
        )
        let transport = TransportV2(
            store: store,
            socket: socket,
            token: token,
            contextCoordinator: coordinator
        )
        let setLogQueue = SetLogQueue(writer: dbq)

        return AppV2Stack(
            store: store,
            transport: transport,
            coordinator: coordinator,
            dbq: dbq,
            setLogQueue: setLogQueue
        )
    }

    /// Variant used when the storage half has already been built (e.g. by the
    /// `AppCoordinator` at init time). Reuses the existing `dbq`/`store`
    /// instead of re-opening the database, so the `MessageTimeline` and the
    /// transport see the exact same writer. The timeline itself stays with
    /// `AppCoordinator`; this builder only needs the `(dbq, store)` pair.
    static func build(
        serverURL: URL,
        token: String,
        storage: (dbq: DatabaseQueue, store: ConversationStoreV2),
        location: LocationManager? = nil,
        health: HealthManager? = nil,
        calendar: CalendarManager? = nil
    ) -> AppV2Stack {
        let socket = URLSessionWebSocket(url: serverURL)
        let coordinator = AppContextCoordinator(
            location: location,
            health: health,
            calendar: calendar
        )
        let transport = TransportV2(
            store: storage.store,
            socket: socket,
            token: token,
            contextCoordinator: coordinator
        )
        let setLogQueue = SetLogQueue(writer: storage.dbq)
        return AppV2Stack(
            store: storage.store,
            transport: transport,
            coordinator: coordinator,
            dbq: storage.dbq,
            setLogQueue: setLogQueue
        )
    }
}
