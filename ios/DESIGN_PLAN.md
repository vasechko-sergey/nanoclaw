# Jarvis Soul — План реализации

> Цель: превратить технически хорошее приложение в живое, с характером.
> Каждый пункт — конкретный файл, конкретное изменение.

---

## Фаза 0: Орб как хаб — философия навигации

Сейчас приложение сразу открывает ChatView с активным диалогом. Орб — просто кнопка ввода внизу. Но если орб — сердце Jarvis, он должен быть **центром навигации**.

### 0.1 Орб-экран вместо чата при запуске

**Файлы:** `Views/ContentView.swift`, новый `Views/OrbHomeView.swift`

**Что сейчас:** `ContentView` → splash → `ChatView` (всегда в чат).

**Что делаем:** После splash открывается **OrbHomeView** — экран с крупным орбом в центре, приветствием и контекстными подсказками. Это «домашний экран» Jarvis.

```swift
enum AppPhase {
    case splash, home, chat
}
```

**OrbHomeView** содержит:
- Крупный орб (mood: .welcoming) в центре
- Контекстное приветствие по времени суток
- Suggestion chips (как в текущем EmptyStateView)
- **При long press** орба — сателлиты, один из которых **«Продолжить диалог»** (bubble.left.and.bubble.right), если есть активный диалог

**Сателлиты на орб-экране (по кругу при long press):**

| Позиция | Иконка | Действие |
|---------|--------|----------|
| Top | `mic.fill` / `keyboard` | Голосовой ввод / клавиатура → открыть новый чат |
| Right | `camera` | Камера → новый чат с фото |
| Bottom-Right | `photo` | Фото → новый чат с фото |
| Bottom-Left | `doc` | Документ → новый чат с файлом |
| Left | `bubble.left.and.bubble.right` | Продолжить активный диалог (если есть) |

Сателлит «Продолжить диалог» — **появляется только если есть активный диалог**. У него accent border + мини-badge с preview последнего сообщения.

**Навигация из OrbHomeView:**
- Тап по орбу → начать голосовой ввод (или keyboard, по настройке) → переход в ChatView
- Тап по suggestion chip → отправить в новый чат → ChatView
- Тап по сателлиту «Продолжить диалог» → ChatView с активным диалогом
- ⚙ в header → настройки (sheet)

**Навигация из ChatView обратно:**
- Тап по «J A R V I S» в header → возврат на OrbHomeView (свайп тоже вариант)
- ⚙ в header → настройки (sheet)

**Header — два режима:**
На обоих экранах header одинаковый по структуре: `[●статус]  J A R V I S  [⚙]`, но:
- На OrbHomeView: «JARVIS» — декоративный, не кликабельный
- На ChatView: «JARVIS» — кнопка «домой» (можно добавить subtle chevron.left или underline как hint)

**Переход OrbHomeView → ChatView:**
Орб анимируется вниз экрана, становясь input bar орбом. `matchedGeometryEffect` между крупным орбом home и маленьким орбом input bar.

**Переход ChatView → OrbHomeView:**
Кнопка «домой» (или свайп?) возвращает на орб-экран. Орб из input bar увеличивается обратно.

**По сути:** EmptyStateView сейчас делает часть этой работы, но он внутри ChatView. OrbHomeView — это promoted EmptyStateView на уровень navigation.

### 0.2 Список диалогов → в настройки

**Файл:** `Views/SettingsView.swift`, `Views/ChatView.swift`, `Views/ConversationListView.swift`

**Что сейчас:** Тап по «JARVIS» в header ChatView открывает ConversationListView как sheet. Header содержит три точки входа: профиль, диалоги, настройки.

**Что делаем:**

1. **Убираем** ConversationListView из ChatView header.

2. **Добавляем** секцию «История диалогов» в SettingsView:

```swift
// В SettingsView, после секции «Подключение»:
settingsSection(title: "История") {
    NavigationLink {
        ConversationListView(store: store, onAction: handleAction)
    } label: {
        settingsField(icon: "bubble.left.and.bubble.right", label: "Диалоги") {
            HStack(spacing: Theme.scaled(4)) {
                Text("\(store.conversations.count)")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.accentMedium)
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.scaled(11)))
                    .foregroundStyle(Theme.accentMedium)
            }
        }
    }
}
```

