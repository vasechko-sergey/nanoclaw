# Lock-screen Reply + Per-agent Notification Controls — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user reply to an agent from the lock-screen notification, and silence individual agents or a nightly quiet-hours window — both built on the existing no-APNs local-notification rail.

**Architecture:** A new host `POST /ios/reply` routes a lock-screen reply as a genuine user message via the existing `adapterRouteToAgent` (suspend-safe HTTP, no WS). On iOS, `LocalNotifier` stamps every agent notification with a reply text-action + `userInfo`; `AppDelegate.didReceive` posts the typed reply via `NotificationReplySender`. Per-agent mute + quiet hours are pure on-device gates added to `LocalNotifier.raise`.

**Tech Stack:** Host — Node + TypeScript + vitest (`src/channels/ios-app/v2/`). iOS — Swift + SwiftUI + GRDB + `UserNotifications`, scheme `JarvisApp`, test target `JarvisAppTests`, module `Jarvis`, XCTest.

**Reference spec:** `docs/superpowers/specs/2026-06-30-lockscreen-reply-and-notif-controls-design.md`

---

## File Structure

**Host (create):**
- `src/channels/ios-app/v2/reply-endpoint.test.ts` — tests for `POST /ios/reply`.

**Host (modify):**
- `src/channels/ios-app/v2/index.ts` — extract `routeChatToAgent` helper; add `routeReply` closure; pass `routeReply` + `defaultAgentSlug` into `createIosHttpHandler`.
- `src/channels/ios-app/v2/http-handler.ts` — add `routeReply` + `defaultAgentSlug` to `HttpHandlerDeps`; add `POST /ios/reply` route + route-inventory comment.
- `src/channels/ios-app/v2/http-routes.test.ts` — add `routeReply`/`defaultAgentSlug` to the harness deps (tsc).
- `src/channels/ios-app/v2/image-endpoint.test.ts` — same harness-deps fix (tsc).

**iOS (create):**
- `Sources/JarvisApp/Services/NotificationCategories.swift` — `agent-message` category + reply action factory + `register()`.
- `Sources/JarvisApp/Services/NotificationReplySender.swift` — `NotificationReplySender` + `ReplyRequest.build`.
- `Sources/JarvisApp/Models/NotificationGating.swift` — `QuietHours.contains` + `MutedAgents` encode/decode (pure).
- `Sources/JarvisAppTests/NotificationCategoriesTests.swift`
- `Sources/JarvisAppTests/NotificationReplySenderTests.swift`
- `Sources/JarvisAppTests/NotificationGatingTests.swift`

**iOS (modify):**
- `Sources/JarvisApp/Services/LocalNotifier.swift` — category + userInfo on content; `isMuted`/`inQuietHours` gates.
- `Sources/JarvisApp/JarvisApp.swift` — register category in `didFinishLaunching`; handle `reply` in `didReceive`.
- `Sources/JarvisApp/Services/AppCoordinator.swift` — `NotificationReplySender.shared.configure(store:)`.
- `Sources/JarvisApp/Storage/ConversationStoreV2.swift` — `insertOutboundUserMessage` gains a `status` param.
- `Sources/JarvisApp/Utility/ServerConfig.swift` — `httpBase()` helper.
- `Sources/JarvisApp/Models/AppSettings.swift` — mute set + quiet-hours storage + helpers.
- `Sources/JarvisApp/Views/SettingsView.swift` — dedicated "Уведомления" section.
- `Sources/JarvisAppTests/LocalNotifierTests.swift` — assert category/userInfo; add mute + quiet-hours suppression tests.
- `ios/JarvisApp/project.yml` — version bump 71 / 1.17.0.

---

## Task 1: Host — extract `routeChatToAgent` helper (pure refactor)

**Files:**
- Modify: `src/channels/ios-app/v2/index.ts`

This is a no-behavior-change refactor; the existing ios-app-v2 suite is the safety net. It factors the inbound-build so Task 2's `routeReply` reuses one routing path.

- [ ] **Step 1: Add the module-level helper.** In `src/channels/ios-app/v2/index.ts`, near `resolveSessionForPlatform` (module scope), add:

```ts
/** Build a `chat` inbound message and route it to a specific agent group.
 *  Single routing path shared by the WS dispatcher and the HTTP reply endpoint. */
function routeChatToAgent(input: {
  platform_id: string;
  agentId: string;
  threadId: string | null;
  id: string;
  text: string;
  context?: unknown;
  attachments?: unknown[];
  timestamp?: string;
}): void {
  void adapterRouteToAgent(
    {
      channelType: CHANNEL_TYPE,
      platformId: input.platform_id,
      threadId: input.threadId,
      message: {
        id: input.id,
        kind: 'chat',
        content: JSON.stringify({
          text: input.text,
          senderId: input.platform_id,
          ios_context: input.context ?? null,
          attachments: input.attachments ?? [],
        }),
        timestamp: input.timestamp ?? new Date().toISOString(),
      },
    },
    input.agentId,
  ).catch((err) => logV2Warn('routeChatToAgent threw', { err: String(err), agent_group_id: input.agentId }));
}
```

