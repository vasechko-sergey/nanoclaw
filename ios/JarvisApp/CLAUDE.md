# JarvisApp — iOS

SwiftUI-чат с агентом Jarvis (NanoClaw на VDS `148.253.211.164`).
Транспорт: WebSocket через Tailscale (`100.94.184.60:3001`). Push через APNs когда WS не подключён.

## Структура

```
ios/JarvisApp/
├── project.yml               # xcodegen — единственный источник истины проекта (PRODUCT_NAME: Jarvis)
├── JarvisApp.xcodeproj       # генерируется: xcodegen generate (из ios/JarvisApp/)
├── Assets.xcassets/
├── JarvisApp.entitlements    # HealthKit entitlement
└── Sources/JarvisApp/        # организовано по слоям (V2-рефактор: мульти-агент + GRDB)
    ├── JarvisApp.swift        # @main + AppDelegate (APNs token → транспорт)
    ├── Protocol/V2.swift      # типы v2-протокола (Envelope + payload-структуры)
    ├── Models/                # AgentIdentity (enum агентов jarvis/payne/greg/scrooge — picker/displayName/accentColor;
    │                          #   rawValue = folder-слаг хоста), ActiveAgentState, AppSettings (@AppStorage),
    │                          #   Message, DraftAttachment, Workout
    ├── Storage/               # ПЕРСИСТЕНТНОСТЬ — GRDB SQLite (см. «Хранилище»)
    │   ├── ConversationStoreV2.swift # стор сообщений; prune(agentId,keep:500)
    │   ├── MessageTimeline.swift     # live-observe GRDB-таймлайна (DatabaseQueue, retention 500)
    │   ├── Schema.swift              # GRDB-миграции (таблицы + индексы)
    │   └── SetLogQueue.swift         # durable GRDB-очередь set_log (тренировки)
    ├── Services/              # транспорт + системные сервисы:
    │   ├── AppV2Bootstrap.swift      # открывает Documents/jarvis-v2.sqlite (DatabaseQueue), поднимает стор/таймлайн
    │   ├── AppCoordinator.swift      # центральный координатор (ws/стор/speech/workout-bus)
    │   ├── WebSocketClientV2 · TransportV2 · URLSessionWebSocket  # WS v2 + reconnect + APNs
    │   ├── InboundDispatcherV2       # входящие envelope → стор/шины
    │   ├── ContextBuilder · LocationManager · HealthManager (+Health*)  # iOS-контекст гео/здоровье
    │   ├── SpeechManager · SpeechSynthesizer · VoiceLoopController       # голос/TTS
    │   └── Workout* · ProactiveDispatcher · ConnectivityMonitor · StatusV2 · WatchConnectivityBridge · …
    ├── Views/                 # ContentView (splash→home/chat), OrbHomeView (домашний орб+picker, приветствие внизу),
    │                          #   ChatView (чат), AgentPickerInline, Settings/Profile/RightDrawer/OrbVoice/FullScreenImage, Workout/*
    ├── Components/            # EmptyStateView (пустой чат), MessageRow, MarkdownText, UnifiedInputBar/InputBar/OrbInputBar,
    │                          #   OrbView/MiniOrbView, HeaderStatusDot, ConnectionBanner, AttachmentBar, CameraPicker, EmojiPicker
    └── Utility/               # Theme (цвета/scaled()), GreetingBank (per-agent приветствия), SuggestionEngine, Log
```

## Цветовая схема (из load.gif)

```swift
bgColor          = Color(red: 0.07, green: 0.11, blue: 0.15)  // #111C26 — фон чата
jarvisBackground = Color(red: 0.09, green: 0.16, blue: 0.22)  // пузырь Джарвиса
userBubble       = Color(red: 0.05, green: 0.22, blue: 0.38)  // пузырь пользователя
teal             = Color(red: 0.33, green: 0.74, blue: 0.77)  // #54BCC5 — акцент
splashBg         = Color(red: 0.06, green: 0.06, blue: 0.06)  // фон сплэша
```

## Протокол WebSocket

Клиент → сервер:
```json
{ "type": "auth", "token": "<IOS_APP_TOKEN>", "platformId": "ios:<UUID>" }
{ "type": "message", "text": "...", "conversationId": "<UUID>", "context": { "location": {...}, "health": {...}, "status": "🏄" } }
{ "type": "new_conversation", "conversationId": "<UUID>" }
{ "type": "feedback", "conversationId": "<UUID>", "messageId": "...", "value": true, "messageText": "<текст оцениваемого ответа>" }
{ "type": "apns_token", "token": "<hex>" }
```

