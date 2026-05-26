# Automated Testing — Spec

**Date:** 2026-05-25
**Scope:** Full-stack automated verification — iOS XCUITest + NanoClaw server vitest extensions
**Trigger:** Manual (`pnpm test:all`) via Claude Code

**Пререквизиты:** `xcodegen` установлен (`brew install xcodegen`), Xcode + iOS Simulator установлены, `ws` в devDeps (уже есть).

---

## Архитектура

Три слоя, один runner:

```
pnpm test:all
  ├── 1. vitest (server unit + ios-app.ts WS/context integration)   ~15s
  ├── 2. start mock-ws-server (port 8765)
  ├── 3. xcodegen generate + xcodebuild test JarvisUITests            ~3-5 мин
  └── 4. kill mock-ws-server, объединить exit codes
```

iOS-приложение при запуске с аргументом `--uitesting` подключается к `ws://localhost:8765` вместо реального VDS. Mock WS server имитирует ios-app.ts канал: auth handshake, message_ack, assistant replies.

---

## Серверные тесты (vitest)

### Уже покрыто

`src/channels/ios-read-receipts.test.ts` — ReadReceiptStore полностью: record delivered/read, getPending, markInjected, hydrate, serialize, лимит 20.

### Новые файлы

**`src/channels/ios-app.ws.test.ts`** — WS-протокол интеграция:

- Поднимает реальный `http.createServer()` + ios-app handler на случайном порту
- Подключается через `ws` WebSocket клиент
- Тест-кейсы:
  - `auth` → `auth_ok`
  - `message` с `clientMessageId` → `message_ack` содержит тот же `clientMessageId`
  - `message_delivered` → запись появляется в ReadReceiptStore
  - `message_read` → `readAt` обновляется в существующей записи
- Teardown: закрывает сервер после каждого теста

**`src/channels/ios-app.context.test.ts`** — context injection:

- Создаёт ReadReceiptStore с несколькими pending записями
- Отправляет `context_request` по WS
- Проверяет что `context_response` содержит блок `[read receipts]` с правильными messageId
- Проверяет что после ответа те же записи `injected=true` → второй `context_request` не дублирует их

Routing до inbound.db не тестируется в unit-тестах — покрывается существующим `src/delivery.test.ts`.

---

## iOS XCUITest

### project.yml — новый таргет

```yaml
JarvisUITests:
  type: bundle.ui-testing
  platform: iOS
  sources: Sources/JarvisUITests
  dependencies:
    - target: JarvisApp
  settings:
    PRODUCT_BUNDLE_IDENTIFIER: com.vasechko.jarvis.uitests
    TEST_TARGET_NAME: JarvisApp
    SWIFT_VERSION: "5.9"
```

### Test mode

В `JarvisApp.swift` или `AppCoordinator.swift`:

```swift
static var isUITesting: Bool {
    ProcessInfo.processInfo.arguments.contains("--uitesting")
}
```

`WebSocketClient` при `isUITesting == true` использует `ws://localhost:8765` вместо реального URL из настроек.

### Accessibility identifiers (минимальный набор)

| Файл | View | Identifier |
|------|------|------------|
| `OrbHomeView.swift` | корневой контейнер | `"orb-home"` |
| `ChatView.swift` | корневой контейнер | `"chat-view"` |
| `OrbInputBar.swift` | текстовое поле | `"message-input"` |
| `OrbInputBar.swift` | кнопка отправки | `"send-btn"` |
| `MessageBubble.swift` | пузырь user role | `"bubble-user-\(message.id)"` |

### Тест-кейсы (`Sources/JarvisUITests/JarvisUITests.swift`)

1. **`testLaunch`** — приложение запускается, `orb-home` существует
2. **`testOrbTapOpensChat`** — tap на орб → `chat-view` появляется
3. **`testSendMessage`** — вводим текст в `message-input`, tap `send-btn` → пузырь с clock иконкой (`.sending`) появляется
4. **`testDeliveryFlow`** — после отправки mock присылает `message_ack` → пузырь переходит в double checkmark (`.delivered`)
5. **`testAssistantReply`** — mock присылает assistant message → пузырь assistant появляется

Симулятор — `iPhone 16, OS latest`. Signing не нужен для симулятора.

---

## Mock WS server

**`scripts/mock-ws-server.ts`** — ~80 строк, запускается через `npx tsx`.

Протокол:

| Входящее | Ответ | Задержка |
|----------|-------|----------|
| `{ type: "auth" }` | `{ type: "auth_ok", pid: "ios:test" }` | сразу |
| `{ type: "message", clientMessageId, content }` | `{ type: "message_ack", clientMessageId }` | сразу |
| то же | `{ type: "message", role: "assistant", content: "Mock: " + content, messageId: uuid }` | +500ms |
| `{ type: "context_request" }` | `{ type: "context_response", context: {} }` | сразу |
| `{ type: "message_delivered" \| "message_read" }` | — (только лог) | — |

SIGTERM → graceful close всех соединений.

Зависимости: только `ws` (уже в devDeps).

---

## Runner

**`scripts/test-all.sh`**:

```bash
#!/usr/bin/env bash
set -e

# 1. Vitest
pnpm test

# 2. Mock WS server
npx tsx scripts/mock-ws-server.ts &
MOCK_PID=$!
trap "kill $MOCK_PID 2>/dev/null; exit" EXIT INT TERM
sleep 1

# 3. xcodegen + xcodebuild
cd ios/JarvisApp
xcodegen generate --quiet
xcodebuild test \
  -project JarvisApp.xcodeproj \
  -scheme JarvisUITests \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -quiet
cd ../..

echo "✓ All tests passed"
```

**`package.json`**:
```json
"test:all": "bash scripts/test-all.sh"
```

---

## Порядок реализации

```
1. src/channels/ios-app.ws.test.ts          [server WS protocol]
2. src/channels/ios-app.context.test.ts     [context injection]
3. scripts/mock-ws-server.ts               [mock server]
4. project.yml — JarvisUITests target      [iOS test target]
5. AppCoordinator — isUITesting flag       [iOS test mode]
6. WebSocketClient — test URL switch       [iOS WS routing]
7. Accessibility identifiers (5 views)     [iOS testability]
8. Sources/JarvisUITests/JarvisUITests.swift [5 test cases]
9. scripts/test-all.sh + package.json      [runner]
```

---

## Риски

| Риск | Вероятность | Решение |
|------|-------------|---------|
| xcodebuild симулятор не найден | средняя | Явно указать `OS=latest`, упасть с понятной ошибкой |
| ios-app.ts трудно изолировать для WS тестов | средняя | Рефакторинг: `export function createIosAppHandler(store: ReadReceiptStore, router: RouterFn)` — принимает store и router как параметры. Тест передаёт mock router (no-op). Основной `src/index.ts` передаёт реальные инстансы. |
| XCUITest async timing flaky | средняя | `waitForExistence(timeout: 5)` на каждый элемент, mock задержка 500ms достаточна |
| `isUITesting` попадает в prod | низкая | Флаг читается из `ProcessInfo.arguments` — в prod запуске аргумент не передаётся |
