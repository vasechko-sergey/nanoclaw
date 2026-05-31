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
}

/// Builds the v2 stack: opens (and migrates) the on-disk SQLite, runs the
/// one-shot legacy-data importer, and instantiates the WebSocket + TransportV2
/// actor + ContextCoordinator. Pure construction — no network IO happens here.
/// Callers are responsible for calling `transport.connect()` once they're ready.
enum AppV2Bootstrap {
    static func build(
        serverURL: URL,
        token: String,
        location: LocationManager? = nil,
        health: HealthManager? = nil,
        calendar: CalendarManager? = nil
    ) throws -> AppV2Stack {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbURL = docs.appendingPathComponent("jarvis-v2.sqlite")
        let dbq = try DatabaseQueue(path: dbURL.path)
        try Schema.migrate(dbq)

        let store = ConversationStoreV2(writer: dbq)
        try MigrationV2.runIfNeeded(documentsURL: docs, store: store)

        let socket = URLSessionWebSocket(url: serverURL)
        let transport = TransportV2(store: store, socket: socket, token: token)
        let coordinator = AppContextCoordinator(
            location: location,
            health: health,
            calendar: calendar
        )

        return AppV2Stack(
            store: store,
            transport: transport,
            coordinator: coordinator,
            dbq: dbq
        )
    }
}
