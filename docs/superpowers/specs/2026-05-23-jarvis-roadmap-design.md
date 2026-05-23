# Jarvis Roadmap — Spec

**Date:** 2026-05-23  
**Scope:** From current functional state → proactive personal assistant  
**Vision:** Jarvis знает что происходит → инициирует сам, не ждёт вопроса

---

## Контекст и текущее состояние

### Что уже работает

**iOS-приложение (~85% DESIGN_PLAN.md выполнено):**
- OrbMood (8 состояний: heroic, welcoming, listening, processing, speaking, ready, calm, error)
- AppPhase навигация: splash → home → chat
- OrbHomeView с SuggestionEngine (частотный трекинг + time-of-day defaults)
- Орбитальные сателлиты (long press + spring stagger)
- matchedGeometryEffect: орб → клавиатура
- TypingIndicator → MiniOrbView(.processing)
- CalendarManager (EventKit, nextEvent за 18ч) + ContextBuilder (location/health/device/calendar)
- APNs инфраструктура (iOS + сервер) — полностью написана, не настроена
- SettingsView с NavigationStack + секция истории диалогов

**Агент и память (на VDS `root@148.253.211.164`):**
- `memories/self/profile.md` — детальный: карьера, Тбилиси, Лена Турусова, ИП в Грузии, предпочтения, новостные приоритеты, любимые места
- `memories/people/helenalindermann.md` — создана
- `memories/projects/nanoclaw.md` — создана
- wiki-ingest обработал Instagram, Facebook, GitHub, LinkedIn, VK
- Greg (health-analyzer) — 16 дней raw.jsonl, запускается 09:00 UTC, аномалии отслеживает

**Инфраструктура:**
- `schedule_task` с bash-скриптами — работает (Greg доказал)
- a2a между Jarvis и Greg — работает
- HTTP poll для health requests — работает
- WebSocket + offline queue — работает

### Реальные дыры

1. CalendarManager → только `nextEvent` (1 событие). Полный день не виден.
2. Reminders (Apple Reminders) — не подключены вовсе.
3. SuggestionEngine — жёстко включает Серфинг/Бали; Сергей сейчас в Тбилиси.
4. Greg не пишет в `jarvis/memories/self/health.md` — Jarvis не видит недельные тренды.
5. Утренний брифинг-агент — не существует (концепция в CLAUDE.md §2, инфраструктура есть).
6. APNs env vars не выставлены → push-уведомления не работают.
7. Система личных задач — нет ничего (кроме агентского `schedule_task`).
8. Визуальная польша приложения — gradient border бабблов, bg gradient, particles, haptics.

---

## Архитектура — принципы без изменений

Существующие паттерны не меняем, только достраиваем:
- **iOS → агент**: контекст через pull-модель (ContextBuilder → JSON)
- **Headless агенты**: `schedule_task` + bash-скрипт-гейт → Claude только если нужно
- **Память**: wiki-файлы в `memories/`, Jarvis пишет сам, sub-agents для ingest
- **a2a**: Jarvis ↔ Greg через `send_message`

---

## Блок 1 — Cheap Wins (неделя)

Всё технически уже почти готово — доделать.

### 1.1 CalendarManager v2

**Файл:** `Services/CalendarManager.swift`

**Сейчас:** `nextEvent` — одно событие в ближайшие 18ч, только один optional tuple.

**Станет:** 
```swift
@Published var todayEvents: [CalendarEvent] = []
@Published var pendingReminders: [ReminderItem] = []
```

Логика:
- Запрос событий: `now..<endOfDay` по всем календарям (кроме `isAllDay` опционально, настройка)
- Запрос Reminders: `EKReminder` незавершённые с dueDate ≤ завтра, через `requestFullAccessToReminders`
- Обновление: при подключении + при foregrounding + раз в 15 мин

**ContextBuilder** расширяется:
```json
"calendar": {
  "events": [
    {"title": "Standup ANNA Money", "start": "2026-05-23T10:00:00+04:00", "end": "..."},
    {"title": "Обед с Леной", "start": "2026-05-23T13:30:00+04:00", "end": "..."}
  ],
  "reminders": [
    {"title": "Оплатить аренду", "due": "2026-05-23"}
  ]
}
```

**Лимит**: не более 10 событий, не более 5 Reminders — чтобы контекст не раздувался.

### 1.2 SuggestionEngine — геоконтекст

**Файл:** `Utility/SuggestionEngine.swift`

**Сейчас:** time-of-day дефолты жёстко включают «Серфинг» в каталоге.