- [ ] **Step 2: Refactor the dispatcher's `routeToAgent` to call it.** Replace the existing `routeToAgent: ({ platform_id, agent_group_id, envelope }) => { void adapterRouteToAgent(...).catch(...) }` callback (the inline block at ~line 270) with:

```ts
    routeToAgent: ({ platform_id, agent_group_id, envelope }) =>
      routeChatToAgent({
        platform_id,
        agentId: agent_group_id,
        threadId: envelope.payload.thread_id ?? null,
        id: envelope.id,
        text: envelope.payload.text ?? '',
        context: envelope.payload.context ?? null,
        attachments: envelope.payload.attachments ?? [],
        timestamp: envelope.ts ?? undefined,
      }),
```

- [ ] **Step 3: Run the ios-app-v2 suite — must stay green.**

Run: `pnpm test -- src/channels/ios-app/v2/`
Expected: PASS (same count as before; `agent-routing.test.ts`, `inbound-dispatch.test.ts`, `integration.test.ts` exercise this path).

- [ ] **Step 4: Commit.**

```bash
git add src/channels/ios-app/v2/index.ts
git commit -m "refactor(ios-v2): extract routeChatToAgent shared routing helper"
```

---

## Task 2: Host — `POST /ios/reply` endpoint

**Files:**
- Create: `src/channels/ios-app/v2/reply-endpoint.test.ts`
- Modify: `src/channels/ios-app/v2/http-handler.ts`, `src/channels/ios-app/v2/index.ts`, `src/channels/ios-app/v2/http-routes.test.ts`, `src/channels/ios-app/v2/image-endpoint.test.ts`

- [ ] **Step 1: Write the failing test.** Create `src/channels/ios-app/v2/reply-endpoint.test.ts`:

```ts
// Unit tests for POST /ios/reply — the lock-screen reply endpoint. Mounts the
// bare createIosHttpHandler on a stub server with a routeReply spy; identity is
// the token's platform_id (tok-p2 → ios-app-v2:p2), never body.platformId.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { createIosHttpHandler } from './http-handler.js';
import type { HealthRequestsStore } from './health-requests-store.js';

const TOKEN = 'tok-p2';
const PLATFORM_ID = 'ios-app-v2:p2';

interface ReplyCall { platform_id: string; agentId: string; text: string }

async function boot() {
  const calls: ReplyCall[] = [];
  const handler = createIosHttpHandler({
    resolveToken: (raw) => (raw === TOKEN ? { platform_id: PLATFORM_ID, person_key: 'p2' } : null),
    healthRequestsStore: {} as unknown as HealthRequestsStore,
    healthAgentFolder: 'greg',
    getChannelSetup: () => null,
    listPending: () => [],
    defaultAgentSlug: 'jarvis',
    routeReply: (platform_id, agentId, text) => calls.push({ platform_id, agentId, text }),
    log: () => {},
    logWarn: () => {},
  });
  const server = http.createServer(handler);
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  return {
    url: `http://127.0.0.1:${port}`,
    calls,
    close: () => new Promise<void>((r) => server.close(() => r())),
  };
}

function post(url: string, body: string, token?: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (token) headers.Authorization = `Bearer ${token}`;
    const req = http.request(
      { method: 'POST', hostname: u.hostname, port: u.port, path: u.pathname, headers },
      (res) => {
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (raw += c));
        res.on('end', () => resolve({ status: res.statusCode ?? 0, body: raw }));
      },
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

let h: Awaited<ReturnType<typeof boot>>;
beforeEach(async () => { h = await boot(); });
afterEach(async () => { await h.close(); });

describe('POST /ios/reply', () => {
  it('401 without auth, routeReply not called', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ text: 'hi' }));
    expect(r.status).toBe(401);
    expect(h.calls).toHaveLength(0);
  });

  it('routes text to the named agent', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ text: 'hello', agent_id: 'greg' }), TOKEN);
    expect(r.status).toBe(200);
    expect(h.calls).toEqual([{ platform_id: PLATFORM_ID, agentId: 'greg', text: 'hello' }]);
  });

  it('defaults agent_id to jarvis', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ text: 'hi' }), TOKEN);
    expect(r.status).toBe(200);
    expect(h.calls[0].agentId).toBe('jarvis');
  });

  it('400 on empty text, routeReply not called', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ text: '   ' }), TOKEN);
    expect(r.status).toBe(400);
    expect(h.calls).toHaveLength(0);
  });

  it('400 on missing text', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ agent_id: 'greg' }), TOKEN);
    expect(r.status).toBe(400);
  });

  it('400 on over-cap text', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ text: 'x'.repeat(5000) }), TOKEN);
    expect(r.status).toBe(400);
  });

  it('ignores body.platformId — routes by token identity', async () => {
    const r = await post(
      `${h.url}/ios/reply`,
      JSON.stringify({ text: 'x', platformId: 'ios-app-v2:someone-else' }),
      TOKEN,
    );
    expect(r.status).toBe(200);
    expect(h.calls[0].platform_id).toBe(PLATFORM_ID);
  });
});
```

- [ ] **Step 2: Run it — fails (route 404s / dep missing).**

Run: `pnpm test -- src/channels/ios-app/v2/reply-endpoint.test.ts`
Expected: FAIL (200/400 assertions fail — route returns 404; and tsc errors on the unknown `routeReply`/`defaultAgentSlug` deps).

- [ ] **Step 3: Extend `HttpHandlerDeps`.** In `src/channels/ios-app/v2/http-handler.ts`, add to the `HttpHandlerDeps` interface (after `listPending`):

```ts
  /** Default agent slug when a reply omits agent_id. */
  defaultAgentSlug: string;
  /** Route a lock-screen reply as a user message to the named agent's session.
   *  platform_id is the token's identity (never body.platformId). */
  routeReply: (platform_id: string, agentId: string, text: string) => void;
