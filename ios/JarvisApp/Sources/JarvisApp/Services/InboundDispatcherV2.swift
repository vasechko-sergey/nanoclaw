import Foundation

protocol ContextCoordinatorV2 {
    func health() async throws -> V2.JSONValue
    func calendar(window: String) async throws -> V2.JSONValue
    func device() async throws -> V2.JSONValue
    func nextEvent() async throws -> V2.JSONValue?
    func recentLocations(hours: Int) async throws -> V2.JSONValue
    func screenState() async throws -> V2.JSONValue
    func reminders(window: String) async throws -> V2.JSONValue
    func focus() async throws -> V2.JSONValue
}

enum InboundDispatcherFieldError: Error, CustomStringConvertible, Equatable {
    case denied
    case unsupported
    case failed(String)
    var description: String {
        switch self {
        case .denied: return "denied"
        case .unsupported: return "unsupported"
        case .failed(let s): return s
        }
    }
}

actor InboundDispatcherV2 {
    private let coordinator: ContextCoordinatorV2
    init(coordinator: ContextCoordinatorV2) { self.coordinator = coordinator }

    func gather(
        requestID: String,
        fields: [String],
        params: V2.JSONValue?
    ) async -> V2.ContextResponse {
        var data: [String: V2.JSONValue] = [:]
        var errors: [String: String] = [:]

        await withTaskGroup(of: (String, Result<V2.JSONValue?, Error>).self) { group in
            for f in fields {
                group.addTask { [coordinator] in
                    do {
                        let v: V2.JSONValue?
                        switch f {
                        case "health": v = try await coordinator.health()
                        case "calendar":
                            let calWindow = Self.stringParam(params, key: "calendar_window") ?? "today"
                            v = try await coordinator.calendar(window: calWindow)
                        case "device": v = try await coordinator.device()
                        case "next_event": v = try await coordinator.nextEvent()
                        case "recent_locations":
                            let hours = Self.intParam(params, key: "locations_hours") ?? 12
                            v = try await coordinator.recentLocations(hours: hours)
                        case "screen_state": v = try await coordinator.screenState()
                        case "reminders":
                            let remWindow = Self.stringParam(params, key: "calendar_window") ?? "today"
                            v = try await coordinator.reminders(window: remWindow)
                        case "focus": v = try await coordinator.focus()
                        default: throw InboundDispatcherFieldError.unsupported
                        }
                        return (f, .success(v))
                    } catch {
                        return (f, .failure(error))
                    }
                }
            }
            for await (field, result) in group {
                switch result {
                case .success(let v?): data[field] = v
                case .success(nil): continue
                case .failure(let e): errors[field] = "\(e)"
                }
            }
        }

        return V2.ContextResponse(
            request_id: requestID,
            data: .object(data),
            errors: errors.isEmpty ? nil : errors
        )
    }

    private static func intParam(_ params: V2.JSONValue?, key: String) -> Int? {
        guard case .object(let obj) = params else { return nil }
        guard let v = obj[key] else { return nil }
        if case .int(let i) = v { return i }
        if case .double(let d) = v { return Int(d) }
        return nil
    }

    private static func stringParam(_ params: V2.JSONValue?, key: String) -> String? {
        guard case .object(let obj) = params else { return nil }
        guard let v = obj[key] else { return nil }
        if case .string(let s) = v { return s }
        return nil
    }
}
