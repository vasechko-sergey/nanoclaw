# Automated Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full-stack automated test suite — vitest WS/context integration tests for ios-app.ts + XCUITest UI automation for the iOS app against a local mock WS server.

**Architecture:** Server tests extend existing vitest suite by extracting a testable WS handler factory from `ios-app.ts`. iOS tests add a new `JarvisUITests` xcodegen target; the app detects `--uitesting` launch arg and connects to a local mock server instead of VDS.

**Tech Stack:** vitest, ws (WebSocket), Node http, Swift XCTest/XCUITest, xcodegen.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `src/channels/ios-app.ts` | Modify | Export `createIosWsHandler` for test isolation |
| `src/channels/ios-app.ws.test.ts` | Create | WS protocol integration tests |
| `src/channels/ios-app.context.test.ts` | Create | Context injection integration tests |
| `scripts/mock-ws-server.ts` | Create | Local mock server for iOS XCUITest |
| `scripts/test-all.sh` | Create | Combined test runner |
| `package.json` | Modify | Add `test:all` script |
| `ios/JarvisApp/project.yml` | Modify | Add `JarvisUITests` target |
| `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift` | Modify | Add `isUITesting` static flag + `isConfigured` test override |
| `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift` | Modify | Override `isConfigured` in test mode |
| `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift` | Modify | Override URL + token in `doConnect` |
| `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` | Modify | Add accessibility IDs: `orb-home`, `home-orb` |
| `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` | Modify | Add accessibility ID: `chat-view` |
| `ios/JarvisApp/Sources/JarvisApp/Components/OrbInputBar.swift` | Modify | Add accessibility IDs: `message-input`, `send-btn` |
| `ios/JarvisApp/Sources/JarvisApp/Components/EmptyStateView.swift` | Modify | Add accessibility ID: `empty-start-text` |
| `ios/JarvisApp/Sources/JarvisApp/Components/MessageBubble.swift` | Modify | Add accessibility IDs: `bubble-user-<id>`, `bubble-assistant-<id>` |
| `ios/JarvisApp/Sources/JarvisUITests/JarvisUITests.swift` | Create | 5 XCUITest cases |

---

## Task 1: Export testable WS handler from ios-app.ts

**Files:**
- Modify: `src/channels/ios-app.ts`

The test needs to spin up a real WebSocket server with the ios-app.ts connection handler. Currently the handler is buried inside `createIOSAdapter()`. Extract it as an exported function that takes its dependencies explicitly.

- [ ] **Step 1: Add exported types and handler factory**

Add the following BEFORE the `createIOSAdapter` function (around line 247):