```

And destructure them in `createIosHttpHandler`:

```ts
  const {
    resolveToken,
    healthRequestsStore,
    healthAgentFolder,
    getChannelSetup,
    imageCache,
    listPending,
    defaultAgentSlug,
    routeReply,
    log,
    logWarn,
  } = deps;
```

- [ ] **Step 4: Add the route.** In `http-handler.ts`, add a constant near the top of `createIosHttpHandler` and the route handler just before the final `404` fallthrough:

```ts
  const MAX_REPLY_CHARS = 4000;
```

```ts
    if (req.method === 'POST' && url.pathname === '/ios/reply') {
      const id = authIdentity(req);
      if (!id) {
        res.writeHead(401, { 'Content-Type': 'application/json' }).end('{"error":"unauthorized"}');
        return;
      }
      readBody(req)
        .then((body) => {
          const obj = JSON.parse(body) as { text?: unknown; agent_id?: unknown };
          const text = typeof obj.text === 'string' ? obj.text.trim() : '';
          if (!text || text.length > MAX_REPLY_CHARS) {
            res.writeHead(400, { 'Content-Type': 'application/json' }).end('{"error":"text required (1..4000 chars)"}');
            return;
          }
          const agentId = typeof obj.agent_id === 'string' && obj.agent_id ? obj.agent_id : defaultAgentSlug;
          // Routing is by TOKEN identity, never body.platformId (confused-deputy guard).
          routeReply(id.platform_id, agentId, text);
          res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
        })
        .catch((err) => {
          logWarn('reply failed', { err: err instanceof Error ? err.message : String(err) });
          res
            .writeHead(400, { 'Content-Type': 'application/json' })
            .end(JSON.stringify({ error: String(err instanceof Error ? err.message : err) }));
        });
      return;
    }
```

Add a line to the top-of-file route-inventory comment:

```
//   POST /ios/reply              — lock-screen reply → user message to the
//                                    token's agent session. Bearer auth.
```

- [ ] **Step 5: Wire `routeReply` + `defaultAgentSlug` in `index.ts`.** Ensure `import { randomUUID } from 'node:crypto';` is present at the top of `src/channels/ios-app/v2/index.ts` (add if missing). In the `createIosHttpHandler({ ... })` call (near line 459), add alongside `listPending`:

```ts
        defaultAgentSlug,
        routeReply: (platform_id, agentId, text) =>
          routeChatToAgent({ platform_id, agentId, threadId: null, id: randomUUID(), text }),
```

- [ ] **Step 6: Fix the other two harnesses (tsc).** In BOTH `src/channels/ios-app/v2/http-routes.test.ts` and `src/channels/ios-app/v2/image-endpoint.test.ts`, in the `createIosHttpHandler({ ... })` call, add:

```ts
    defaultAgentSlug: 'jarvis',
    routeReply: () => {},
```

- [ ] **Step 7: Run the reply test + full ios-app-v2 suite.**

Run: `pnpm test -- src/channels/ios-app/v2/`
Expected: PASS, including all 7 `POST /ios/reply` cases.

- [ ] **Step 8: Commit.**

```bash
git add src/channels/ios-app/v2/http-handler.ts src/channels/ios-app/v2/index.ts \
        src/channels/ios-app/v2/reply-endpoint.test.ts \
        src/channels/ios-app/v2/http-routes.test.ts src/channels/ios-app/v2/image-endpoint.test.ts
git commit -m "feat(ios-v2): POST /ios/reply — lock-screen reply routes to agent"
```

---

## Task 3: iOS — notification category + reply action

**Files:**
- Create: `Sources/JarvisApp/Services/NotificationCategories.swift`, `Sources/JarvisAppTests/NotificationCategoriesTests.swift`

- [ ] **Step 1: Write the failing test.** Create `Sources/JarvisAppTests/NotificationCategoriesTests.swift`:

```swift
import XCTest
import UserNotifications
@testable import Jarvis

final class NotificationCategoriesTests: XCTestCase {
    func testAgentMessageCategory() {
        let c = NotificationCategories.agentMessageCategory()
        XCTAssertEqual(c.identifier, "agent-message")
        XCTAssertEqual(c.actions.count, 1)
        XCTAssertEqual(c.actions.first?.identifier, "reply")
        XCTAssertTrue(c.actions.first is UNTextInputNotificationAction)
    }
}
```

- [ ] **Step 2: Create the factory.** Create `Sources/JarvisApp/Services/NotificationCategories.swift`:

```swift
import UserNotifications

