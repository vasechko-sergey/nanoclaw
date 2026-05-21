# JarvisApp — iOS

SwiftUI-чат с агентом Jarvis (NanoClaw на VDS `148.253.211.164`).
Транспорт: WebSocket через Tailscale (`100.94.184.60:3001`). Push через APNs когда WS не подключён.

## Структура

```
ios/JarvisApp/
├── project.yml               # xcodegen — единственный источник истины проекта
├── JarvisApp.xcodeproj       # генерируется: xcodegen generate (из ios/JarvisApp/)
├── Assets.xcassets/
├── JarvisApp.entitlements    # HealthKit entitlement
└── Sources/JarvisApp/
    ├── JarvisApp.swift       # @main + AppDelegate (APNs token → WebSocketClient)
    ├── AppSettings.swift     # @AppStorage: serverURL, bearerToken, agentName, useLocation, useHealth, statusEmoji
    ├── Message.swift         # ChatMessage: id, role, content (.text | .image), timestamp
    ├── WebSocketClient.swift # WS + reconnect + APNs token; messages инициализируются из MessageCache.load()
    ├── MessageCache.swift    # Documents/MessageCache/ — index.json + *.jpg; лимит 150 сообщений
    ├── ContextBuilder.swift  # собирает context dict из location/health/statusEmoji
    ├── LocationManager.swift # CLLocationManager, кэш 15 мин, reverseGeocode → cityName
    ├── HealthManager.swift   # HKHealthStore: steps, heartRate, activeEnergyBurned
    ├── ContentView.swift     # splash (GIFView load.gif) → ChatView или SettingsView
    ├── ChatView.swift        # главный экран; emoji-пикер + шестерёнка в тулбаре
    ├── MessageBubble.swift   # .text / .image пузыри + TypingIndicator (SVG-кольцо)
    ├── InputBar.swift        # TextField + кнопка отправки
    ├── SettingsView.swift    # URL, токен, переключатели контекста, Platform ID
    ├── EmojiPickerView.swift # попап со статус-эмодзи (18 штук), .popover из тулбара
    ├── FullScreenImageView.swift # FitScrollView + UIScrollView zoom 1–6x, double-tap
    ├── GIFView.swift         # UIViewRepresentable → UIImageView animatedImage; gifDuration()
    ├── JarvisRingView.swift  # не используется (оставлен)
    └── load.gif              # 390×844 portrait, 23 кадра, ~1.8MB
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
{ "type": "message", "text": "...", "context": { "location": {...}, "health": {...}, "status": "🏄" } }
{ "type": "apns_token", "token": "<hex>" }
```

Сервер → клиент:
```json
{ "type": "auth_ok" }
{ "type": "message", "id": "...", "text": "...", "timestamp": "..." }
{ "type": "image",   "id": "...", "data": "<base64>", "filename": "...", "timestamp": "..." }
```

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

## Кэш сообщений

`MessageCache` сохраняет в `Documents/MessageCache/`:
- `index.json` — массив `CachedMessage` с `.iso8601` датами
- `<msg-id>.jpg` — изображения (JPEG 85%)
- Лимит 150 сообщений, старые JPG автоматически удаляются

`WebSocketClient.messages` инициализируется из кэша при запуске — старые сообщения видны сразу.

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
