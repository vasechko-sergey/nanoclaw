# JarvisApp — iOS

SwiftUI-чат с агентом Jarvis (NanoClaw на VDS `148.253.211.164`).
Транспорт: WebSocket на `wss://jarvis.vasechko.dev` (nginx+TLS на VDS → `127.0.0.1:3001`). URL захардкожен в `Utility/ServerConfig.swift` — НЕ редактируется в UI (поле убрано из Settings + онбординга); в настройках остаётся только токен. `ServerConfig.swift` — единственный endpoint (Tailscale-фолбэка в коде НЕТ). Проактивные уведомления тянутся pull'ом (`GET /ios/pending`); APNs-кода в приложении НЕТ (ни `registerForRemoteNotifications`, ни `aps-environment` entitlement).

## Структура

```
ios/JarvisApp/
├── project.yml               # xcodegen — единственный источник истины проекта (PRODUCT_NAME: Jarvis)
├── JarvisApp.xcodeproj       # генерируется: xcodegen generate (из ios/JarvisApp/)
├── Assets.xcassets/
├── JarvisApp.entitlements    # HealthKit entitlement
└── Sources/JarvisApp/        # организовано по слоям (V2-рефактор: мульти-агент + GRDB)
    ├── JarvisApp.swift        # @main + AppDelegate (lifecycle; НЕ регистрирует APNs — push-кода нет)
    ├── Protocol/V2.swift      # типы v2-протокола (Envelope + payload-структуры)
    ├── Models/                # AgentIdentity (enum агентов jarvis/payne/greg/scrooge/gordon — picker/displayName/accentColor;
    │                          #   rawValue = folder-слаг хоста), ActiveAgentState, AppSettings (@AppStorage),
    │                          #   Message, DraftAttachment, Workout
    ├── Storage/               # ПЕРСИСТЕНТНОСТЬ — GRDB SQLite (см. «Хранилище»)
    │   ├── ConversationStoreV2.swift # стор сообщений; prune(keep:500) — глобальный, без agentId
    │   ├── Schema.swift              # GRDB-миграции (таблицы + индексы)
    │   └── SetLogQueue.swift         # durable GRDB-очередь set_log (тренировки)
    ├── Services/              # транспорт + системные сервисы:
    │   ├── AppV2Bootstrap.swift      # открывает Documents/jarvis-v2.sqlite (DatabaseQueue), поднимает стор
    │   ├── AppCoordinator.swift      # центральный координатор (ws/стор/speech/workout-bus)
    │   ├── WebSocketClientV2 · TransportV2 · URLSessionWebSocket  # WS v2 + reconnect + durable outbox
    │   ├── InboundDispatcherV2       # входящие envelope → стор/шины
    │   ├── ContextBuilder · LocationManager · HealthManager (+Health*)  # iOS-контекст гео/здоровье
    │   ├── SpeechManager · SpeechSynthesizer · VoiceLoopController       # голос/TTS
    │   └── Workout* · ProactiveDispatcher · ConnectivityMonitor · StatusV2 · WatchConnectivityBridge · …
    ├── Views/                 # ContentView (splash→home/chat), OrbHomeView (домашний орб+picker, приветствие внизу),
    │                          #   ChatView (чат), Settings/Profile/RightDrawer/OrbVoice/FullScreenImage, Workout/*
    ├── Components/            # EmptyStateView (пустой чат), MessageRow, MarkdownText, UnifiedInputBar, CommandList,
    │                          #   OrbView/MiniOrbView, HeaderStatusDot, ConnectionBanner, AttachmentBar, CameraPicker, EmojiPicker
    └── Utility/               # Theme (цвета/scaled()), GreetingBank (per-agent приветствия), SuggestionEngine, Log
```

## Цветовая схема

Источник истины — `Utility/Theme.swift` (`Theme.background`, `Theme.accent` ≈ teal `#54BCC5`, `Theme.surface`, `Theme.textPrimary`, `Theme.online/offline`, …; плюс размеры через `Theme.scaled()`). Per-agent акцент picker'а — в `AgentIdentity.accentColor` (jarvis — teal, payne — copper, greg — sage, scrooge — gold). (Раньше цвета «выводились из load.gif» — этого ассета больше нет.)

## Протокол WebSocket (v2 envelopes)