3. **SettingsView** оборачивается в `NavigationStack` (если ещё нет), чтобы push-навигация работала.

4. **Header ChatView** упрощается:
   - Слева: ●статус → профиль
   - Центр: «J A R V I S» → возврат на OrbHomeView
   - Справа: ⚙ → настройки

5. **ConversationListView** остаётся как есть по UI, но теперь живёт внутри настроек как pushed view, а не как sheet.

**Почему это хорошо:**
- Header чище — только 2 действия вместо 3
- Диалоги — это «архив», не primary action, логично в настройках
- «JARVIS» освобождается для навигации домой

### 0.3 Настройка: скрыть кнопку клавиатуры

**Файл:** `Models/AppSettings.swift`

```swift
@AppStorage("showKeyboardShortcut") var showKeyboardShortcut = true
```

**Файл:** `Views/SettingsView.swift` (секция «Ввод»)

```swift
settingsToggle(icon: "keyboard", label: "Быстрый доступ к клавиатуре",
               subtitle: "Кнопка рядом с орбом. Выключи для чистого экрана",
               isOn: $settings.showKeyboardShortcut)
```

**Файл:** `Components/OrbInputBar.swift`

Когда `showKeyboardShortcut == false`:
- В режиме орба (resting state) — только чистый орб, без кнопки клавиатуры рядом
- Доступ к клавиатуре: через long press сателлит или двойной тап по орбу
- В режиме compose (клавиатура уже открыта) — ничего не меняется

```swift
// В orbCluster:
if settings.showKeyboardShortcut {
    // маленькая иконка клавиатуры слева от орба
    keyboardShortcutButton
}
centralOrb
```

Результат: пользователь может получить абсолютно чистый экран — только орб и ничего больше.

### 0.4 Связка splash → home → chat

**Файл:** `Views/ContentView.swift`

```swift
var body: some View {
    ZStack {
        // Chat underneath (always ready)
        ChatView(coordinator: coordinator)
            .opacity(appPhase == .chat ? 1 : 0)

        // Home screen
        if appPhase == .home {
            OrbHomeView(coordinator: coordinator, onEnterChat: {
                withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
                    appPhase = .chat
                }
            })
            .transition(.opacity)
            .zIndex(1)
        }

        // Splash overlay
        if appPhase == .splash {
            SplashView(... onReady: {
                withAnimation(.easeOut(duration: 0.6)) {
                    appPhase = .home  // ← вместо .chat
                }
            })
            .transition(.opacity)
            .zIndex(2)
        }
    }
}
```

---

## Фаза 1: Орб с душой

Орб — сердце приложения. Сейчас это красивая геометрия без эмоций. Нужно дать ему настроение.

### 1.1 OrbView v2 — единый компонент с настроениями

**Файл:** `Components/OrbView.swift` (полная переработка, ~150 строк)

**Что сейчас:** 5 концентрических кругов, 3 анимации (pulse 3s, rotation 8s, innerPulse 2s). Два параметра: `size` и `brightness`. Используется одинаково везде.

**Что делаем:**

Вводим `OrbMood` enum, который управляет всей визуальной динамикой:

```swift
enum OrbMood {
    case heroic      // Splash — большой, яркий, медленный ripple
    case welcoming   // Empty state — мягкий, приглашающий
    case ready       // Input bar — отзывчивый, ждёт действия
    case listening   // Запись голоса — быстрый пульс, expanding ripple
    case processing  // Jarvis думает — ускоренное вращение колец
    case speaking    // Озвучка — звуковые волны от ядра
    case calm        // Профиль — минимальное движение, тихий
    case error       // Ошибка — тусклый, замедленный
}
```

**Визуальные слои нового орба (ZStack снизу вверх):**

1. **Ambient glow** — `RadialGradient` от accent к transparent, scaleEffect по mood
2. **Outer orbit ring** — dashed circle, opacity по mood
3. **Primary ring** — `trim(from: 0, to: 0.45)` + AngularGradient + rotation. Скорость: heroic=10s, ready=6s, listening=3s, processing=2s
4. **Secondary ring** — counter-rotation, другой trim. Скорость зависит от mood
5. **Particle dots** — 1-3 маленьких circle на орбитах, вращаются вместе с кольцами, filter=glow. Количество: heroic=2, ready=1, listening=2, processing=3
6. **Inner glow** — пульсирующий filled circle
7. **Core** — яркая точка с glow-тенью, пульсация по mood

