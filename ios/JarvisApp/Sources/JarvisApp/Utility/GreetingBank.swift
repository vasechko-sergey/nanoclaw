import Foundation

/// Per-agent home-screen greetings keyed by time of day. Random pick on each
/// access — keeps the orb screen alive instead of one fixed phrase per slot.
enum TimeSlot { case morning, day, evening, night }

enum GreetingBank {
    static func pick(agent: AgentIdentity, slot: TimeSlot) -> String {
        let bank = phrases(agent: agent, slot: slot)
        return bank.randomElement() ?? "Здравствуйте"
    }

    private static func phrases(agent: AgentIdentity, slot: TimeSlot) -> [String] {
        switch agent {
        case .jarvis:
            switch slot {
            case .morning: return [
                "Доброе утро, сэр",
                "С добрым утром, сэр",
                "Утро доброе. Чем могу помочь, сэр?",
                "Доброе утро. Рад снова видеть вас",
            ]
            case .day: return [
                "Добрый день, сэр",
                "Чем могу служить, сэр?",
                "К вашим услугам, сэр",
            ]
            case .evening: return [
                "Добрый вечер, сэр",
                "Вечер добрый. Чем занимаемся?",
                "Готов к вечерним поручениям, сэр",
            ]
            case .night: return [
                "Доброй ночи, сэр",
                "Поздний час. Что-то срочное, сэр?",
                "Не спится, сэр?",
            ]
            }

        case .payne:
            switch slot {
            case .morning: return [
                "Подъём, солдат!",
                "Доброе утро? Нет такого. Есть утро. Тренируемся?",
                "Шесть утра — самое время потеть",
                "Готов работать, новобранец?",
            ]
            case .day: return [
                "Так-так-так. День в разгаре, солдат",
                "Готов к работе?",
                "Время не ждёт, солдат",
            ]
            case .evening: return [
                "Вечерняя смена, солдат",
                "Один подход до отбоя?",
                "Думаешь день закончился? Ошибаешься",
            ]
            case .night: return [
                "Ночью спят слабаки",
                "Что не спится, солдат?",
                "Тренировка по расписанию или будем оправдываться?",
            ]
            }

        case .greg:
            switch slot {
            case .morning: return [
                "Доброе утро? Это оксюморон",
                "О, ты ещё жив. Уже плюс",
                "Утро. Кофе. Что болит?",
                "Что, опять симптомы?",
            ]
            case .day: return [
                "Все врут. Ну, что у нас?",
                "Если ты пришёл — значит что-то не так",
                "Дай угадаю. Ты в порядке. Конечно",
            ]
            case .evening: return [
                "Вечер. Самое время признаться, что весь день болит",
                "Что, день был тяжёлый? Невероятно",
                "Ладно, давай по симптомам",
            ]
            case .night: return [
                "Ночью люди приходят с интересными проблемами",
                "Не спишь? Это уже симптом",
                "Полночь. Что-то болит?",
            ]
            }
        }
    }
}