```typescript
export interface IosWsHandlerState {
  wsClients: Map<string, Set<WebSocket>>;
  apnsTokens: Map<string, string>;
  pendingMessages: Map<string, QueuedMessage[]>;
  deliveredIds: Map<string, Set<string>>;
  lastTimezone: Map<string, string>;
}

export function createIosWsHandler(opts: {
  token: string;
  store: ReadReceiptStore;
  cfg: { onInbound: (pid: string, tid: string | null, msg: Record<string, unknown>) => Promise<void>; onAction: (qid: string, bid: string, pid: string) => void };
  state: IosWsHandlerState;
  persist: { receipts: () => void; tokens: () => void };
}): (ws: WebSocket) => void {
  const { token, store, cfg, state, persist } = opts;
  const { wsClients, apnsTokens, pendingMessages, deliveredIds, lastTimezone } = state;

  function recordDelivered(pid: string, id: string): void {
    let s = deliveredIds.get(pid);
    if (!s) deliveredIds.set(pid, (s = new Set()));
    if (s.size > 500) s.clear();
    s.add(id);
  }

  function removeClient(pid: string, ws: WebSocket) {
    const s = wsClients.get(pid);
    if (!s) return;
    s.delete(ws);
    if (s.size === 0) {
      wsClients.delete(pid);
      lastTimezone.delete(pid);
    }
  }

  return (ws: WebSocket) => {
    let pid: string | null = null;
    let authed = false;
    let isAlive = true;
    ws.on('pong', () => { isAlive = true; });
    const ping = setInterval(() => {
      if (ws.readyState !== WebSocket.OPEN) return;
      if (!isAlive) { ws.terminate(); return; }
      isAlive = false;
      ws.ping();
    }, 30_000);

    ws.on('message', async (data) => {
      let msg: Record<string, unknown>;
      try { msg = JSON.parse(data.toString()); } catch { ws.close(1003); return; }

      if (!authed) {
        if (msg.type === 'auth' && msg.token === token && typeof msg.platformId === 'string') {
          authed = true;
          pid = msg.platformId;
          if (!wsClients.has(pid)) wsClients.set(pid, new Set());
          wsClients.get(pid)!.add(ws);
          if (typeof msg.apnsToken === 'string' && msg.apnsToken) {
            apnsTokens.set(pid, msg.apnsToken);
            persist.tokens();
          }
          ws.send(JSON.stringify({ type: 'auth_ok', commands: [] }));
          const pending = pendingMessages.get(pid);
          if (pending?.length) {
            pendingMessages.delete(pid);
            const seen = deliveredIds.get(pid);
            for (const p of pending) {
              if (seen?.has(p.id)) continue;
              if (ws.readyState === WebSocket.OPEN && p.text)
                ws.send(JSON.stringify({ type: 'message', id: p.id, text: p.text, timestamp: p.ts }));
              recordDelivered(pid, p.id);
            }
          }
        } else {
          ws.close(4001);
        }
        return;
      }

      if (msg.type === 'apns_token' && typeof msg.token === 'string' && pid) {
        apnsTokens.set(pid, msg.token);
        persist.tokens();
      }

      if (msg.type === 'message_delivered' && pid && typeof msg.messageId === 'string') {
        store.record(pid, msg.messageId, 'delivered');
        persist.receipts();
      }

      if (msg.type === 'message_read' && pid && typeof msg.messageId === 'string') {
        store.record(pid, msg.messageId, 'read');
        persist.receipts();
      }

      if (msg.type === 'message' && typeof msg.text === 'string' && pid) {
        if (typeof msg.timezone === 'string' && msg.timezone) lastTimezone.set(pid, msg.timezone);
        const status = typeof msg.status === 'string' && msg.status ? `[status: ${msg.status}]\n` : '';
        const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
        const content: Record<string, unknown> = { text: status + msg.text, senderId: pid };
        await cfg.onInbound(pid, tid, { id: randomUUID(), kind: 'chat', content, timestamp: new Date().toISOString() } as Record<string, unknown>);
        if (typeof msg.clientMessageId === 'string' && msg.clientMessageId) {
          ws.send(JSON.stringify({ type: 'message_ack', clientMessageId: msg.clientMessageId }));
        }
      }

      if (msg.type === 'context_response' && pid) {
        const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
        const ctx = (msg.context as Record<string, unknown> | undefined) ?? {};
        if (typeof ctx.timezone !== 'string' && lastTimezone.has(pid)) ctx.timezone = lastTimezone.get(pid);
        const pendingReceipts = store.getPending(pid);
        if (pendingReceipts.length > 0) {
          ctx.readReceipts = pendingReceipts;
          store.markInjected(pendingReceipts);
          persist.receipts();
        }
        let block: string;
        try { block = buildCtx(ctx); } catch { block = ''; }
        await cfg.onInbound(pid, tid, {
          id: randomUUID(), kind: 'chat',
          content: { text: block || '[iOS context — requested data unavailable]', senderId: pid },
          timestamp: new Date().toISOString(),
        } as Record<string, unknown>);
      }
    });

    ws.on('close', () => { clearInterval(ping); if (pid) removeClient(pid, ws); });
    ws.on('error', () => { clearInterval(ping); if (pid) removeClient(pid, ws); });
  };
}
```

- [ ] **Step 2: Wire createIosWsHandler inside createIOSAdapter**

In `createIOSAdapter()`, replace the inline `wss.on('connection', (ws) => { ... })` block with:

```typescript
const handlerState: IosWsHandlerState = {
  wsClients,
  apnsTokens,
  pendingMessages,
  deliveredIds,
  lastTimezone,
};

wss.on('connection', createIosWsHandler({
  token,
  store: readReceiptStore,
  cfg: {
    onInbound: async (pid, tid, msg) => cfg!.onInbound(pid, tid, msg as Parameters<ChannelSetup['onInbound']>[2]),
    onAction: (qid, bid, pid) => cfg!.onAction(qid, bid, pid),
  },
  state: handlerState,
  persist: { receipts: persistReadReceipts, tokens: () => savePersistedTokens(apnsTokens) },
}));
```

Also delete the now-redundant inline `recordDelivered` and `removeClient` functions from `createIOSAdapter`.

- [ ] **Step 3: Verify build**

```bash
pnpm run build
```
Expected: no TypeScript errors.