**Параметры, управляемые mood:**

| Параметр | heroic | welcoming | ready | listening | processing | speaking | calm | error |
|----------|--------|-----------|-------|-----------|------------|----------|------|-------|
| Ring speed | 10s | 12s | 6s | 3s | 2s | 8s | 15s | 20s |
| Ring2 speed | 15s | 18s | 9s | 4s | 1.5s | 12s | 22s | 30s |
| Core pulse | 2.5s | 3s | 2s | 1s | 0.8s | 0.6s | 4s | 5s |
| Particles | 2 | 1 | 1 | 2 | 3 | 1 | 0 | 0 |
| Ripple | да, 3s | нет | нет | да, 1.5s | нет | да, волны | нет | нет |
| Brightness | 1.0 | 0.85 | 0.75 | 1.0 | 0.9 | 1.0 | 0.5 | 0.25 |
| Glow radius | 60% | 50% | 40% | 55% | 45% | 50% | 35% | 20% |

**Ripple (для listening и heroic):**
```swift
Circle()
    .stroke(Theme.accent, lineWidth: 1)
    .frame(width: rippleSize, height: rippleSize)
    .scaleEffect(rippleScale)  // 1.0 → 2.5
    .opacity(2.0 - rippleScale) // затухает
```

**Speaking waves (для speaking):**
Два-три концентрических круга с offset-анимацией, расходящиеся от ядра как звуковые волны.

**Анимации — через `.onChange(of: mood)`:**
При смене mood все animation-параметры пересчитываются с `withAnimation(.easeInOut(duration: 0.5))` — плавный переход между состояниями.

**Обратная совместимость:**
Оставляем `init(size:brightness:)` как convenience, маппящий brightness на mood:
- brightness >= 0.9 → .welcoming
- brightness >= 0.5 → .calm
- brightness < 0.5 → .error

Новый primary init: `init(size: CGFloat = 120, mood: OrbMood = .welcoming)`

---

### 1.2 OrbInputBar — сателлиты по орбите + long press

**Файл:** `Components/OrbInputBar.swift` (переработка orbCluster + centralOrb, ~80 строк изменений)

**Что сейчас:** Сателлиты в HStack сверху от орба, всегда видны. Орб — кнопка.

**Что делаем:**

**Убираем** HStack с сателлитами из `orbCluster`. Вместо этого:

1. **Рест:** Только центральный орб (mood: .ready). Чисто, минимально.

2. **Long press:** `LongPressGesture(minimumDuration: 0.3)` → сателлиты вылетают по кругу вокруг орба.

```swift
// Раскладка по кругу
let satellites = ["keyboard", "camera", "photo", "doc", "slash.circle"]
let radius: CGFloat = Theme.scaled(70)

ForEach(0..<satellites.count, id: \.self) { i in
    let angle = -(.pi / 2) + (2 * .pi / Double(satellites.count)) * Double(i)
    let x = cos(angle) * radius
    let y = sin(angle) * radius

    SatelliteOrb(icon: satellites[i], ...)
        .offset(x: showSatellites ? x : 0, y: showSatellites ? y : 0)
        .scaleEffect(showSatellites ? 1.0 : 0.3)
        .opacity(showSatellites ? 1.0 : 0)
        .animation(
            .spring(duration: 0.4, bounce: 0.25)
            .delay(Double(i) * 0.06),  // stagger
            value: showSatellites
        )
}
```

3. **Жест-система:**
   - Tap → основное действие (голос или отправка, как сейчас)
   - Long press (0.3s) → `showSatellites = true` + haptic .medium
   - Tap сателлита → действие + `showSatellites = false`
   - Tap вне → `showSatellites = false`
   - Drag от орба к сателлиту (будущая фича, пока не делаем)

4. **Visual feedback:** При long press орб слегка увеличивается (scaleEffect 1.05) и mood переключается на .heroic — «раскрывается».

5. **SatelliteOrb обновление:** Добавить мягкий glow при появлении:
```swift
.shadow(color: Theme.accent.opacity(showSatellites ? 0.3 : 0), radius: 8)
```

6. **Кнопка клавиатуры — опциональная (см. 0.2):**
   Маленькая subtle-иконка клавиатуры слева от орба — видна по умолчанию, но скрывается настройкой `showKeyboardShortcut`. Когда скрыта, доступ к клавиатуре — через long press сателлит или двойной тап.