**Станет:** `suggestions(count:location:)` — принимает опциональный город. Разные дефолтные наборы:

| Город | Набор |
|-------|-------|
| Бали / Canggu / Denpasar | включает «Серфинг», «Прогноз волн» |
| Тбилиси / Tbilisi | «Погода», «Маршрут», «Кафе рядом», «Новости» |
| Другой / неизвестен | нейтральный набор |

OrbHomeView передаёт `location.cityName` при построении suggestions.

### 1.3 Greg → health.md

**Файл:** `groups/health-analyzer/CLAUDE.md` (добавить секцию)

Greg уже работает 16 дней. Нужно добавить задачу: каждое воскресенье 20:00 UTC Greg пишет агрегат за неделю в `handoff/health-weekly.md` (или напрямую в Jarvis через a2a с приложенным markdown).

Формат агрегата (согласно шаблону в `jarvis/memories/self/health.md`):
```markdown
### Неделя 2026-05-17 — 2026-05-23
- Сон: среднее 6.2ч (диапазон 5.7–6.7)
- Шаги: среднее 7527/день
- RHR: среднее 69 bpm
- Активность: 236 мин/неделя
- Сдвиги: HRV упал 22 мая (45→16), восстановился 23-го (52)
```

Jarvis получает a2a-сообщение от Greg → обновляет `memories/self/health.md`.

---

## Блок 2 — Proactive Jarvis (1-2 недели)

### 2.1 APNs Setup

**Что нужно сделать (разово):**
1. Войти на developer.apple.com (бесплатный аккаунт достаточен для sandbox)
2. Создать `.p8` ключ (Keys → + → APNs)
3. Заполнить в `.env` на VDS:
   ```
   IOS_APNS_KEY_ID=<10-char key id>
   IOS_APNS_TEAM_ID=<10-char team id>
   IOS_APNS_BUNDLE_ID=<bundle id приложения>
   IOS_APNS_KEY=<содержимое .p8 файла однострочно>
   IOS_APNS_ENV=sandbox
   ```
4. Перезапустить сервис

**Что уже готово:** JWT-подпись, `sendApnsPush()`, регистрация токена на iOS, deep-link по tap, форвардинг notification при foreground — всё написано. Только конфиг нужен.

**Без APNs — fallback:** Jarvis доставляет через WebSocket когда приложение открыто. Offline-доставка через reconnect queue тоже работает. APNs даёт true background push.

### 2.2 Утренний брифинг-агент

**Паттерн:** Greg, но для брифинга. Headless scheduled task.

**Как работает:**
```
schedule_task(
  cron: "30 4 * * *",  // 08:30 UTC+4 (Tbilisi)
  prompt: "Составь утренний брифинг...",
  script: <проверка: есть ли что-то существенное сегодня>
)
```

Bash-скрипт-гейт проверяет:
- Есть ли события в calendar context на сегодня (из raw.jsonl за сегодня или calendar endpoint)
- Если нет ни событий ни аномалий — `wakeAgent: false`, Jarvis не тревожится

Когда Jarvis просыпается:
1. Читает `memories/self/profile.md` (таймзона, город, контекст)
2. Получает данные: calendar events дня, health state от Greg, любые pending tasks
3. Формирует брифинг в стиле Jarvis: лаконично, по приоритету, без воды
4. Доставляет через `send_message` → iOS получает push

**Формат брифинга (пример):**
```
Доброе утро, сэр. Пятница.

Standup в 10:00. Обед с Леной в 13:30.

Вчера: 7075 шагов, сон 6.2ч — в норме. HRV восстановился после среды.

Больше ничего срочного.
```

Брифинг не отправляется если нечего докладывать (нет событий, нет аномалий, нет задач).

### 2.3 Система личных задач

**Где живут:** `memories/projects/tasks.md` (wiki-файл, Jarvis управляет)

**Структура файла:**
```markdown
# Задачи

## Активные
- [ ] Оплатить аренду — до 25 мая
- [ ] Разобраться с APNs setup

## Выполнено (последние 30 дней)
- [x] Зарегистрировать ИП — 2026-05-19
```

**Интерфейс:** голос/текст через Jarvis
- «Добавь задачу: позвонить врачу до пятницы» → Jarvis пишет в tasks.md
- «Что у меня на сегодня?» → Jarvis читает tasks.md + calendar events
- «Отметь выполненной оплату аренды» → Jarvis обновляет

**CRUD:** Jarvis делает сам через file tools, без sub-agent. Простой формат, читаемый человеком.

**В брифинг:** просроченные задачи и задачи с дедлайном сегодня попадают в утренний брифинг автоматически.

