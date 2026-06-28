import SwiftUI

/// One curated starter suggestion for an agent's home orb / empty-chat
/// satellites. `text` is sent verbatim to the active agent on tap; `icon` is
/// an SF Symbol name. `id == text` so a single agent never repeats a chip.
struct AgentSuggestion: Identifiable, Equatable {
    let text: String
    let icon: String
    var id: String { text }
}

/// Identity of one of the agent_groups multiplexed over a single iOS-app
/// WebSocket. The `rawValue` must match the agent_group's `folder` slug on
/// the host (the same value carried in the `agent_id` field of v2 envelopes
/// and stamped into the `messages.agent_id` storage column).
enum AgentIdentity: String, CaseIterable, Identifiable, Codable {
    case jarvis
    case payne
    case greg
    case scrooge
    case gordon

    var id: String { rawValue }

    /// Accept folder-name aliases the host stamps on the outbound `agent_id`
    /// field. Greg's group folder on the server is `health-analyzer`, but
    /// iOS treats `.greg.rawValue == "greg"` as canonical, so without this
    /// alias every Greg reply would be filtered out of ChatView.
    init?(rawValue: String) {
        switch rawValue {
        case "jarvis": self = .jarvis
        case "payne": self = .payne
        case "greg", "health-analyzer": self = .greg
        case "scrooge": self = .scrooge
        case "gordon": self = .gordon
        default: return nil
        }
    }

    /// Compact English title used in the navbar picker so letter-spaced
    /// uppercase fits one line (`J A R V I S`, `M A J   P A Y N E`,
    /// `D R   H O U S E`). Greetings + agent personas still respond in
    /// Russian — this is only the navbar identity.
    var displayName: String {
        switch self {
        case .jarvis: return "Jarvis"
        case .payne:  return "Maj Payne"
        case .greg:   return "Dr House"
        case .scrooge: return "Scrooge"
        case .gordon: return "Ramzi"
        }
    }

    /// Picker accent — desaturated so the agents read as a coherent palette
    /// rather than generic system colors. The original three sit in the teal
    /// value/saturation range (#54BCC5); the later domain agents add warmer,
    /// still-muted accents to stay distinguishable.
    /// - Jarvis: the existing app teal.
    /// - Payne: muted military copper.
    /// - Greg/House: sage green, low-key.
    /// - Scrooge: muted gold.
    /// - Gordon/Ramzi: desaturated tomato, a kitchen nod.
    var accentColor: Color {
        switch self {
        case .jarvis: return Color(red: 0.33, green: 0.74, blue: 0.77)  // teal #54BCC5
        case .payne:  return Color(red: 0.78, green: 0.55, blue: 0.30)  // copper #C68C4D
        case .greg:   return Color(red: 0.45, green: 0.70, blue: 0.62)  // sage #73B39E
        case .scrooge: return Color(red: 0.88, green: 0.72, blue: 0.30)  // muted gold #E0B84C
        case .gordon:  return Color(red: 0.80, green: 0.42, blue: 0.34)  // desaturated tomato #CC6B57
        }
    }

    /// Profession label shown as the dashboard card subtitle (the persona's
    /// trade, not the domain): "Dr House · врач-диагност".
    var profession: String {
        switch self {
        case .jarvis:  return "дворецкий"
        case .payne:   return "тренер"
        case .greg:    return "врач-диагност"
        case .scrooge: return "казначей"
        case .gordon:  return "повар"
        }
    }

    /// SF Symbol for the dashboard card header. All available on iOS 16.0.
    var dashIcon: String {
        switch self {
        case .jarvis:  return "bell.fill"
        case .payne:   return "figure.strengthtraining.traditional"
        case .greg:    return "stethoscope"
        case .scrooge: return "banknote.fill"
        case .gordon:  return "fork.knife"
        }
    }

    /// Curated per-agent starter chips for the home orb satellites and the
    /// empty-chat state. Each agent gets a domain-relevant set rather than the
    /// Jarvis-centric `SuggestionEngine` defaults. Tapping a chip sends `text`
    /// verbatim to the active agent.
    var suggestions: [AgentSuggestion] {
        switch self {
        case .jarvis:
            return [
                AgentSuggestion(text: "Погода",            icon: "cloud.sun"),
                AgentSuggestion(text: "Расписание",        icon: "calendar"),
                AgentSuggestion(text: "Новости",           icon: "newspaper"),
                AgentSuggestion(text: "Итоги дня",         icon: "chart.bar"),
            ]
        case .payne:
            return [
                AgentSuggestion(text: "Начать тренировку", icon: "figure.strengthtraining.traditional"),
                AgentSuggestion(text: "Моя программа",     icon: "list.bullet.clipboard"),
                AgentSuggestion(text: "Прогресс",          icon: "chart.line.uptrend.xyaxis"),
                AgentSuggestion(text: "Замена упражнения", icon: "arrow.triangle.2.circlepath"),
            ]
        case .greg:
            return [
                AgentSuggestion(text: "Как мой сон?",      icon: "bed.double"),
                AgentSuggestion(text: "Готовность сегодня", icon: "bolt.heart"),
                AgentSuggestion(text: "Тренды здоровья",   icon: "waveform.path.ecg"),
                AgentSuggestion(text: "Пульс покоя",       icon: "heart"),
            ]
        case .gordon:
            return [
                AgentSuggestion(text: "Залогировать еду",  icon: "fork.knife"),
                AgentSuggestion(text: "Что съесть?",       icon: "carrot"),
                AgentSuggestion(text: "Белок за день",     icon: "chart.bar.doc.horizontal"),
                AgentSuggestion(text: "Рекомпозиция",      icon: "figure.arms.open"),
            ]
        case .scrooge:
            return [
                AgentSuggestion(text: "Импорт выписки",    icon: "doc.text.magnifyingglass"),
                AgentSuggestion(text: "Траты за месяц",    icon: "creditcard"),
                AgentSuggestion(text: "Категории",         icon: "tag"),
                AgentSuggestion(text: "Отчёт",             icon: "chart.pie"),
            ]
        }
    }
}