---

### 1.3 Morph-переход орб → клавиатура

**Файл:** `Components/OrbInputBar.swift` (переработка transition между orbCluster и composeRow)

**Что сейчас:** `if showKeyboard { composeRow } else { orbCluster }` — резкая смена.

**Что делаем:**

Используем `matchedGeometryEffect` чтобы орб «раскрывался» в текстовое поле:

```swift
@Namespace private var orbTransition

// В orbCluster:
OrbView(size: Theme.scaled(84), mood: orbMood)
    .matchedGeometryEffect(id: "orbInput", in: orbTransition)

// В composeRow:
TextField(...)
    .matchedGeometryEffect(id: "orbInput", in: orbTransition)
```

Орб визуально трансформируется в поле ввода. При collapse — обратно.

Fallback если matchedGeometryEffect глючит: `.transition(.scale(scale: 0.5, anchor: .center).combined(with: .opacity))` с duration 0.3s.

---

### 1.4 Обновление всех потребителей OrbView

**Файлы и изменения:**

| Файл | Строка | Сейчас | Станет |
|------|--------|--------|--------|
| `ContentView.swift` | 72 | `OrbView(size: 140, brightness: orbBrightness)` | `OrbView(size: 140, mood: orbMood)` — mood вычисляется из phase |
| `ContentView.swift` | 107-109 | `orbBrightness = 1.0` при connected | `orbMood = .heroic` |
| `ContentView.swift` | 118-119 | `orbBrightness = 0.3` при failed | `orbMood = .error` |
| `EmptyStateView.swift` | 14 | `OrbView(size: orbSize, brightness: 0.8)` | `OrbView(size: orbSize, mood: .welcoming)` |
| `ProfileView.swift` | 53 | `OrbView(size: 100, brightness: isConnected ? 1.0 : 0.3)` | `OrbView(size: 100, mood: isConnected ? .calm : .error)` |
| `SettingsView.swift` | 47 | `OrbView(size: 80, brightness: 0.6)` | `OrbView(size: 80, mood: .calm)` |
| `OrbInputBar.swift` | 113 | `OrbView(size: 84, brightness: isRecording ? 1.0 : 0.7)` | `OrbView(size: 84, mood: currentOrbMood)` — вычисляется из состояния |

**Mapping состояний в OrbInputBar:**
```swift
private var currentOrbMood: OrbMood {
    if speech.isRecording { return .listening }
    if ws.isTyping { return .processing }  // нужно прокинуть
    return .ready
}
```

---

### 1.5 Состояния орба при записи (вместо текущего listenPulse)

**Файл:** `Components/OrbInputBar.swift` (удаление listenPulse, делегирование в OrbView)

**Что сейчас:** `centralOrb` рисует свой отдельный expanding circle поверх OrbView при записи.

**Что делаем:** Убираем `listenPulse`, `Circle().stroke().scaleEffect(listenPulse)` — весь визуал записи уходит в `OrbView(mood: .listening)`. OrbInputBar просто передаёт mood.

---

## Фаза 2: Голос и контекст

### 2.1 Голос бренда — переписать все UI-строки

**Принцип:** Jarvis — вежливый, спокойный, чуть-чуть с характером. Не робот, не клоун.

**Файл: `ContentView.swift` (SplashView, statusText)**

| Строка | Сейчас | Станет |
|--------|--------|--------|
| 132 | `"инициализация..."` | `"просыпаюсь..."` |
| 135 | `"подключение..."` | `"ищу связь..."` |
| 138 | `"системы активны"` | `"на связи"` |
| 141 | `"необходима настройка"` | `"нужно познакомиться"` |
| 144 | `"ошибка подключения"` | `"не удалось связаться"` |
| 163 | `"Повторить"` (кнопка) | `"Попробовать снова"` |
| 175 | `"Продолжить оффлайн"` | `"Пока без связи"` |

**Файл: `ConnectionBanner.swift`**

| Строка | Сейчас | Станет |
|--------|--------|--------|
| 15 | `"Нет подключения"` | `"Потерял связь..."` |
| 24 | `"Подключено"` | `"Вернулся!"` |
| 63 | `"Повторить"` (кнопка) | `"Попробовать"` |