- [ ] **Step 4: Verify existing tests still pass**

```bash
pnpm test -- --reporter=verbose src/channels/ios-read-receipts.test.ts
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app.ts
git commit -m "refactor(ios-app): export createIosWsHandler for test isolation"
```

---

## Task 2: WS protocol integration tests

**Files:**
- Create: `src/channels/ios-app.ws.test.ts`

- [ ] **Step 1: Write the tests**

```typescript
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { WebSocketServer, WebSocket } from 'ws';
import { ReadReceiptStore } from './ios-read-receipts.js';
import { createIosWsHandler, type IosWsHandlerState } from './ios-app.js';

function makeState(): IosWsHandlerState {
  return {
    wsClients: new Map(),
    apnsTokens: new Map(),
    pendingMessages: new Map(),
    deliveredIds: new Map(),
    lastTimezone: new Map(),
  };
}

async function createTestServer() {
  const store = new ReadReceiptStore();
  const inbound: Array<{ pid: string; content: Record<string, unknown> }> = [];
  const state = makeState();
  const handler = createIosWsHandler({
    token: 'test-token',
    store,
    cfg: {
      onInbound: async (pid, _tid, msg) => {
        inbound.push({ pid, content: (msg as Record<string, unknown>).content as Record<string, unknown> });
      },
      onAction: () => {},
    },
    state,
    persist: { receipts: () => {}, tokens: () => {} },
  });
  const server = createServer();
  const wss = new WebSocketServer({ server });
  wss.on('connection', handler);
  await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  const close = () => new Promise<void>(r => { wss.close(); server.close(() => r()); });
  return { port, store, inbound, close };
}

async function connect(port: number): Promise<WebSocket> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  await new Promise<void>((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  return ws;
}

async function auth(ws: WebSocket): Promise<Record<string, unknown>> {
  return new Promise(resolve => {
    ws.once('message', m => resolve(JSON.parse(m.toString())));
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:test-1' }));
  });
}

describe('ios-app WS protocol', () => {
  let ctx: Awaited<ReturnType<typeof createTestServer>>;

  beforeEach(async () => { ctx = await createTestServer(); });
  afterEach(async () => { await ctx.close(); });

  it('auth → auth_ok', async () => {
    const ws = await connect(ctx.port);
    const reply = await auth(ws);
    expect(reply.type).toBe('auth_ok');
    ws.close();
  });

  it('bad token → socket closed with code 4001', async () => {
    const ws = await connect(ctx.port);
    const closeCode = await new Promise<number>(resolve => {
      ws.once('close', code => resolve(code));
      ws.send(JSON.stringify({ type: 'auth', token: 'wrong-token', platformId: 'ios:bad' }));
    });
    expect(closeCode).toBe(4001);
  });

  it('message with clientMessageId → message_ack with same id', async () => {
    const ws = await connect(ctx.port);
    await auth(ws);
    const ack = await new Promise<Record<string, unknown>>(resolve => {
      ws.once('message', m => resolve(JSON.parse(m.toString())));
      ws.send(JSON.stringify({ type: 'message', text: 'hello', clientMessageId: 'cid-abc' }));
    });
    expect(ack.type).toBe('message_ack');
    expect(ack.clientMessageId).toBe('cid-abc');
    ws.close();
  });

  it('message_delivered → stored in ReadReceiptStore', async () => {
    const ws = await connect(ctx.port);
    await auth(ws);
    ws.send(JSON.stringify({ type: 'message_delivered', messageId: 'msg-1' }));
    await new Promise(r => setTimeout(r, 50));
    const pending = ctx.store.getPending('ios:test-1');
    expect(pending).toHaveLength(1);
    expect(pending[0].messageId).toBe('msg-1');
    expect(pending[0].deliveredAt).toBeTruthy();
    ws.close();
  });

  it('message_read → readAt set on existing entry', async () => {
    const ws = await connect(ctx.port);
    await auth(ws);
    ws.send(JSON.stringify({ type: 'message_delivered', messageId: 'msg-2' }));
    ws.send(JSON.stringify({ type: 'message_read', messageId: 'msg-2' }));
    await new Promise(r => setTimeout(r, 50));
    const pending = ctx.store.getPending('ios:test-1');
    const entry = pending.find(p => p.messageId === 'msg-2');
    expect(entry?.readAt).toBeTruthy();
    ws.close();
  });
});
```

- [ ] **Step 2: Run tests and confirm they fail (store not yet exported)**

