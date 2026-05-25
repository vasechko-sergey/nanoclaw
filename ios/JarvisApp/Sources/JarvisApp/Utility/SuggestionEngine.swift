import SwiftUI

/// Tracks suggestion usage frequency and provides smart, hybrid suggestions.
/// Falls back to time-of-day defaults when no usage history exists.
enum SuggestionEngine {

    // MARK: – All known suggestions

    /// Master catalog of suggestions with icons.
    static let catalog: [(text: String, icon: String)] = [
        ("Погода",     "cloud.sun"),
        ("Новости",    "newspaper"),
        ("Расписание", "calendar"),
        ("Напомни",    "bell"),
        ("Серфинг",    "water.waves"),
        ("Перевод",    "textformat.abc"),
        ("Итоги дня",  "chart.bar"),
    ]

    /// Icon lookup by suggestion text.
    static func icon(for text: String) -> String {
        catalog.first(where: { $0.text == text })?.icon ?? "text.bubble"
    }

    // MARK: – Time-of-day defaults

    private static func defaultSuggestions() -> [String] {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<10:  return ["Погода", "Серфинг", "Расписание", "Новости"]
        case 10..<14: return ["Расписание", "Напомни", "Серфинг", "Погода"]
        case 14..<18: return ["Новости", "Напомни", "Серфинг", "Итоги дня"]
        case 18..<22: return ["Серфинг", "Итоги дня", "Погода", "Напомни"]
        default:      return ["Напомни", "Погода", "Серфинг", "Новости"]
        }
    }

    // MARK: – Frequency tracking (UserDefaults)

    private static let storageKey = "suggestionFrequency"

    /// Record that a suggestion was used.
    static func recordUsage(_ text: String) {
        var freq = loadFrequency()
        freq[text, default: 0] += 1
        UserDefaults.standard.set(freq, forKey: storageKey)
    }

    private static func loadFrequency() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
    }

    private static var hasHistory: Bool {
        let freq = loadFrequency()
        let total = freq.values.reduce(0, +)
        return total >= 5  // need at least 5 uses to personalize
    }

    // MARK: – Smart suggestions

    /// Returns top-N suggestions: personalized if enough history, otherwise time-of-day defaults.
    static func suggestions(count: Int = 4) -> [String] {
        guard hasHistory else {
            return Array(defaultSuggestions().prefix(count))
        }

        let freq = loadFrequency()
        let sorted = freq
            .sorted { $0.value > $1.value }
            .map(\.key)
            .filter { text in catalog.contains(where: { $0.text == text }) }  // only known suggestions

        // Fill up to count with defaults if not enough history entries
        var result = Array(sorted.prefix(count))
        if result.count < count {
            let remaining = defaultSuggestions().filter { !result.contains($0) }
            result.append(contentsOf: remaining.prefix(count - result.count))
        }
        return Array(result.prefix(count))
    }
}