/// The single notification category for agent messages, carrying a text-input
/// "reply" action so the user can answer from the lock screen. Registered once
/// at launch; `LocalNotifier` stamps every agent notification with this category.
enum NotificationCategories {
    static let agentMessage = "agent-message"
    static let replyAction = "reply"

    static func agentMessageCategory() -> UNNotificationCategory {
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: "Ответить",
            options: [],
            textInputButtonTitle: "Отправить",
            textInputPlaceholder: "Сообщение…"
        )
        return UNNotificationCategory(
            identifier: agentMessage,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
    }

    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories([agentMessageCategory()])
    }
}
```

- [ ] **Step 3: Regenerate the project (new files) + run the test.** From `ios/JarvisApp/`:

```bash
xcodegen generate
```

Run the test via XcodeBuildMCP `test_sim` (preferred) or, as fallback, controller-run with a long timeout:
`xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/NotificationCategoriesTests`
Expected: PASS (1 test).

- [ ] **Step 4: Commit.**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/NotificationCategories.swift \
        ios/JarvisApp/Sources/JarvisAppTests/NotificationCategoriesTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): agent-message notification category with reply action"
```

---

## Task 4: iOS — stamp category + userInfo on notifications

**Files:**
- Modify: `Sources/JarvisApp/Services/LocalNotifier.swift`, `Sources/JarvisAppTests/LocalNotifierTests.swift`

- [ ] **Step 1: Extend the existing pass test to assert category + userInfo.** In `Sources/JarvisAppTests/LocalNotifierTests.swift`, inside `testRaisesWhenBackgroundedAndEnabled`, after the existing `content` asserts, add:

```swift
        XCTAssertEqual(content.categoryIdentifier, "agent-message")
        XCTAssertEqual(content.userInfo["agentId"] as? String, "greg")
        XCTAssertEqual(content.userInfo["msgId"] as? String, "m1")
```

- [ ] **Step 2: Run it — fails.** (category/userInfo not set yet.)
Run via `test_sim` / xcodebuild `-only-testing:JarvisAppTests/LocalNotifierTests/testRaisesWhenBackgroundedAndEnabled`.
Expected: FAIL.

- [ ] **Step 3: Set them in `raise`.** In `Sources/JarvisApp/Services/LocalNotifier.swift`, in `raise(...)`, after `content.threadIdentifier = agentId`, add:

```swift
        content.categoryIdentifier = NotificationCategories.agentMessage
        content.userInfo = ["agentId": agentId, "msgId": id]
```

- [ ] **Step 4: Run the LocalNotifier tests — pass.**
Run `-only-testing:JarvisAppTests/LocalNotifierTests`.
Expected: PASS (existing 5 + the strengthened assert).

- [ ] **Step 5: Commit.**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/LocalNotifier.swift \
        ios/JarvisApp/Sources/JarvisAppTests/LocalNotifierTests.swift
git commit -m "feat(ios): stamp reply category + userInfo on agent notifications"
```

---

## Task 5: iOS — `NotificationReplySender` + HTTP base + echo

**Files:**
- Modify: `Sources/JarvisApp/Utility/ServerConfig.swift`, `Sources/JarvisApp/Storage/ConversationStoreV2.swift`
- Create: `Sources/JarvisApp/Services/NotificationReplySender.swift`, `Sources/JarvisAppTests/NotificationReplySenderTests.swift`

- [ ] **Step 1: Write the failing tests.** Create `Sources/JarvisAppTests/NotificationReplySenderTests.swift`:

```swift
import XCTest
import GRDB
@testable import Jarvis

final class NotificationReplySenderTests: XCTestCase {
    func testHttpBaseNormalizesWss() {
        XCTAssertEqual(ServerConfig.httpBase(), "https://jarvis.vasechko.dev")
    }

    func testBuildRequestTargetsReplyRoute() throws {
        let req = ReplyRequest.build(
            base: "https://jarvis.vasechko.dev", token: "tok", agentId: "greg", text: "привет"
        )
        let r = try XCTUnwrap(req)
        XCTAssertEqual(r.url?.path, "/ios/reply")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try XCTUnwrap(r.httpBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(obj["text"], "привет")
        XCTAssertEqual(obj["agent_id"], "greg")
    }

    func testEchoIsNotQueuedForResend() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        // status 'sent' (terminal) — the WS drain must NOT pick it up.
        try store.insertOutboundUserMessage(
            id: "echo-1", text: "hi", attachments: [], context: nil, agentId: "greg", status: "sent"
        )
        XCTAssertTrue(try store.queuedOutbound(agentId: "greg").isEmpty, "echo must not be re-sent")
        let total = try dbq.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages WHERE dir='out'") }
        XCTAssertEqual(total, 1, "echo row is present in the timeline")
    }
}
```

- [ ] **Step 2: Run — fails** (`httpBase`, `ReplyRequest`, `status:` param don't exist).

- [ ] **Step 3: Add `ServerConfig.httpBase()`.** In `Sources/JarvisApp/Utility/ServerConfig.swift`, inside `enum ServerConfig`:

```swift
    /// `url` normalized to an HTTP(S) base with no trailing slash, for the
    /// REST endpoints (state/health/pending/reply). `wss://` → `https://`.
    static func httpBase() -> String {
        var base = url
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        else if !base.hasPrefix("http") { base = "http://" + base }
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        return base
    }