```bash
pnpm test -- src/channels/ios-app.ws.test.ts
```
Expected: PASS (Task 1 already exports the handler).

- [ ] **Step 3: Commit**

```bash
git add src/channels/ios-app.ws.test.ts
git commit -m "test(ios-app): WS protocol integration tests"
```

---

## Task 3: Context injection integration tests

**Files:**
- Create: `src/channels/ios-app.context.test.ts`

- [ ] **Step 1: Write the tests**

```typescript
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { WebSocketServer, WebSocket } from 'ws';
import { ReadReceiptStore } from './ios-read-receipts.js';
import { createIosWsHandler, type IosWsHandlerState } from './ios-app.js';

function makeState(): IosWsHandlerState {
  return {
    wsClients: new Map(),
    apnsTokens: new Map(),
    pendingMessages: new Map(),
    deliveredIds: new Map(),
    lastTimezone: new Map(),
  };
}

async function setup() {
  const store = new ReadReceiptStore();
  const inbound: Array<{ text: string }> = [];
  const handler = createIosWsHandler({
    token: 'test-token',
    store,
    cfg: {
      onInbound: async (_pid, _tid, msg) => {
        const content = (msg as Record<string, unknown>).content as Record<string, unknown>;
        inbound.push({ text: content.text as string });
      },
      onAction: () => {},
    },
    state: makeState(),
    persist: { receipts: () => {}, tokens: () => {} },
  });
  const server = createServer();
  const wss = new WebSocketServer({ server });
  wss.on('connection', handler);
  await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  const close = () => new Promise<void>(r => { wss.close(); server.close(() => r()); });

  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  await new Promise<void>((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  // Auth
  await new Promise<void>(resolve => {
    ws.once('message', () => resolve());
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:ctx-test' }));
  });

  return { store, inbound, ws, close };
}

describe('ios-app context injection', () => {
  let ctx: Awaited<ReturnType<typeof setup>>;

  beforeEach(async () => { ctx = await setup(); });
  afterEach(async () => { ctx.ws.close(); await ctx.close(); });

  it('context_response with pending receipts → inbound text contains [read receipts]', async () => {
    ctx.store.record('ios:ctx-test', 'msg-abc', 'delivered');
    ctx.ws.send(JSON.stringify({ type: 'context_response', context: { timezone: 'Asia/Tbilisi' } }));
    await new Promise(r => setTimeout(r, 100));
    expect(ctx.inbound).toHaveLength(1);
    expect(ctx.inbound[0].text).toContain('[read receipts]');
    expect(ctx.inbound[0].text).toContain('msg-abc');
  });

  it('receipts are marked injected after context_response', async () => {
    ctx.store.record('ios:ctx-test', 'msg-xyz', 'delivered');
    ctx.ws.send(JSON.stringify({ type: 'context_response', context: {} }));
    await new Promise(r => setTimeout(r, 100));
    expect(ctx.store.getPending('ios:ctx-test')).toHaveLength(0);
  });

  it('second context_response does not re-inject already injected receipts', async () => {
    ctx.store.record('ios:ctx-test', 'msg-dup', 'delivered');
    ctx.ws.send(JSON.stringify({ type: 'context_response', context: {} }));
    await new Promise(r => setTimeout(r, 50));
    ctx.ws.send(JSON.stringify({ type: 'context_response', context: {} }));
    await new Promise(r => setTimeout(r, 50));
    expect(ctx.inbound).toHaveLength(2);
    // Second call has no receipts — text is empty context or unavailable banner
    expect(ctx.inbound[1].text).not.toContain('msg-dup');
  });

  it('context_response without pending receipts → no [read receipts] block', async () => {
    ctx.ws.send(JSON.stringify({ type: 'context_response', context: {} }));
    await new Promise(r => setTimeout(r, 100));
    // buildCtx returns '' when no data → inbound gets the unavailable banner
    expect(ctx.inbound[0].text).not.toContain('[read receipts]');
  });
});
```

- [ ] **Step 2: Run all server tests**

```bash
pnpm test -- src/channels/ios-app.ws.test.ts src/channels/ios-app.context.test.ts src/channels/ios-read-receipts.test.ts
```
Expected: all pass.

- [ ] **Step 3: Run full vitest suite to check for regressions**

```bash
pnpm test
```
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add src/channels/ios-app.context.test.ts
git commit -m "test(ios-app): context injection integration tests"
```

---

## Task 4: Mock WS server

**Files:**
- Create: `scripts/mock-ws-server.ts`

- [ ] **Step 1: Write the mock server**

```typescript
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';