Wire-формат — **envelope-based v2**. Каноническая схема: `shared/ios-app-protocol/v2.ts` (TS), Swift-зеркало: `Sources/JarvisApp/Protocol/V2.swift`, закреплено fixture-контракт-тестами. Старый плоский v1-JSON (`{type:"auth"/"message"/"image"}` с `conversationId` в корне) больше НЕ используется.

Envelope несёт `type` (дискриминатор), `kind` ∈ `data|control|ack|status`, и payload-union. Основные `type`:
- **auth / auth_ok / auth_fail** — рукопожатие (token + platformId; `auth_ok` несёт список commands).
- **message** — текст + (опц.) attachments + ios-context; помечен `agent_id` (какому агенту) + `thread_id`.
- **new_conversation** — сброс треда.
- **context_request / context_response** — pull iOS-контекста (гео/здоровье) по запросу агента.
- **action_response / feedback** — нажатие inline-кнопки / 👍👎.
- **ack / delivered / read / ping / pong** — доставка, статусы прочтения, keepalive.
- **workout_* · exercise_swap_* · set_log · coach_message · program_update · image_request · image_blob** — workout-флоу (Payne) + картинки.

Семантика: `thread_id` (он же conversationId) = тред сессии nanoclaw — новый чат = отдельный контейнер агента (изоляция «новый чат = сброс»). `agent_id` = folder-слаг агента (роутинг к нужному агенту/сессии — см. `AgentIdentity`). `feedback` доставляется агенту как `[user feedback: 👍/👎 …]` + цитата текста оцениваемого ответа.

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
# Bundle ID: dev.vasechko.jarvis
# Min iOS: 18.0  (project.yml:5 — deployment target)
```

**Важно:** `JarvisApp.xcodeproj` генерируется из `project.yml`. Никогда не редактировать `.xcodeproj` вручную — изменения потеряются при следующем `xcodegen generate`.

## Сплэш

`SplashView` в `Views/ContentView.swift` (НЕ GIF — `load.gif`/`GIFView` удалены). Анимированный `OrbView` + титул «J A R V I S» + статус-строка. Фазы коннекта: `loading → connecting → ready` (→ home) / `failed` (кнопки «Повторить» / «Продолжить автономно») / `waitingSetup` (inline setup-карта: сервер URL + токен). Таймаут коннекта 10с. App-фазы: `splash → home (OrbHomeView) → chat (ChatView)`, opacity/transition-driven (чат всегда смонтирован).

## Хранилище (GRDB SQLite)

Сообщения и связанные данные — в **`Documents/jarvis-v2.sqlite`** (GRDB), открывается в `Services/AppV2Bootstrap.swift` через `DatabaseQueue`. Старого JSON-кэша (`MessageCache`, `Documents/MessageCache/` с `index.json`+`*.jpg`) **больше НЕТ** — файл удалён.

- **Таблицы** (`Storage/Schema.swift`, миграции v1–v6): `messages` (`conversation_id`, `ts`, `status`, `created_at`, `agent_id`, `failure_reason`, `seq`), `cursors`, `inbound_dedup`. (`conversations`+`kv` дропнуты в v3, `attachments` — в v6.) Индексы: `idx_msg_ts`, `idx_msg_status`.
- **Стор/наблюдение:** `Storage/ConversationStoreV2.swift` (CRUD). UI читает `WebSocketClientV2.messages` — наблюдение через GRDB `ValueObservation` внутри `WebSocketClientV2.restartObservation`, фильтр по активному агенту в ChatView.
- **Retention:** жёсткий cap **`keep: 500`** (`ConversationStoreV2.prune(keep:)` — ГЛОБАЛЬНЫЙ, не per-agent; сигнатура без `agentId`).
- **Мульти-агент:** строки помечены `agent_id` (jarvis/payne/greg/scrooge/gordon); список фильтруется по активному агенту в ChatView. `conversationId` ↔ `thread_id` сессии (новый чат = новый контейнер).
- **Очистка чата при дебаге:** удали `Documents/jarvis-v2.sqlite` (НЕ `Documents/MessageCache/` — его не существует).

## Серверная часть

Канальный адаптер: `src/channels/ios-app/v2/` в репозитории NanoClaw (главный файл `index.ts`; v1 `ios-app.ts` удалён).
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
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw"'
```
