import Foundation

/// Pure quiet-hours window test. Minutes are minutes-since-local-midnight in
/// [0,1440). The window may wrap midnight (start > end).
enum QuietHours {
    static func contains(minutes t: Int, start: Int, end: Int, enabled: Bool) -> Bool {
        guard enabled, start != end else { return false }
        if start < end { return t >= start && t < end }
        return t >= start || t < end   // overnight wrap
    }
}

/// Muted-agent set persisted as a JSON-array string in AppStorage.
enum MutedAgents {
    static func decode(_ raw: String) -> Set<String> {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    static func encode(_ set: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(Array(set).sorted()),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}