const PORT = parseInt(process.env.MOCK_WS_PORT ?? '8765', 10);

const server = createServer();
const wss = new WebSocketServer({ server });

wss.on('connection', (ws: WebSocket) => {
  console.log('[mock-ws] client connected');

  ws.on('message', (data) => {
    let msg: Record<string, unknown>;
    try { msg = JSON.parse(data.toString()); } catch { return; }

    console.log(`[mock-ws] <- ${msg.type as string}`);

    if (msg.type === 'auth') {
      ws.send(JSON.stringify({ type: 'auth_ok', pid: 'ios:mock', commands: [] }));
      return;
    }

    if (msg.type === 'message') {
      if (typeof msg.clientMessageId === 'string') {
        ws.send(JSON.stringify({ type: 'message_ack', clientMessageId: msg.clientMessageId }));
      }
      const text = typeof msg.text === 'string' ? msg.text : '';
      const convId = msg.conversationId;
      setTimeout(() => {
        if (ws.readyState !== ws.OPEN) return;
        ws.send(JSON.stringify({
          type: 'message',
          id: randomUUID(),
          text: `Mock: ${text}`,
          conversationId: convId,
          timestamp: new Date().toISOString(),
        }));
      }, 500);
      return;
    }

    if (msg.type === 'context_request') {
      ws.send(JSON.stringify({ type: 'context_response', requestId: msg.requestId, context: {} }));
      return;
    }
    // message_delivered, message_read, apns_token, feedback, new_conversation — no reply needed
  });

  ws.on('close', () => console.log('[mock-ws] client disconnected'));
  ws.on('error', (e) => console.error('[mock-ws] error:', e.message));
});

await new Promise<void>((resolve) => server.listen(PORT, '127.0.0.1', resolve));
console.log(`[mock-ws] listening on ws://127.0.0.1:${PORT}`);

for (const sig of ['SIGTERM', 'SIGINT'] as NodeJS.Signals[]) {
  process.on(sig, () => {
    wss.close();
    server.close(() => process.exit(0));
  });
}
```

- [ ] **Step 2: Verify it starts and accepts a connection**

```bash
npx tsx scripts/mock-ws-server.ts &
MOCK_PID=$!
sleep 1
node -e "
const WebSocket = require('ws');
const ws = new WebSocket('ws://127.0.0.1:8765');
ws.on('open', () => { ws.send(JSON.stringify({type:'auth', token:'x', platformId:'test'})); });
ws.on('message', m => { console.log('got:', m.toString()); ws.close(); });
ws.on('close', () => process.exit(0));
"
kill $MOCK_PID
```
Expected: prints `got: {"type":"auth_ok",...}`.

- [ ] **Step 3: Commit**

```bash
git add scripts/mock-ws-server.ts
git commit -m "feat: mock WS server for iOS XCUITest"
```

---

## Task 5: iOS project — add JarvisUITests target

**Files:**
- Modify: `ios/JarvisApp/project.yml`

- [ ] **Step 1: Add the UITest target**

In `ios/JarvisApp/project.yml`, append the following to the `targets:` section (after the `JarvisApp:` block, at the same indentation level):

```yaml
  JarvisUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - path: Sources/JarvisUITests
    dependencies:
      - target: JarvisApp
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.vasechko.jarvis.uitests
        TEST_TARGET_NAME: JarvisApp
        SWIFT_VERSION: "5.9"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: 24Z6S27D7U
```

- [ ] **Step 2: Create the test source directory**

```bash
mkdir -p ios/JarvisApp/Sources/JarvisUITests
```

- [ ] **Step 3: Regenerate the Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```
Expected: no errors. `JarvisApp.xcodeproj` updated.

- [ ] **Step 4: Verify the new scheme exists**

```bash
xcodebuild -project ios/JarvisApp/JarvisApp.xcodeproj -list
```
Expected: `JarvisUITests` appears in the schemes or targets list.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/project.yml
git commit -m "feat(ios): add JarvisUITests xcodegen target"
```

---

## Task 6: iOS test mode — isUITesting flag + AppSettings override

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift`

- [ ] **Step 1: Add isUITesting to JarvisApp**

In `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift`, add the static property inside the `JarvisApp` struct, right after `@UIApplicationDelegateAdaptor(AppDelegate.self) var delegate`:

```swift
static var isUITesting: Bool {
    ProcessInfo.processInfo.arguments.contains("--uitesting")
}
```

- [ ] **Step 2: Override isConfigured in AppSettings**