**Файл: `EmptyStateView.swift`**

| Строка | Сейчас | Станет |
|--------|--------|--------|
| 17 | `"Чем могу помочь?"` | Контекстное приветствие (см. 2.2) |

**Файл: `SettingsView.swift`**

| Строка | Сейчас | Станет |
|--------|--------|--------|
| 49 | `"Настройка"` | `"Знакомство"` |
| 53 | `"Укажи параметры подключения"` | `"Расскажи, как тебя найти"` |

**Файл: `ProfileView.swift`**

| Строка | Сейчас | Станет |
|--------|--------|--------|
| 37 | `"Профиль"` | `"О нас"` (Jarvis + пользователь) |

---

### 2.2 Контекстные подсказки по времени суток

**Файл:** `Components/EmptyStateView.swift` (переработка)

**Что сейчас:** Статический массив `["Погода", "Расписание", "Новости", "Напомни"]` и фиксированный `"Чем могу помочь?"`.

**Что делаем:**

```swift
private var greeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 5..<12:  return "Доброе утро"
    case 12..<17: return "Добрый день"
    case 17..<22: return "Добрый вечер"
    default:      return "Не спится?"
    }
}

private var suggestions: [String] {
    let hour = Calendar.current.component(.hour, from: Date())
    let weekday = Calendar.current.component(.weekday, from: Date())

    switch hour {
    case 5..<10:
        return ["Что на сегодня?", "Погода", "Новости утра", "Напомни"]
    case 10..<13:
        return ["Резюмируй переписку", "Найди информацию", "Напомни", "Идеи"]
    case 13..<17:
        return ["Что осталось на день?", "Помоги с текстом", "Переведи", "Посчитай"]
    case 17..<22:
        if weekday == 6 { // пятница
            return ["Планы на выходные?", "Подведи итоги", "Что посмотреть?", "Рецепт"]
        }
        return ["Подведи итоги дня", "Что посмотреть?", "Рецепт на ужин", "Расслабься"]
    default:
        return ["Расскажи что-нибудь", "Помоги уснуть", "Случайный факт", "Тихая музыка"]
    }
}
```

---

### 2.3 Настройки — объяснения для каждой опции

**Файл:** `Views/SettingsView.swift`

Добавляем `subtitle` в `settingsToggle` и `settingsField`:

```swift
// Было:
settingsToggle(icon: "location", label: "Геолокация", isOn: $settings.useLocation)

// Стало:
settingsToggle(icon: "location", label: "Геолокация",
               subtitle: "Подскажу кафе рядом и погоду за окном",
               isOn: $settings.useLocation)
```

**Тексты подписей:**

| Опция | Подпись |
|-------|--------|
| Геолокация | `"Подскажу кафе рядом и погоду за окном"` |
| Здоровье | `"Буду в курсе шагов, сна и активности"` |
| Календарь | `"Напомню о встречах и помогу планировать"` |
| Отправка по Enter | `"Shift+Enter для новой строки"` |
| Режим ввода | `"Орб — с голосом, Классика — только текст"` |
| Тап по орбу | `"Что делает первый тап по орбу"` |
| Озвучивать ответы | `"Автоматически проговаривать голосовые"` |

Добавить новый helper `settingsToggle(icon:label:subtitle:isOn:)` с опциональным subtitle мелким шрифтом под label.

---

### 2.4 ConnectionBanner — промежуточное состояние

**Файл:** `Components/ConnectionBanner.swift`

Добавляем состояние `reconnecting`:

```swift
@State private var isReconnecting = false

// При нажатии "Попробовать":
isReconnecting = true
onReconnect()

// При восстановлении:
isReconnecting = false

// Текст меняется:
if isReconnecting {
    "Ищу связь..."  // + subtle spinner или пульсирующая точка
} else {
    "Потерял связь..."
}
```

---

## Фаза 3: Визуальная глубина

### 3.1 Фон с глубиной

**Файл:** `Utility/Theme.swift` + `Views/ChatView.swift`

**Что сейчас:** Плоский `#0A0E14` везде.

**Что делаем:**

Добавляем в Theme:
```swift
static let backgroundGradient = RadialGradient(
    colors: [
        Color(red: 0.06, green: 0.08, blue: 0.12),  // чуть светлее в центре
        background
    ],
    center: .center,
    startRadius: 50,
    endRadius: 400
)
```