Сервер → клиент:
```json
{ "type": "auth_ok", "commands": [{ "command": "/new", "description": "..." }] }
{ "type": "message", "id": "...", "text": "...", "conversationId": "<UUID>", "timestamp": "..." }
{ "type": "image",   "id": "...", "data": "<base64>", "filename": "...", "conversationId": "<UUID>", "timestamp": "..." }
```

`conversationId` маппится на `thread_id` сессии nanoclaw — каждый диалог = отдельный контейнер агента (изоляция контекста, «новый чат = сброс»). Адаптер: `supportsThreads: true`. `feedback` доставляется агенту как входящее сообщение `[user feedback: 👍/👎 on your previous message]` + цитата `messageText` в сессию диалога — агент опирается на конкретный текст.

iOS-контекст попадает к Джарвису как текстовый блок перед сообщением:
```
[iOS Context — 20 мая 2026, 14:32 MSK] 🏄
📍 Canggu (8.6478, 115.1385)
🏃 Steps: 4 231 | HR: 68 bpm | Active: 312 kcal
---
Текст сообщения
```

## Xcode / сборка

```bash
# Из ios/JarvisApp/ — после добавления новых .swift файлов или изменения project.yml
xcodegen generate

# Team ID: 24Z6S27D7U (Personal Team vasechkoss@gmail.com)
# Bundle ID: com.vasechko.jarvis
# Min iOS: 16.0
```

**Важно:** `JarvisApp.xcodeproj` генерируется из `project.yml`. Никогда не редактировать `.xcodeproj` вручную — изменения потеряются при следующем `xcodegen generate`.

## GIF сплэша

`load.gif` генерируется из `load2.gif` (источник 720×404) скриптом на Python (Pillow):
- Кроп до центрального квадрата 404×404
- Resize до 390×390, размещение на 390×844 canvas
- Gradient fade сверху/снизу (80px feather)
- Floyd-Steinberg dithering для сохранения градиентов
- 23 кадра, 70ms каждый

## Хранилище (GRDB SQLite)

Сообщения и связанные данные — в **`Documents/jarvis-v2.sqlite`** (GRDB), открывается в `Services/AppV2Bootstrap.swift` через `DatabaseQueue`. Старого JSON-кэша (`MessageCache`, `Documents/MessageCache/` с `index.json`+`*.jpg`) **больше НЕТ** — файл удалён.

- **Таблицы** (`Storage/Schema.swift`, миграции): `conversations`, `messages` (`conversation_id`, `ts`, `status`, `created_at`, `agent_id`), `attachments`, `cursors`, `inbound_dedup`, `kv`. Индексы: `idx_msg_conv_ts`, `idx_msg_status`.
- **Стор/наблюдение:** `Storage/ConversationStoreV2.swift` (CRUD) + `Storage/MessageTimeline.swift` (live-observe таймлайна через GRDB `ValueObservation`). UI подписывается на таймлайн активного агента.
- **Retention:** жёсткий cap **`keep: 500` сообщений НА АГЕНТА** (`ConversationStoreV2.prune(agentId:keep:)`) — не 150.
- **Мульти-агент:** строки помечены `agent_id` (jarvis/payne/greg/scrooge); таймлайн фильтруется по активному агенту. `conversationId` ↔ `thread_id` сессии (новый чат = новый контейнер).
- **Очистка чата при дебаге:** удали `Documents/jarvis-v2.sqlite` (НЕ `Documents/MessageCache/` — его не существует).

## Серверная часть

Канальный адаптер: `src/channels/ios-app.ts` в репозитории NanoClaw.
Переменные окружения на VDS (`.env`):
```
IOS_APP_TOKEN=<hex>
IOS_APP_PORT=3001
IOS_APNS_KEY_ID=, IOS_APNS_TEAM_ID=, IOS_APNS_BUNDLE_ID=, IOS_APNS_KEY=  # опционально
```

Health endpoint: `GET http://100.94.184.60:3001/ios/health` → `{"ok":true}`

После изменений в `src/channels/ios-app.ts`:
```bash
pnpm run build && git push
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && bash ~/nanoclaw/start-nanoclaw.sh"'
```