In `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift`, change `isConfigured`:

```swift
var isConfigured: Bool {
    JarvisApp.isUITesting || (!serverURL.isEmpty && !bearerToken.isEmpty)
}
```

- [ ] **Step 3: Verify build**

```bash
cd ios/JarvisApp && xcodebuild build \
  -project JarvisApp.xcodeproj \
  -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift \
        ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift
git commit -m "feat(ios): isUITesting flag + AppSettings test override"
```

---

## Task 7: WebSocketClient — test URL and token override

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`

In test mode, `doConnect` must use `ws://127.0.0.1:8765` as the URL and `"uitest-token"` as the auth token (the mock server accepts any token; using a distinct value avoids accidentally hitting a real server).

- [ ] **Step 1: Modify doConnect**

Replace the current `doConnect` signature and first guard lines:

```swift
// BEFORE:
private func doConnect(settings: AppSettings) {
    guard !stopped, !settings.serverURL.isEmpty else { return }
    var s = settings.serverURL

// AFTER:
private func doConnect(settings: AppSettings) {
    guard !stopped else { return }
    let rawUrl: String
    let authToken: String
    if JarvisApp.isUITesting {
        rawUrl = "ws://127.0.0.1:8765"
        authToken = "uitest-token"
    } else {
        guard !settings.serverURL.isEmpty else { return }
        rawUrl = settings.serverURL
        authToken = settings.bearerToken
    }
    var s = rawUrl
```

Then change the auth payload to use `authToken` instead of `settings.bearerToken`:

```swift
// BEFORE:
guard let auth = try? JSONSerialization.data(withJSONObject: [
    "type": "auth",
    "token": settings.bearerToken,
    "platformId": settings.platformId,
] as [String: Any]) else { return }

// AFTER:
guard let auth = try? JSONSerialization.data(withJSONObject: [
    "type": "auth",
    "token": authToken,
    "platformId": settings.platformId,
] as [String: Any]) else { return }
```

- [ ] **Step 2: Verify build**

```bash
cd ios/JarvisApp && xcodebuild build \
  -project JarvisApp.xcodeproj \
  -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift
git commit -m "feat(ios): override WS URL and token in UI testing mode"
```

---