---

## Блок 3 — Визуальная польша (параллельно)

Мелкие UI-улучшения, не блокируют ничего.

### 3.1 Gradient border бабблов ассистента

**Файл:** `Components/MessageBubble.swift`

```swift
.overlay(
    RoundedRectangle(cornerRadius: Theme.bubbleRadius)
        .stroke(
            LinearGradient(
                colors: [Theme.accent.opacity(0.15), Theme.accent.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 0.5
        )
)
```

Убрать `.ultraThinMaterial` в ChatView (367:) — не работает на тёмном фоне.

### 3.2 Radial gradient фон

**Файл:** `Utility/Theme.swift` + `Views/ChatView.swift`, `Views/OrbHomeView.swift`

```swift
static let backgroundGradient = RadialGradient(
    colors: [Color(red: 0.06, green: 0.08, blue: 0.12), background],
    center: .center, startRadius: 50, endRadius: 400
)
```

Subtle — почти незаметно, добавляет глубину.

### 3.3 Particle burst при отправке

**Файл:** `Components/OrbInputBar.swift`

4-6 маленьких Circle (2pt) разлетаются от орба при onSend(), opacity 1→0 за 0.6s. SwiftUI Shape — GPU-нагрузки нет.

### 3.4 Haptics

**Файл:** `Utility/Theme.swift`

```swift
static func hapticMedium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
static func hapticSuccess() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
```

Использовать: `hapticMedium()` при long press орба, `hapticSuccess()` при реконнекте.

### 3.5 Status dot pulse

**Файл:** `Views/ChatView.swift`

Пульсирующий ring вокруг status dot при connected:
```swift
Circle()
    .stroke(Theme.online.opacity(0.2), lineWidth: 1.5)
    .frame(width: 22, height: 22)
    .scaleEffect(statusPulse) // 1.0→1.15→1.0, 2s repeat, .easeInOut
```

---

## Блок 4 — Глубокая память (ongoing, без дедлайна)

Не блокирует ничего. Накапливается органически.

### 4.1 People CRM

Jarvis уже умеет писать в `memories/people/`. Нужно только использовать:
- При упоминании встречи/звонка → Jarvis предлагает зафиксировать
- После разговора о человеке → обновляет досье (последний контакт, контекст)
- Триггер явный: «встретился с X», «созванивался с Y»

Автоматической записи нет — только по триггеру. Иначе слишком агрессивно.

### 4.2 Projects memory

`memories/projects/` — Jarvis предлагает фиксировать решения по проектам. Текущий проект: ANNA Money (новая работа с мая 2026) — логично начать с него.

### 4.3 Pattern recognition

Со временем Jarvis начнёт замечать паттерны из health.md + tasks.md:
- «Вы хуже спите перед важными встречами»
- «Задачи по X обычно зависают на второй неделе»

Не автоматизировать — Jarvis делает это через обычный анализ при разговоре.

---

## Порядок реализации

```
Сейчас (неделя 1):
  - CalendarManager v2 + Reminders     [iOS]
  - SuggestionEngine геоконтекст       [iOS]
  - Greg → health.md weekly write      [VDS agent]

Следом (неделя 2):
  - APNs env vars setup                [VDS config]
  - Утренний брифинг-агент             [VDS agent]

Параллельно:
  - Визуальная польша (любой порядок)  [iOS]

После:
  - Система задач tasks.md             [VDS agent + iOS voice]
  - People CRM activation              [ongoing]
```

---

## Что не трогаем

- Архитектура NanoClaw (host, router, delivery, sessions) — стабильна
- WebSocketClient, AppCoordinator — без изменений  
- Greg's core logic (`analyze.js`, `state.md` dedup) — только добавляем weekly write
- OrbView, OrbMood, OrbInputBar — завершены
- wiki-ingest / wiki-lint sub-agents — работают
- `schedule_task` / a2a механизм — не меняем

---

## Риски

| Риск | Вероятность | Решение |
|------|-------------|---------|
| Apple Developer APNs setup сложный | средняя | Fallback: WebSocket delivery работает. APNs — enhancement, не блокер. |
| Reminders access permission | низкая | `requestFullAccessToReminders` отдельно от Events; если отказ — деградация до Events only |
| Брифинг-агент будит зря (нет данных) | средняя | Bash-скрипт-гейт + `wakeAgent: false` по умолчанию |
| CalendarManager раздувает контекст | низкая | Лимит 10 событий + 5 Reminders жёстко |
| Greg a2a latency при weekly write | низкая | Async write, не блокирует прогон |