Применяем в EmptyStateView (за орбом) и ChatView (как фон). Subtle, почти незаметный, но добавляет глубину.

---

### 3.2 Бабблы с глубиной

**Файл:** `Components/MessageBubble.swift`

**Ассистент-бабблы:**
```swift
// Было:
.background(Theme.assistantBubble)

// Стало:
.background(.ultraThinMaterial)
.environment(\.colorScheme, .dark)
```

**Border:**
```swift
// Было:
.stroke(Theme.assistantBubbleBorder, lineWidth: 0.5)

// Стало:
.stroke(
    LinearGradient(
        colors: [Theme.accent.opacity(0.15), Theme.accent.opacity(0.05)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    ),
    lineWidth: 0.5
)
```

User-бабблы оставляем как есть — они уже выделяются цветом.

---

### 3.3 Micro-interactions

**Файл:** `Components/OrbInputBar.swift` + `Views/ChatView.swift`

1. **Send — particle burst:** При `onSend()` кратковременно показываем 4-6 маленьких circles, разлетающихся от орба. Через 0.5s исчезают.

```swift
@State private var showSendParticles = false

// В tapOrb(), перед onSend():
showSendParticles = true
DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    showSendParticles = false
}
```

2. **Receive — orb pulse:** Когда приходит ответ, орб кратковременно ярче (mood boost). Уже есть `hapticReceive()`, добавляем визуальное подтверждение.

3. **Typing — orb реагирует:** Когда `ws.isTyping == true`, орб в input bar переходит в `.processing` — видно что Jarvis думает.

---

### 3.4 Профиль — тепло

**Файл:** `Views/ProfileView.swift`

1. **Статистика с фреймингом:**
```swift
// Было: "47" + "Диалогов"
// Стало:
private var conversationLabel: String {
    let count = store.conversations.count
    if count == 0 { return "Пока ни одного" }
    if count < 5  { return "Начало положено" }
    if count < 20 { return "Общаемся!" }
    return "Много историй"
}
```
Значение остаётся числом, но label становится тёплым.

2. **memberSince — в человечный формат:**
```swift
// Было: "23 дн. назад"
// Стало: "3 недели вместе" или "с 1 мая"
```

3. **Stat cards — разные accent-оттенки:** Первый card — основной accent, второй — accentMedium подсветка, третий — тёплый.

---

### 3.5 Список диалогов — живость

**Файл:** `Views/ConversationListView.swift`

1. **Активный чат:** Добавить слабый left border accent + чуть заметный glow:
```swift
.overlay(alignment: .leading) {
    if isActive {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(width: 2)
            .padding(.vertical, Theme.scaled(8))
    }
}
```

2. **Формат времени:**
```swift
// Было: "15:37"
// Стало:
private func formattedDate(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "только что" }
    if interval < 3600 { return "\(Int(interval / 60)) мин. назад" }
    // далее как было
}
```

3. **«Ничего не найдено»** → `"Не нашёл такого... попробуй другие слова"` (строка 151)

---

## Фаза 4: Полировка

### 4.1 Header — живой статус

**Файл:** `Views/ChatView.swift` (header)

Пульсирующий ring вокруг status dot при connected:
```swift
Circle()
    .stroke(Theme.online.opacity(0.2), lineWidth: 1.5)
    .frame(width: 22, height: 22)
    .scaleEffect(statusPulse)  // 1.0 → 1.15 → 1.0, 2s repeat
```

### 4.2 TypingIndicator — связь с орбом

**Файл:** `Components/MessageBubble.swift` (TypingIndicator)

Заменяем текущий TypingIndicator на мини-OrbView:
```swift
OrbView(size: Theme.scaled(28), mood: .processing)
```
Единый визуальный язык — орб = Jarvis, везде.

### 4.3 Haptics — обогащение

**Файл:** `Utility/Theme.swift`

```swift
// Добавляем:
static func hapticSuccess()  { UINotificationFeedbackGenerator().notificationOccurred(.success) }
static func hapticMedium()   { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
```

Используем: hapticMedium при long press, hapticSuccess при реконнекте.

---

## Порядок работы