## Task 8: Accessibility identifiers

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/OrbInputBar.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/EmptyStateView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/MessageBubble.swift`

- [ ] **Step 1: OrbHomeView — orb-home + home-orb**

In `OrbHomeView.swift`, add `.accessibilityIdentifier("orb-home")` to the outer VStack in `body`. The `body` starts with:

```swift
var body: some View {
    VStack(spacing: 0) {
        // Header
        header
        // Content — ...
        VStack(spacing: 0) { ... }
    }
    .background { ... }
    .preferredColorScheme(.dark)
```

Add after `.preferredColorScheme(.dark)`:

```swift
.accessibilityIdentifier("orb-home")
```

Also in `orbCluster`, add `.accessibilityIdentifier("home-orb")` to the `OrbView`:

```swift
OrbView(size: Theme.orbSize, mood: showSatellites ? .heroic : .welcoming)
    // ... existing modifiers ...
    .accessibilityLabel("Начать диалог")
    .accessibilityIdentifier("home-orb")   // ← add this
```

- [ ] **Step 2: ChatView — chat-view**

In `ChatView.swift`, `body` starts with:

```swift
var body: some View {
    VStack(spacing: 0) {
        // MARK: – Custom header
        header
```

Add `.accessibilityIdentifier("chat-view")` at the end of the `VStack` modifier chain, right before or after `.animation(...)`:

```swift
.animation(.spring(duration: 0.4, bounce: 0.15), value: visibleMessages.isEmpty)
.accessibilityIdentifier("chat-view")
```

- [ ] **Step 3: OrbInputBar — message-input + send-btn**

In `OrbInputBar.swift`, inside `composeRow`, the `TextField` is:

```swift
TextField("Спросить Jarvis...", text: $text, axis: .vertical)
    .font(.system(size: Theme.fontInput))
    // ... existing modifiers ...
    .onSubmit { ... }
    .submitLabel(enterToSend ? .send : .return)
```

Add `.accessibilityIdentifier("message-input")` after `.submitLabel(...)`:

```swift
.submitLabel(enterToSend ? .send : .return)
.accessibilityIdentifier("message-input")
```

The send `Button` has `.accessibilityLabel("Отправить")`. Add `.accessibilityIdentifier("send-btn")` to it:

```swift
Button { ... } label: { ... }
.frame(width: Theme.minTapSize, height: Theme.minTapSize)
.disabled(!canSend || isDisabled)
.accessibilityLabel("Отправить")
.accessibilityIdentifier("send-btn")
```

- [ ] **Step 4: EmptyStateView — empty-start-text**

In `EmptyStateView.swift`, the keyboard button:

```swift
Button { onStartText() } label: {
    HStack(spacing: Theme.scaled(4)) {
        Image(systemName: "keyboard")
        Text("или введите запрос")
    }
    ...
}
.frame(minHeight: Theme.minTapSize)
```

Add `.accessibilityIdentifier("empty-start-text")` after `.frame(minHeight: Theme.minTapSize)`:

```swift
.frame(minHeight: Theme.minTapSize)
.accessibilityIdentifier("empty-start-text")
```

- [ ] **Step 5: MessageBubble — bubble-user-<id> + bubble-assistant-<id>**

In `MessageBubble.swift`, `textBubble` ends with:

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel(accessibilityDescription)
```

Add `.accessibilityIdentifier(...)` after `.accessibilityLabel(...)`:

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel(accessibilityDescription)
.accessibilityIdentifier(isUser ? "bubble-user-\(message.id)" : "bubble-assistant-\(message.id)")
```

- [ ] **Step 6: Verify build**

```bash
cd ios/JarvisApp && xcodebuild build \
  -project JarvisApp.xcodeproj \
  -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift \
        ios/JarvisApp/Sources/JarvisApp/Components/OrbInputBar.swift \
        ios/JarvisApp/Sources/JarvisApp/Components/EmptyStateView.swift \
        ios/JarvisApp/Sources/JarvisApp/Components/MessageBubble.swift
git commit -m "feat(ios): add accessibility identifiers for XCUITest"
```

---

## Task 9: XCUITest test cases

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisUITests/JarvisUITests.swift`

The tests assume the mock server is running on port 8765. They launch with `--uitesting` arg which makes the app connect there instead of VDS.

**Navigation flow:**  
`splash` (800ms after auth_ok) → `orb-home` → long press `home-orb` → tap "Текст" → `chat-view` → tap `empty-start-text` → `message-input` + `send-btn` visible

- [ ] **Step 1: Create the test file**

```swift
import XCTest

final class JarvisUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: – Helpers

    /// Wait for orb-home and navigate to chat via long press → Текст
    private func navigateToChat() {
        let orbHome = app.otherElements["orb-home"]
        XCTAssertTrue(orbHome.waitForExistence(timeout: 8), "orb-home not found — splash did not complete")

        let homeOrb = app.otherElements["home-orb"]
        XCTAssertTrue(homeOrb.waitForExistence(timeout: 3))
        homeOrb.press(forDuration: 0.5)  // reveal action satellites

        let textBtn = app.buttons["Текст"]
        XCTAssertTrue(textBtn.waitForExistence(timeout: 2))
        textBtn.tap()

        let chatView = app.otherElements["chat-view"]
        XCTAssertTrue(chatView.waitForExistence(timeout: 5), "chat-view not found after tapping Текст")
    }

    /// Open input bar from empty state
    private func openInputBar() {
        let startText = app.buttons["empty-start-text"]
        XCTAssertTrue(startText.waitForExistence(timeout: 3))
        startText.tap()
    }

    // MARK: – Tests

    func testLaunch() throws {
        let orbHome = app.otherElements["orb-home"]
        XCTAssertTrue(orbHome.waitForExistence(timeout: 8), "App did not reach home screen in time")
    }

    func testOrbTapOpensChat() throws {
        navigateToChat()
        // chat-view existence already asserted inside navigateToChat
    }

    func testSendMessage() throws {
        navigateToChat()
        openInputBar()

        let messageInput = app.textFields["message-input"]
        XCTAssertTrue(messageInput.waitForExistence(timeout: 3))
        messageInput.tap()
        messageInput.typeText("Привет")

        let sendBtn = app.buttons["send-btn"]
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 2))
        sendBtn.tap()

        let bubble = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bubble-user-'")
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), "User message bubble not found after send")
    }

    func testDeliveryFlow() throws {
        // Mock server sends message_ack after send → bubble transitions to .delivered
        navigateToChat()
        openInputBar()

        let messageInput = app.textFields["message-input"]
        XCTAssertTrue(messageInput.waitForExistence(timeout: 3))
        messageInput.tap()
        messageInput.typeText("Test delivery")

        app.buttons["send-btn"].tap()

        let bubble = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bubble-user-'")
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))

        // Allow time for ack round-trip (mock sends ack immediately, delivery update is async)
        Thread.sleep(forTimeInterval: 1.5)

        // App should not crash; bubble still exists in delivered state
        XCTAssertTrue(bubble.exists, "Bubble disappeared after delivery transition")
    }

    func testAssistantReply() throws {
        // Mock server sends assistant message after 500ms
        navigateToChat()
        openInputBar()

        let messageInput = app.textFields["message-input"]
        XCTAssertTrue(messageInput.waitForExistence(timeout: 3))
        messageInput.tap()
        messageInput.typeText("Hello")

        app.buttons["send-btn"].tap()

        let assistantBubble = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bubble-assistant-'")
        ).firstMatch
        XCTAssertTrue(assistantBubble.waitForExistence(timeout: 5), "Assistant reply bubble not found")
    }
}
```

- [ ] **Step 2: Start the mock server and run the tests**

```bash
# Terminal 1: start mock server (keep running)
npx tsx scripts/mock-ws-server.ts

# Terminal 2: run tests
cd ios/JarvisApp && xcodebuild test \
  -project JarvisApp.xcodeproj \
  -scheme JarvisUITests \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -quiet 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`

If any test fails, check the failure message — common issues:
- `orb-home` timeout: splash didn't connect. Verify mock server is on port 8765.
- `home-orb` not found: OrbHomeView long-press element lookup failed. Check accessibility ID placement.
- `message-input` not found: `empty-start-text` tap didn't activate input. Check EmptyStateView ID.

- [ ] **Step 3: Regenerate project after adding the new Swift file**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisUITests/JarvisUITests.swift \
        ios/JarvisApp/project.yml
git commit -m "test(ios): XCUITest suite — launch, nav, send, delivery, assistant reply"
```

---

## Task 10: Combined test runner

**Files:**
- Create: `scripts/test-all.sh`
- Modify: `package.json`

- [ ] **Step 1: Create the runner script**

```bash
#!/usr/bin/env bash
set -eo pipefail

echo "=== Step 1: vitest ==="
pnpm test

echo "=== Step 2: mock WS server ==="
npx tsx scripts/mock-ws-server.ts &
MOCK_PID=$!
cleanup() { kill "$MOCK_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
sleep 1  # give the server time to bind

echo "=== Step 3: xcodegen + xcodebuild UITest ==="
cd ios/JarvisApp
xcodegen generate --quiet
xcodebuild test \
  -project JarvisApp.xcodeproj \
  -scheme JarvisUITests \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -quiet
cd ../..

echo "=== All tests passed ==="
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/test-all.sh
```

- [ ] **Step 3: Add to package.json**

In `package.json`, add `"test:all"` to the `"scripts"` object alongside the existing `"test"` entry:

```json
"test:all": "bash scripts/test-all.sh"
```

- [ ] **Step 4: Run the full suite end-to-end**

```bash
pnpm test:all
```
Expected: vitest passes, mock server starts, XCUITests pass, `=== All tests passed ===` printed.

- [ ] **Step 5: Commit**

```bash
git add scripts/test-all.sh package.json
git commit -m "feat: pnpm test:all — vitest + XCUITest combined runner"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|-----------------|------|
| ios-app.ws.test.ts — WS protocol | Task 2 |
| ios-app.context.test.ts — context injection | Task 3 |
| ReadReceiptStore already covered | ios-read-receipts.test.ts (existing) |
| scripts/mock-ws-server.ts | Task 4 |
| project.yml JarvisUITests target | Task 5 |
| isUITesting + isConfigured override | Task 6 |
| WebSocketClient test URL/token | Task 7 |
| Accessibility identifiers (orb-home, home-orb, chat-view, message-input, send-btn, empty-start-text, bubble-*) | Task 8 |
| 5 XCUITest cases | Task 9 |
| scripts/test-all.sh + package.json | Task 10 |
| Prerequisite: xcodegen installed | stated in spec — not automated here (manual one-time) |

**No placeholders found.**

**Type consistency:** `IosWsHandlerState` defined in Task 1, used identically in Tasks 2 and 3. `createIosWsHandler` signature stable across all tasks.

**Risk note (from spec):** After the `createIosWsHandler` extraction in Task 1, the inline `recordDelivered` and `removeClient` functions in `createIOSAdapter` become dead code and must be deleted. Confirmed in Step 2 of Task 1.
