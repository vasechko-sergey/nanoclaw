# Jarvis iOS — План редизайна

> Стиль: «Apple meets Jarvis» — пульсирующий орб, тонкие glow-границы,
> монохромный teal (#54BEC4), максимум воздуха.
> Старые чаты — только на чтение. Новый чат = сброс контекста.

---

## Выполненные этапы (v1.0 — Фундамент + Дизайн)

### Этап 1 — Фундамент ✅
- `Theme.swift` — единые дизайн-токены с адаптивным масштабированием (scale factor от ширины экрана)
- `Conversation.swift` — модель диалога (id, title, dates, preview, messageCount, isPinned)
- `ConversationStore.swift` — менеджер с per-conversation storage + миграция из legacy формата
- `MessageCache.swift` — рефакторинг под параметризованные директории
- `WebSocketClient.swift` — добавлен conversationId, new_conversation, onMessagesChanged

### Этап 2 — Splash Screen ✅
- `OrbView.swift` — переиспользуемый пульсирующий орб (splash, empty state, profile, settings)
- `SplashView` — нативная двухфазная анимация (loading → connecting → системы активны)
- Удалён `GIFView.swift`

### Этап 3 — Empty State ✅
- `EmptyStateView.swift` — орб + «Чем могу помочь?» + 4 suggestion chips
- ViewThatFits для адаптивного переноса чипсов на узких экранах

### Этап 4 — Обновлённый Chat ✅
- Кастомный header: статус-точка с кольцом → JARVIS → emoji + gear
- MessageBubble: Theme-токены, markdown для ассистента, адаптивные отступы
- InputBar: адаптивные размеры, "/" команды, enter-to-send
- Haptic feedback: send (light), receive (soft), error (notification)

### Этап 5 — Навигация ✅
- `ConversationListView` — группировка по датам, поиск, context menu, удаление с подтверждением
- `ArchivedChatView` — read-only, dimmed messages, «Новый чат на эту тему»
- ChatView: .newChat, .newChatWithContext, .open actions

### Этап 6 — Настройки + Профиль ✅
- `SettingsView` — полный рестайл: тёмный фон, кастомные секции, иконки, setup-орб, версия
- `ProfileView` — орб-аватар, статус, кнопка переподключения, 3 stat-карточки, connection info

### Этап 7 — Polish (v1) ✅
- MarkdownText — **bold**, *italic*, `code`, [links], ```code blocks``` с кнопкой «Копировать»
- Анимации: spring-scroll, asymmetric message transitions, scale+offset
- EmojiPickerView — тёмная тема, accent-подсветка
- FullScreenImageView — Theme-стиль

### Адаптивность ✅
- Scale factor 0.92–1.15 от ширины экрана (база 390pt)
- Проверено: iPhone 12 mini (375pt) → Pro Max (430pt)
- Min-cap на шрифтах, 44pt tap targets (Apple HIG)

### Архитектурный рефакторинг ✅
- Структура папок: Models/ Services/ Views/ Components/ Utility/
- `AppCoordinator` — центральный координатор, владеет всеми сервисами
- ChatView облегчён — только UI, вся логика в координаторе
- WebSocketClient чист от UI-зависимостей (Theme.haptic → callback)
- Splash flow: коннект при загрузке или inline-setup → коннект → чат

---

## Выполненные этапы (v1.1 — UX Спринты)

### Sprint 1 — Критичное UX ✅

**1.1 Context menu на сообщениях ✅**
- Long press на текстовом пузыре → «Копировать» (UIPasteboard) + «Поделиться» (ShareLink)
- Long press на изображении → «Копировать» + «Сохранить в фото» (UIImageWriteToSavedPhotosAlbum)
- Haptic feedback при действии

**1.2 Баннер обрыва соединения + retry ✅**
- Новый компонент `ConnectionBanner.swift`
- При `isConnected == false`: slide-down баннер с wifi.slash + «Нет подключения» + кнопка «Повторить»
- InputBar блокируется (dim + disabled через `isDisabled` параметр)
- При восстановлении: зелёный баннер «Подключено» автоматически исчезает через 2с
- Spring-анимации появления/исчезновения

**1.3 Splash: обработка ошибок коннекта ✅**
- Убраны оба 4с fallback (из startAnimation и из кнопки «Подключиться»)
- Новый SplashPhase: `.failed` с красным текстом «ошибка подключения»
- Таймаут 10с через DispatchWorkItem (отменяемый при успешном коннекте)
- Кнопки: «Повторить» (accent capsule) и «Продолжить оффлайн» (subtle)
- Орб тускнеет до brightness 0.3, haptic error при ошибке

**1.4 Базовые VoiceOver labels ✅**
- Header: статус-точка («Статус: подключено/отключено. Профиль»), «Диалоги», «Статус-эмодзи», «Настройки»
- MessageBubble: `.accessibilityElement(children: .combine)` с «Роль: текст. Время»
- TypingIndicator: «Jarvis печатает»
- InputBar: «Команды», «Поле ввода сообщения», «Отправить»
- Timestamp скрыт от VoiceOver (`.accessibilityHidden(true)`)

### Sprint 2 — Важное UX ✅

**2.1 Scroll-to-bottom FAB ✅**
- Компактная capsule-кнопка (chevron.down + badge) в правом нижнем углу чата
- Отслеживание скролла через GeometryReader + PreferenceKey (`ScrollOffsetKey`)
- Кнопка вынесена в ZStack вне ScrollViewReader — реагирует даже во время инерционной прокрутки
- `.onTapGesture` вместо Button для надёжного перехвата касаний
- Невидимый padding для 44pt tap area при визуально компактном размере
- Badge с количеством новых сообщений (lastSeenCount фиксируется при начале скролла вверх)

**2.2 Enter-to-send ✅**
- `.onSubmit` на TextField → отправка сообщения
- `.submitLabel(.send)` — кнопка «Send» на клавиатуре
- Настройка `enterToSend` в AppSettings (@AppStorage)
- Переключатель в SettingsView → секция «Ввод» → «Отправка по Enter»

**2.3 Улучшенные код-блоки ✅**
- Полностью переписан `MarkdownText.swift` — парсинг ``` блоков через NSRegularExpression
- `CodeBlockView`: тёмный фон (black 0.35), monospace шрифт, горизонтальный ScrollView
- Метка языка (если указан) в header код-блока
- Capsule-кнопка «Копировать» → UIPasteboard + анимированный feedback «Скопировано» (1.5с)
- `.textSelection(.enabled)` на коде

**2.4 Кнопка Reconnect ✅**
- ProfileView: кнопка «Переподключиться» / «Подключиться» через callback `onReconnect`
- Логика: disconnect → 0.3с delay → connect
- Иконка меняется: arrow.triangle.2.circlepath (online) / bolt.horizontal (offline)

**2.5 Дата-разделители ✅**
- Компонент `DateSeparator` — центрированная capsule между сообщениями разных дней
- «Сегодня», «Вчера», или «15 мая» (DateFormatter с ru_RU locale)
- Стиль: Theme.accent opacity 0.06 фон, 0.5 текст

**2.6 Визуальный hint для статус-точки ✅**
- Добавлено полупрозрачное кольцо (stroke 1.5pt) вокруг точки статуса
- Online: Theme.online opacity 0.2, Offline: Theme.offline opacity 0.15
- Очевидно что элемент кликабельный

**2.7 Dismiss клавиатуры ✅**
- `.scrollDismissesKeyboard(.interactively)` на ScrollView чата
- Клавиатура плавно уезжает при скролле вниз (паттерн мессенджеров)

### Sprint 3 — Polish ✅

**3.1 Унификация языка UI ✅**
- Все английские строки на splash заменены на русские:
  - "initializing systems..." → "инициализация..."
  - "connecting to server..." → "подключение..."
  - "systems online" → "системы активны"
  - "connection failed" → "ошибка подключения"
  - "configuration required" → "необходима настройка"
- "Platform ID" → "ID платформы" (SettingsView), "Платформа" (ProfileView)

**3.2 Feedback-кнопки на ответы ассистента ✅**
- 👍/👎 иконки (hand.thumbsup/hand.thumbsdown) рядом с timestamp на сообщениях ассистента
- Состояния: none (opacity 0.2), positive (accent, fill), negative (offline, fill)
- Callback `onFeedback: ((String, Bool) -> Void)?` для отправки на сервер
- Анимация переключения (.easeOut 0.15s)

**3.3 Swipe actions в списке диалогов ✅**
- Свайп влево: красная «Удалить» (с подтверждением через alert)
- Свайп вправо: accent «Закрепить» / «Открепить» (full swipe)
- `isPinned` поле в Conversation модели с backwards-compatible `init(from:)` (decodeIfPresent)
- Закреплённые диалоги группируются в секцию «Закреплённые» наверху списка
- Иконка pin.fill рядом с заголовком закреплённого диалога
- `togglePin(_:)` в ConversationStore
- Pin/Unpin также доступен через context menu

**3.4 About / Версия ✅**
- Секция «О приложении» в SettingsView (только в режиме настроек, не initial setup)
- «Jarvis» + «Версия X.Y (build)» из Bundle.main.infoDictionary
- Иконка info.circle

---

## Текущая архитектура

```
Sources/JarvisApp/
├── JarvisApp.swift                 ← App entry, AppDelegate (APNs)
├── Models/
│   ├── AppSettings.swift           ← @AppStorage settings (+ enterToSend)
│   ├── Conversation.swift          ← Conversation model (+ isPinned, backwards-compat decoding)
│   ├── ConversationAction.swift    ← Navigation actions enum
│   └── Message.swift               ← ChatMessage model
├── Services/
│   ├── AppCoordinator.swift        ← Центральный координатор
│   ├── WebSocketClient.swift       ← WS коннектор (UI-free)
│   ├── ConversationStore.swift     ← Persistence диалогов (+ togglePin)
│   ├── MessageCache.swift          ← Persistence сообщений
│   ├── LocationManager.swift       ← CoreLocation
│   └── HealthManager.swift         ← HealthKit
├── Views/
│   ├── ContentView.swift           ← Root + SplashView (+ error handling, timeout)
│   ├── ChatView.swift              ← Чат (+ scroll FAB, date separators, connection banner)
│   ├── SettingsView.swift          ← Настройки (+ enter-to-send, about/version)
│   ├── ProfileView.swift           ← Профиль (+ reconnect button)
│   ├── ConversationListView.swift  ← Список (+ swipe actions, pinning)
│   ├── ArchivedChatView.swift      ← Read-only чат
│   └── FullScreenImageView.swift   ← Просмотр изображений
├── Components/
│   ├── OrbView.swift               ← Пульсирующий орб
│   ├── MessageBubble.swift         ← Пузырь + context menu + feedback + TypingIndicator
│   ├── InputBar.swift              ← Поле ввода + команды + enter-to-send + disabled state
│   ├── ConnectionBanner.swift      ← Баннер «Нет подключения» / «Подключено»
│   ├── EmptyStateView.swift        ← Пустой чат
│   ├── EmojiPickerView.swift       ← Выбор эмодзи
│   └── MarkdownText.swift          ← Markdown + код-блоки с копированием
└── Utility/
    ├── Theme.swift                 ← Дизайн-токены + адаптивный scale
    └── ContextBuilder.swift        ← Сборка контекста (geo, health, emoji)
```

---

## Метрики успеха

| Метрика | До v1.1 | После v1.1 |
|---------|---------|------------|
| Копирование сообщений | ❌ | ✅ context menu + share |
| Обработка ошибок соединения | ❌ | ✅ баннер + retry + splash errors |
| VoiceOver | ❌ | ✅ базовые labels на всех элементах |
| Scroll-to-bottom | ❌ | ✅ FAB с badge |
| Enter-to-send | ❌ | ✅ + настройка |
| Код-блоки с copy | ❌ | ✅ + метка языка |
| Reconnect | ❌ | ✅ в профиле |
| Дата-разделители | ❌ | ✅ Сегодня/Вчера/дата |
| Dismiss клавиатуры | ❌ | ✅ scroll dismiss |
| Единый язык UI | Смешанный | ✅ Русский |
| Feedback на ответы | ❌ | ✅ 👍/👎 |
| Swipe actions + pinning | ❌ | ✅ удаление + закрепление |
| About / Версия | ❌ | ✅ в настройках |

---

## Нереализованные улучшения (Backlog)

**Средний приоритет:**
- Dynamic Type поддержка (масштабирование от preferredContentSizeCategory)
- Streaming-анимация (посимвольный вывод, требует серверной поддержки)
- Reduce Motion поддержка
- Фото loading/error placeholder

**Низкий приоритет:**
- Light Mode
- Onboarding-тур при первом входе
- Экспорт/очистка чатов
- Подсветка синтаксиса в код-блоках (highlight.js)