```

- [ ] **Step 4: Add a `status` param to the store insert.** In `Sources/JarvisApp/Storage/ConversationStoreV2.swift`, change `insertOutboundUserMessage` to accept `status` (default preserves current behavior):

```swift
    func insertOutboundUserMessage(
        id: String,
        text: String,
        attachments: [V2.Attachment],
        context: V2.InlineContext?,
        agentId: String = "jarvis",
        status: String = "queued"
    ) throws {
```

and change the SQL/args so `status` is bound instead of the literal `'queued'`:

```swift
            try db.execute(sql: """
                INSERT INTO messages
                  (id, dir, seq, text, attachments_json, context_json, status, ts, created_at, agent_id)
                VALUES (?, 'out', NULL, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, text, attachmentsJSON, contextJSON, status, now, now, agentId])
```

- [ ] **Step 5: Create the sender.** Create `Sources/JarvisApp/Services/NotificationReplySender.swift`:

```swift
import Foundation

/// Sends a lock-screen reply to the host (`POST /ios/reply`) and, on success,
/// echoes it into the local store so it appears in the chat timeline. Suspend-
/// safe: a plain URLSession POST inside the notification-response window — no WS.
final class NotificationReplySender {
    static let shared = NotificationReplySender()

    private let storeLock = NSLock()
    private var _store: ConversationStoreV2?
    private var store: ConversationStoreV2? { storeLock.withLock { _store } }

    /// Wire the store at app init (same hook as LocalNotifier.configure).
    func configure(store: ConversationStoreV2) { storeLock.withLock { _store = store } }

    func send(agentId: String, text: String, completion: @escaping (Bool) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let token = UserDefaults.standard.string(forKey: "bearerToken"), !token.isEmpty,
              let req = ReplyRequest.build(base: ServerConfig.httpBase(), token: token, agentId: agentId, text: trimmed)
        else { completion(false); return }

        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            if ok { self?.recordEcho(agentId: agentId, text: trimmed) }
            completion(ok)
        }.resume()
    }

    /// Success-only echo with a terminal status so the outbound WS drain
    /// (queuedOutbound filters status='queued') never re-sends it.
    private func recordEcho(agentId: String, text: String) {
        guard let store else { return }
        try? store.insertOutboundUserMessage(
            id: UUID().uuidString, text: text, attachments: [], context: nil, agentId: agentId, status: "sent"
        )
    }
}

/// Pure request builder (unit-tested without network).
enum ReplyRequest {
    static func build(base: String, token: String, agentId: String, text: String) -> URLRequest? {
        guard let url = URL(string: base.hasSuffix("/") ? base + "ios/reply" : base + "/ios/reply") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "agent_id": agentId])
        req.timeoutInterval = 20
        return req
    }
}
```

- [ ] **Step 6: `xcodegen generate` (new files) + run the tests.** From `ios/JarvisApp/`: `xcodegen generate`, then run `-only-testing:JarvisAppTests/NotificationReplySenderTests`.
Expected: PASS (3 tests).

- [ ] **Step 7: Commit.**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Utility/ServerConfig.swift \
        ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/NotificationReplySender.swift \
        ios/JarvisApp/Sources/JarvisAppTests/NotificationReplySenderTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): NotificationReplySender + ServerConfig.httpBase + terminal-status echo"
```

---

## Task 6: iOS — handle the reply action in `AppDelegate`

**Files:**
- Modify: `Sources/JarvisApp/JarvisApp.swift`, `Sources/JarvisApp/Services/AppCoordinator.swift`

No unit test (the delegate drives the system singleton; the sender logic is covered by Task 5). Verified by a clean build.

- [ ] **Step 1: Register the category at launch.** In `Sources/JarvisApp/JarvisApp.swift`, in `didFinishLaunchingWithOptions`, right after the `requestAuthorization(...)` line, add:

```swift
        NotificationCategories.register()
```

- [ ] **Step 2: Handle the reply action.** Replace the body of `userNotificationCenter(_:didReceive:withCompletionHandler:)` with:

```swift
        if response.actionIdentifier == NotificationCategories.replyAction,
           let textResponse = response as? UNTextInputNotificationResponse {
            let info = response.notification.request.content.userInfo
            let agentId = info["agentId"] as? String ?? "jarvis"
            NotificationReplySender.shared.send(agentId: agentId, text: textResponse.userText) { _ in
                completionHandler()
            }
            return
        }
        completionHandler()
```

- [ ] **Step 3: Configure the sender's store at init.** In `Sources/JarvisApp/Services/AppCoordinator.swift`, in `init`, inside the same `if let storage {` block that calls `LocalNotifier.shared.configure(store:)`, add:

```swift
            NotificationReplySender.shared.configure(store: storage.store)
```

- [ ] **Step 4: Clean build.** Build the `JarvisApp` scheme for the simulator (XcodeBuildMCP `build_sim` or `xcodebuild build`).
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit.**

```bash
git add ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift
git commit -m "feat(ios): post lock-screen reply from notification action"
```

---

## Task 7: iOS — quiet-hours + muted-agents storage (pure)

**Files:**
- Create: `Sources/JarvisApp/Models/NotificationGating.swift`, `Sources/JarvisAppTests/NotificationGatingTests.swift`
- Modify: `Sources/JarvisApp/Models/AppSettings.swift`

- [ ] **Step 1: Write the failing tests.** Create `Sources/JarvisAppTests/NotificationGatingTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class NotificationGatingTests: XCTestCase {
    func testQuietHoursOvernightWrap() {
        // 23:00 (1380) → 08:00 (480)
        XCTAssertTrue(QuietHours.contains(minutes: 1410, start: 1380, end: 480, enabled: true))  // 23:30
        XCTAssertTrue(QuietHours.contains(minutes: 420, start: 1380, end: 480, enabled: true))   // 07:00
        XCTAssertTrue(QuietHours.contains(minutes: 1380, start: 1380, end: 480, enabled: true))  // exactly 23:00
        XCTAssertFalse(QuietHours.contains(minutes: 480, start: 1380, end: 480, enabled: true))  // exactly 08:00
        XCTAssertFalse(QuietHours.contains(minutes: 720, start: 1380, end: 480, enabled: true))  // 12:00
    }

    func testQuietHoursSameDayWindow() {
        // 08:00 (480) → 23:00 (1380)
        XCTAssertTrue(QuietHours.contains(minutes: 600, start: 480, end: 1380, enabled: true))   // 10:00
        XCTAssertFalse(QuietHours.contains(minutes: 60, start: 480, end: 1380, enabled: true))   // 01:00
        XCTAssertFalse(QuietHours.contains(minutes: 1380, start: 480, end: 1380, enabled: true)) // exactly 23:00
    }

    func testQuietHoursDisabledOrZeroWidth() {
        XCTAssertFalse(QuietHours.contains(minutes: 1410, start: 1380, end: 480, enabled: false))
        XCTAssertFalse(QuietHours.contains(minutes: 600, start: 600, end: 600, enabled: true))
    }

    func testMutedAgentsRoundTrip() {
        XCTAssertEqual(MutedAgents.decode("[]"), [])
        XCTAssertEqual(MutedAgents.decode("garbage"), [])
        let encoded = MutedAgents.encode(["greg", "gordon"])
        XCTAssertEqual(MutedAgents.decode(encoded), ["greg", "gordon"])
    }
}
```

- [ ] **Step 2: Run — fails** (`QuietHours`, `MutedAgents` don't exist).

- [ ] **Step 3: Create the pure helpers.** Create `Sources/JarvisApp/Models/NotificationGating.swift`:

```swift
import Foundation

/// Pure quiet-hours window test. Minutes are minutes-since-local-midnight in
/// [0,1440). The window may wrap midnight (start > end).
enum QuietHours {
    static func contains(minutes t: Int, start: Int, end: Int, enabled: Bool) -> Bool {
        guard enabled, start != end else { return false }
        if start < end { return t >= start && t < end }
        return t >= start || t < end   // overnight wrap
    }
}

/// Muted-agent set persisted as a JSON-array string in AppStorage.
enum MutedAgents {
    static func decode(_ raw: String) -> Set<String> {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    static func encode(_ set: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(Array(set).sorted()),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}
```

- [ ] **Step 4: Add storage + helpers to `AppSettings`.** In `Sources/JarvisApp/Models/AppSettings.swift`, in the `// MARK: – Notifications` block, after `notificationsEnabled`, add:

```swift
    /// Per-agent mute (JSON-array string of agent slugs). Empty = nothing muted.
    @ObservationIgnored @AppStorage("mutedAgents") var mutedAgentsRaw = "[]"
    @ObservationIgnored @AppStorage("quietHoursEnabled") var quietHoursEnabled = false
    @ObservationIgnored @AppStorage("quietStartMinutes") var quietStartMinutes = 1380  // 23:00
    @ObservationIgnored @AppStorage("quietEndMinutes")   var quietEndMinutes   = 480   // 08:00

    func isAgentMuted(_ slug: String) -> Bool { MutedAgents.decode(mutedAgentsRaw).contains(slug) }

    func setAgentMuted(_ slug: String, _ muted: Bool) {
        var s = MutedAgents.decode(mutedAgentsRaw)
        if muted { s.insert(slug) } else { s.remove(slug) }
        mutedAgentsRaw = MutedAgents.encode(s)
    }
```

- [ ] **Step 5: `xcodegen generate` + run the gating tests.** From `ios/JarvisApp/`: `xcodegen generate`, then `-only-testing:JarvisAppTests/NotificationGatingTests`.
Expected: PASS (4 tests).

- [ ] **Step 6: Commit.**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/NotificationGating.swift \
        ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift \
        ios/JarvisApp/Sources/JarvisAppTests/NotificationGatingTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): quiet-hours + muted-agents storage and pure logic"
```

---

## Task 8: iOS — gate `LocalNotifier.raise` on mute + quiet hours

**Files:**
- Modify: `Sources/JarvisApp/Services/LocalNotifier.swift`, `Sources/JarvisAppTests/LocalNotifierTests.swift`

- [ ] **Step 1: Write the failing tests.** In `Sources/JarvisAppTests/LocalNotifierTests.swift`, add:

```swift
    func testSuppressedWhenAgentMuted() throws {
        let rec = RecordingCenter(); let store = try makeStore()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true },
                              isMuted: { $0 == "greg" }, inQuietHours: { false })
        n.configure(store: store)
        n.raise(id: "m1", agentId: "greg", text: "x", seq: 1)
        XCTAssertEqual(rec.requests.count, 0, "muted agent → no notification")
        n.raise(id: "m2", agentId: "jarvis", text: "y", seq: 1)
        XCTAssertEqual(rec.requests.count, 1, "non-muted agent still notifies")
    }

    func testSuppressedDuringQuietHours() throws {
        let rec = RecordingCenter(); let store = try makeStore()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true },
                              isMuted: { _ in false }, inQuietHours: { true })
        n.configure(store: store)
        n.raise(id: "m1", agentId: "jarvis", text: "x", seq: 1)
        XCTAssertEqual(rec.requests.count, 0, "quiet hours → no notification")
    }
```

- [ ] **Step 2: Run — fails** (init has no `isMuted`/`inQuietHours` params).

- [ ] **Step 3: Add the gates.** In `Sources/JarvisApp/Services/LocalNotifier.swift`:

Add stored closures next to the existing ones:

```swift
    private let isMuted: (String) -> Bool
    private let inQuietHours: () -> Bool
```

Extend `init` with two new defaulted params (keeps existing call sites + tests compiling):

```swift
    init(
        center: NotificationScheduling = UNUserNotificationCenter.current(),
        isForeground: @escaping () -> Bool = { AppForegroundState.isActive },
        isEnabled: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        },
        isMuted: @escaping (String) -> Bool = { agentId in
            MutedAgents.decode(UserDefaults.standard.string(forKey: "mutedAgents") ?? "[]").contains(agentId)
        },
        inQuietHours: @escaping () -> Bool = {
            let d = UserDefaults.standard
            let enabled = d.object(forKey: "quietHoursEnabled") as? Bool ?? false
            let start = d.object(forKey: "quietStartMinutes") as? Int ?? 1380
            let end = d.object(forKey: "quietEndMinutes") as? Int ?? 480
            let cal = Calendar.current
            let now = Date()
            let t = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
            return QuietHours.contains(minutes: t, start: start, end: end, enabled: enabled)
        }
    ) {
        self.center = center
        self.isForeground = isForeground
        self.isEnabled = isEnabled
        self.isMuted = isMuted
        self.inQuietHours = inQuietHours
    }
```

In `raise(...)`, right after `guard isEnabled() else { return }` and before `guard let store else { return }`, add:

```swift
        guard !isMuted(agentId) else { return }
        guard !inQuietHours() else { return }
```

- [ ] **Step 4: Run the full LocalNotifier suite — pass.**
Run `-only-testing:JarvisAppTests/LocalNotifierTests`.
Expected: PASS (7 tests: 5 original + 2 new).

- [ ] **Step 5: Commit.**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/LocalNotifier.swift \
        ios/JarvisApp/Sources/JarvisAppTests/LocalNotifierTests.swift
git commit -m "feat(ios): gate notifications on per-agent mute + quiet hours"
```

---

## Task 9: iOS — Settings UI

**Files:**
- Modify: `Sources/JarvisApp/Views/SettingsView.swift`

UI; verified by a clean build. No unit test.

- [ ] **Step 1: Remove the lone toggle from "Контекст".** In `Sources/JarvisApp/Views/SettingsView.swift`, delete the existing notifications line inside the `settingsSection(title: "Контекст")` block:

```swift
                    settingsToggle(icon: "bell", label: "Уведомления", isOn: $settings.notificationsEnabled)
```

- [ ] **Step 2: Add a dedicated "Уведомления" section.** Immediately after the `settingsSection(title: "Контекст") { ... }` block closes, insert:

```swift
                settingsSection(title: "Уведомления") {
                    settingsToggle(icon: "bell", label: "Уведомления", isOn: $settings.notificationsEnabled)
                    if settings.notificationsEnabled {
                        ForEach(AgentIdentity.allCases) { agent in
                            settingsToggle(
                                icon: "person.fill",
                                label: agent.displayName,
                                isOn: Binding(
                                    get: { !settings.isAgentMuted(agent.rawValue) },
                                    set: { settings.setAgentMuted(agent.rawValue, !$0) }
                                )
                            )
                        }
                        settingsToggle(icon: "moon", label: "Тихие часы", isOn: $settings.quietHoursEnabled)
                        if settings.quietHoursEnabled {
                            quietHoursRow(label: "С", minutes: $settings.quietStartMinutes)
                            quietHoursRow(label: "До", minutes: $settings.quietEndMinutes)
                        }
                    }
                }
```

- [ ] **Step 3: Add the time-row helper + converters.** Inside the `SettingsView` struct (near `settingsToggle`), add:

```swift
    private func quietHoursRow(label: String, minutes: Binding<Int>) -> some View {
        HStack {
            Image(systemName: "clock").foregroundStyle(Theme.accent)
            Text(label).foregroundStyle(Theme.textPrimary)
            Spacer()
            DatePicker(
                "",
                selection: Binding(
                    get: { Self.date(fromMinutes: minutes.wrappedValue) },
                    set: { minutes.wrappedValue = Self.minutes(fromDate: $0) }
                ),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    private static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minutes(fromDate d: Date) -> Int {
        let c = Calendar.current
        return c.component(.hour, from: d) * 60 + c.component(.minute, from: d)
    }
```

(Match the surrounding padding/visual style if it differs — the goal is rows that read like the existing toggles.)

- [ ] **Step 4: Clean build.**
Build `JarvisApp` for the simulator.
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit.**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift
git commit -m "feat(ios): notifications settings — per-agent mute + quiet hours"
```

---

## Task 10: iOS — version bump + clean build + full test run

**Files:**
- Modify: `ios/JarvisApp/project.yml`

- [ ] **Step 1: Bump versions.** In `ios/JarvisApp/project.yml`, set:

```yaml
    MARKETING_VERSION: "1.17.0"
    CURRENT_PROJECT_VERSION: "71"
```

- [ ] **Step 2: Regenerate.** From `ios/JarvisApp/`: `xcodegen generate`.

- [ ] **Step 3: Full clean build + entire test target.**
Run the whole `JarvisAppTests` suite on the simulator (XcodeBuildMCP `test_sim` preferred; fallback controller-run `xcodebuild test ... -only-testing:JarvisAppTests` with a long Bash timeout).
Expected: BUILD SUCCEEDED; all tests pass (prior 269 + the new NotificationCategories/ReplySender/Gating cases + strengthened LocalNotifier; pre-existing skips unchanged).

- [ ] **Step 4: Commit.**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "chore(ios): bump build 71 / 1.17.0 — lock-screen reply + notif controls"
```

---

## Task 11: Deploy host + update memory

**Files:** none (ops + memory).

- [ ] **Step 1: Run the full host suite once more.**
Run: `pnpm test`
Expected: PASS (prior count + the 7 new reply-endpoint cases).

- [ ] **Step 2: Push.**

```bash
git push origin main
```

- [ ] **Step 3: Deploy to the VDS.**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && git pull --ff-only && pnpm run build && XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart nanoclaw && sleep 2 && XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active nanoclaw"'
```

Expected: `active`.

- [ ] **Step 4: Smoke the endpoint (unauth → 401).**

```bash
ssh root@148.253.211.164 "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:3001/ios/reply -H 'Content-Type: application/json' -d '{\"text\":\"x\"}'"
```

Expected: `401`.

- [ ] **Step 5: Update memory.** Update `memory/project_ios_notifications.md` (and its `MEMORY.md` index hook) to record: lock-screen reply (`POST /ios/reply` + reply action) and per-agent mute + quiet hours shipped; host LIVE; iOS build **71 / 1.17.0** pending user install. Note Approve/Deny + `.timeSensitive` remain deferred.

- [ ] **Step 6: Hand off.** Tell the user host is live and to install build 71 on their device.

---

## Self-Review

**Spec coverage:**
- A.1 `POST /ios/reply` → Task 2. ✓
- A.2 `routeReply`/`routeChatToAgent` wiring → Tasks 1–2. ✓
- A.3 category + action → Task 3; content stamping → Task 4. ✓
- A.4 `NotificationReplySender` + httpBase + terminal-status echo → Task 5. ✓
- A.5 `didReceive` handling + configure → Task 6. ✓
- B.1 settings storage → Task 7. ✓
- B.2 `raise` gating + midnight-wrap → Tasks 7 (logic) + 8 (gates). ✓
- B.3 Settings UI → Task 9. ✓
- C.1 host tests → Task 2. ✓ C.2 iOS tests → Tasks 3,5,7,8. ✓ C.3 version → Task 10. ✓ C.4 deploy → Task 11. ✓
- Out-of-scope (Approve/Deny, `.timeSensitive`) → not implemented, recorded in memory (Task 11). ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type/name consistency:** `routeChatToAgent` (T1) reused in T2; `routeReply(platform_id, agentId, text)` signature matches across http-handler dep, index.ts closure, and the test spy; `NotificationCategories.agentMessage`/`replyAction` reused in T4/T6; `ReplyRequest.build(base:token:agentId:text:)` matches test + sender; `insertOutboundUserMessage(...status:)` matches T5 store change + sender + echo test; `QuietHours.contains(minutes:start:end:enabled:)` and `MutedAgents.decode/encode` match across T7/T8; `isAgentMuted`/`setAgentMuted` match T7 + T9. ✓