```
 1. OrbView v2 (mood enum + визуал)              → фундамент, всё зависит от этого
 2. Обновить потребителей OrbView                 → splash, profile, settings
 3. OrbInputBar (сателлиты по кругу)              → long press + spring stagger
 4. OrbInputBar (morph → клавиатура)              → matchedGeometryEffect
 5. AppSettings (showKeyboardShortcut)             → новый флаг
 6. OrbInputBar (скрытие кнопки клавиатуры)       → зависит от 5
 7. OrbHomeView (орб-хаб, сателлиты, chips)       → зависит от 1, 3
 8. ContentView (splash → home → chat навигация)  → зависит от 7
 9. SettingsView (секция «История диалогов»)      → перенос ConversationListView
10. ChatView header (упрощение, «JARVIS» → home)  → зависит от 8, 9
11. Удалить EmptyStateView (заменён OrbHomeView)  → после 7, 8
12. Голос бренда (все строки UI)                  → параллельно с 3-11
13. OrbHomeView контекстные подсказки             → после 12
14. Настройки (подписи-объяснения)                → после 12
15. ConnectionBanner (промежуточные состояния)    → после 12
16. Бабблы (glassmorphism + gradient border)      → независимо
17. Фон с глубиной (radial gradient)              → независимо
18. Micro-interactions (particles, glow)           → после 1-3
19. Профиль (тепло) + список диалогов (живость)   → независимо
20. TypingIndicator → мини-орб                    → после 1
21. Header pulse + haptics                        → мелочи, в конце
```

**Ключевые решения:**
- EmptyStateView **удаляется** — OrbHomeView полностью заменяет его. В ChatView мы попадаем только когда уже есть диалог.
- ConversationListView **переезжает** из ChatView header в SettingsView как pushed NavigationLink.
- ChatView header **упрощается** до трёх элементов: ●статус → профиль, «JARVIS» → домой, ⚙ → настройки.

---

## Что НЕ трогаем

- Архитектура (Services, Models) — не трогаем
- WebSocketClient, AppCoordinator — без изменений
- InputBar (классический режим) — оставляем как есть
- MarkdownText — работает, не трогаем
- CameraPicker, AttachmentBar — оставляем
- Все модели данных — без изменений

---

## Риски — анализ и решения

### R1: matchedGeometryEffect — ВЫСОКИЙ → устранён

**Проблема:** matchedGeometryEffect ненадёжен между разными уровнями View-иерархии. В проекте нет ни одного использования — значит нет опыта отладки.

**Где планировалось:** (a) орб→клавиатура в OrbInputBar, (b) OrbHome→ChatView.

**Решение:**
- **(a) OrbInputBar** — `matchedGeometryEffect` ИСПОЛЬЗУЕМ. Орб и TextField в одном View, один `@Namespace` — это надёжный стандартный кейс. Если глючит — fallback: `.transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))` с duration 0.3s.
- **(b) OrbHome→ChatView** — `matchedGeometryEffect` НЕ ИСПОЛЬЗУЕМ. Вместо этого:

```swift
// OrbHomeView:
.transition(.asymmetric(
    insertion: .opacity.combined(with: .scale(scale: 1.05)),
    removal: .opacity.combined(with: .scale(scale: 0.92))
))

// ChatView появление через opacity (уже в ZStack, всегда рендерится)
```

Визуально: home «сжимается», чат «проявляется». Простая, надёжная анимация.

---

### R2: Particles GPU — НИЗКИЙ → устранён

**Проблема:** анимированные частицы могут нагружать GPU.

**Реальность:** OrbView v2 содержит 1-3 `Circle()` размером 2-4pt с `opacity` анимацией. Send particles — 4-6 `Circle()` на 0.6s. Это SwiftUI Shape, не Metal/SpriteKit. Для сравнения: одна тень (`.shadow()`) дороже чем все наши частицы вместе.

**Решение:** Не нужно. Если профайлер на старом устройстве покажет проблемы — добавляем `.drawingGroup()` на OrbView (растрирует в Metal texture, убирает compositing overhead). Но не ожидаю.

---

### R3: .ultraThinMaterial на тёмном фоне — СРЕДНИЙ → решён заменой

**Проблема:** На `#0A0E14` фоне `.ultraThinMaterial` даёт почти незаметный frost. Material работает через backdrop blur, но если контент под бабблом — тот же тёмный фон, эффект минимален. Разница видна только при scroll контента под элементом.

**Решение:** НЕ ИСПОЛЬЗУЕМ `.ultraThinMaterial` для бабблов. Вместо этого:

```swift
// Ассистент-бабблы — solid color + gradient border:
.background(Theme.assistantBubble)  // оставляем как есть
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

Gradient border даёт ощущение «стекла» без зависимости от backdrop. Предсказуемо, работает одинаково на всех фонах.

---

### R4: LongPressGesture конфликт со scroll — НИЗКИЙ → устранён архитектурно

**Проблема:** LongPressGesture может конфликтовать со scroll gesture.

**Реальность:** OrbInputBar и OrbHomeView — оба ВНЕ ScrollView. Единственный ScrollView — чат (сообщения), но орб под ним, не внутри. `LongPressGesture(minimumDuration: 0.3)` на `Button` вне scroll — стандартный паттерн iOS, работает без проблем.

**Решение:** Не нужно. Риск не существует.

---

### R5: OrbHome→Chat transition — ВЫСОКИЙ → поглощён R1

**Проблема:** Как анимировать переход между экранами?

**Решение:** Отказались от matchedGeometryEffect (см. R1b). ContentView использует ZStack, ChatView всегда рендерится с `opacity(appPhase == .chat ? 1 : 0)` — state сохраняется. OrbHomeView показывается условно с transition. Простая, проверенная архитектура — уже работает так для splash.

---

### R6: Удаление EmptyStateView — edge cases — СРЕДНИЙ → решён

**Проблема:** Если OrbHomeView заменяет EmptyStateView, что показывать при пустом ChatView?

**Edge cases:**
1. Первый запуск без настроек → splash → setup card → home. **ОК** — EmptyStateView не нужен.
2. Пользователь начал чат с home, но сообщения ещё не пришли → ChatView пуст на мгновение. **Решение:** показать loading state (typing indicator), так как отправка = мгновенное появление user bubble.
3. Тап «JARVIS» в чате → возврат на home. Все сообщения остаются в ChatView (opacity=0). **ОК.**
4. Новый чат из OrbHome → сразу отправляем сообщение → ChatView не может быть пустым.

**Решение:** EmptyStateView упрощается до fallback-заглушки (мини-орб + «начни разговор»), но в нормальном flow никогда не показывается. Можно удалить позже, когда убедимся что все пути ведут через OrbHome. На первом этапе — оставляем как safety net.

```swift
// ChatView:
if visibleMessages.isEmpty && !ws.isTyping {
    // Safety fallback — в нормальном flow не должен показываться
    VStack {
        OrbView(size: Theme.scaled(60), mood: .welcoming)
        Text("Начни разговор")
            .font(.system(size: Theme.fontCaption))
            .foregroundStyle(Theme.accentMedium)
    }
}
```

---

### R7: Трёхступенчатая навигация — СРЕДНИЙ → решён

**Проблема:** splash → home → chat — пользователь может запутаться.

**Решение — чёткие правила:**

1. **Splash → Home:** Автоматический, пользователь не контролирует. Как у всех приложений.
2. **Home → Chat:** Любое действие (тап орб, chip, сателлит) → в чат. Направление ясное: «я начал разговор».
3. **Chat → Home:** ТОЛЬКО тап по «J A R V I S» в header. Не свайп (конфликтует с scroll и системными жестами). Текст слегка подчёркнут как hint что это кнопка.
4. **State preservation:** ChatView в ZStack с opacity — state, scroll position, все сообщения сохраняются. Возврат на home ≠ потеря данных.
5. **SettingsView:** Оборачиваем в `NavigationStack` для push к ConversationListView. Sheet закрывается стандартным свайпом вниз.

**Ментальная модель для пользователя:** Home = «рабочий стол Jarvis». Chat = «разговор». Настройки = sheet поверх чего угодно.

---

### R8 (новый): SettingsView + NavigationStack — НИЗКИЙ

**Проблема:** SettingsView сейчас показывается как sheet без NavigationStack. Для push ConversationListView нужен NavigationStack.

**Решение:** Обернуть содержимое SettingsView в `NavigationStack`:

```swift
// SettingsView body:
NavigationStack {
    VStack(spacing: 0) {
        // header (кастомный, остаётся)
        ScrollView { ... }
    }
    .navigationBarHidden(true)
}
```

NavigationStack доступен с iOS 16 — наш minimum deployment target. Риск нулевой.
