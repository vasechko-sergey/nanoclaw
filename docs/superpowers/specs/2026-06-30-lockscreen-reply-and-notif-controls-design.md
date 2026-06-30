# Lock-screen reply + per-agent notification controls — design

**Date:** 2026-06-30
**Status:** Approved (brainstorm)
**Builds on:** `2026-06-29-proactive-notifications-design.md` (the no-APNs local-notification rail, shipped as host `4ee46a7f` + iOS build 70).

## Summary

Two extensions to the just-shipped no-APNs local-notification rail:

1. **Reply from the lock screen** — an agent-message notification carries a "Ответить" text-input action. The user types a reply on the lock screen; it routes to that agent as a genuine user message via a new HTTP endpoint (suspend-safe, no WS required).
2. **Per-agent mute + quiet hours** — silence individual agents (e.g. mute Greg, keep Jarvis) and a nightly on-device quiet-hours window that suppresses all agent notifications.

**Explicitly out of scope this cycle:**
- **Approve/Deny notification actions.** Approvals aren't structured-delivered to iOS today (they arrive as plain text DMs). Buttons would need a structured approval envelope + a security-reviewed host approval-resolution endpoint + lock-screen-auth consideration (approving credentialed actions without opening the app). That is its own spec; it rides cleanly on the reply transport built here.
- **`.timeSensitive` interruption level.** The app is signed with a free Personal Team (`24Z6S27D7U`), which can't get the `com.apple.developer.usernotifications.time-sensitive` entitlement. Setting the level would silently degrade to `.active` and pierce no Focus/DND — pointless until a paid team. Omitted.

---

## Section A — Reply from the lock screen

### A.1 Host: `POST /ios/reply`

New route in `src/channels/ios-app/v2/http-handler.ts`, additive and safe.

- **Auth:** Bearer token → `{ platform_id, person_key }` via the existing `resolveToken`. Identity is the token's `platform_id` ONLY — any `platformId` in the body is ignored (same confused-deputy guard as `/ios/proactive` and `/ios/pending`). Unauth → 401.
- **Body:** `{ text: string, agent_id?: string, replyToId?: string }`.
  - `text` required, non-empty after trim; capped (e.g. 4000 chars) — over-cap → 400. (The 2 MB raw-body guard in `readBody` still applies.)
  - `agent_id` optional; defaults to the default agent slug (`jarvis`). It is the agent the user is replying to (carried in the notification's `userInfo`). It is **not** validated against an allow-list here — routing tolerates unknown slugs (falls back to the messaging-group default session, exactly like `resolveSessionForPlatform`), and the slug only ever selects which of the user's OWN agents receives the message, so there's no escalation surface.
  - `replyToId` optional, currently unused server-side (reserved for future threading); accepted and ignored.
- **Routing:** calls a new `routeReply(platform_id, agentId, text)` dependency (see A.2). Returns `{"ok":true}` 200 on success. Malformed JSON / validation failure → 400 with an error message, mirroring the other POST routes.

Add the route to the top-of-file route-inventory comment.

### A.2 Host: `routeReply` wiring in `index.ts`

The HTTP handler must route a reply to a specific agent's session — the same thing the WS path's `routeToAgent` does. Today that logic lives inline in the dispatcher's `routeToAgent` callback (`index.ts` ~line 270), which builds a `chat` message and calls `adapterRouteToAgent(..., agent_group_id)`.

- **Extract** the inbound-build + `adapterRouteToAgent` call into a small shared helper, e.g.
  `routeUserText({ platform_id, agentId, text, threadId }): void`, and have BOTH the dispatcher's `routeToAgent` and the new `routeReply` call it (DRY; one routing path).
- `routeReply(platform_id, agentId, text)` = `routeUserText({ platform_id, agentId, text, threadId: null })`.
  - `threadId: null` is already what `routeToAgent` passes when the envelope has no `thread_id` (`envelope.payload.thread_id ?? null`), and `adapterRouteToAgent` resolves/creates the session for `(platform_id, agent_group_id)`. So no synthetic thread_id is fabricated, and the wire-schema `thread_id.min(1)` constraint is never touched (we bypass the envelope schema — `routeReply` is an internal call, not a wire message).
  - `message.id` = `randomUUID()` (host-generated; HTTP replies have no device seq, so no dedup row / `advanceLastSeenOutbound` — those are WS-cursor concerns and don't apply).
- Wire `routeReply` into `HttpHandlerDeps` and pass it in the `createIosHttpHandler({ ... })` call, next to `listPending`.

**Session edge case:** a notification implies the agent already messaged the user, so a session normally exists. If it was swept, `adapterRouteToAgent` creates one on demand (the normal first-inbound behavior). No special handling needed.

### A.3 iOS: notification category + action

- Register a `UNNotificationCategory` (identifier `"agent-message"`) with one `UNTextInputNotificationAction`:
  - `identifier`: `"reply"`
  - `title`: `"Ответить"`
  - button title: `"Отправить"`, placeholder: `"Сообщение…"`
  - options: none special (`[]`) — replying does not require unlocking; the text routes server-side and the agent's response surfaces later. (Revisit if we ever want `.authenticationRequired`.)
- Register via `UNUserNotificationCenter.current().setNotificationCategories([...])` in `AppDelegate.didFinishLaunching`, right after `requestAuthorization`.
- `LocalNotifier.raise` sets on the content:
  - `content.categoryIdentifier = "agent-message"`
  - `content.userInfo = ["agentId": agentId, "msgId": id]`

### A.4 iOS: `NotificationReplySender`

New service mirroring `PendingNotifications`'s HTTP pattern (http base derivation + `bearerToken` from `UserDefaults`).

- `func send(agentId: String, text: String, completion: @escaping (Bool) -> Void)`
  - POST to `…/ios/reply` with `Authorization: Bearer <token>`, JSON body `{ text, agent_id: agentId }`.
  - On HTTP 200 → `completion(true)`; else/error → `completion(false)`.
- **Local echo:** ONLY after the POST returns 200, persist the reply into the store so it shows in the chat timeline:
  - `store.insertOutboundUserMessage(id: <uuid>, text: text, attachments: [], context: nil, agentId: agentId)`.
  - Success-only is deliberate: a failed POST means the agent never received the reply, so no echo (and no later answer) keeps the timeline coherent rather than showing a phantom sent message. (A future revision could echo-with-failed-status + retry; out of scope here.)
  - **CRITICAL:** `insertOutboundUserMessage` inserts `status='queued'`, which the outbound WS drain (`queuedOutbound`) would later RE-SEND over WS → duplicate message to the agent. The echo MUST be written with a terminal status (e.g. `'sent'`) so the drain skips it. Either add a status param / `insertSentUserMessage` variant, or insert then immediately mark the row sent. The plan must verify the exact terminal status string the drain treats as "do not send" (`queuedOutbound` filters `status='queued'`).
  - The store reference is configured at app init (same hook as `LocalNotifier.configure(store:)`).
- Idle-safe: uses `URLSession.shared` within the notification-response handler's execution window.

### A.5 iOS: handle the action in `AppDelegate.didReceive`

`AppDelegate` is already the `UNUserNotificationCenterDelegate`; `didReceive response` exists (currently a no-op `completionHandler()`).

- If `response.actionIdentifier == "reply"`, `response is UNTextInputNotificationResponse`:
  - read `userText`, and `agentId` from `response.notification.request.content.userInfo` (default `"jarvis"`).
  - call `NotificationReplySender.shared.send(agentId:text:) { _ in completionHandler() }` — call `completionHandler()` only after the POST resolves (bounded; the system keeps the app alive for the handler, ~30s).
- Otherwise fall through to the existing `completionHandler()`.

The wiring from delegate → sender uses the same static-shared/`configure` pattern as `LocalNotifier` (the `AppDelegate.dispatchProactive` hook is the in-tree precedent).

---

## Section B — Per-agent mute + quiet hours (iOS only, no host change)

### B.1 Settings storage (`AppSettings`)

- **Per-agent mute:** one `@AppStorage("mutedAgents")` JSON string ↔ computed `mutedAgentIds: Set<String>` (agent slugs). Empty by default (nothing muted).
- **Quiet hours:**
  - `@AppStorage("quietHoursEnabled") Bool = false`
  - `@AppStorage("quietStartMinutes") Int = 1380` (23:00, minutes since local midnight)
  - `@AppStorage("quietEndMinutes") Int = 480` (08:00)

### B.2 `LocalNotifier.raise` gating

After the existing `isForeground` / `isEnabled` guards, before building content:

```
guard !isMuted(agentId) else { return }
guard !inQuietHours(now()) else { return }
```

- `isMuted: (String) -> Bool` and `inQuietHours: () -> Bool` (or `(Date) -> Bool`) and `now: () -> Date` are injectable closures with production defaults reading `UserDefaults` (mirrors how `isEnabled` already reads `notificationsEnabled`). This keeps `LocalNotifier` unit-testable with no real settings.
- **Quiet-hours window** (minutes-since-midnight, wraps midnight):
  - `let t = minutes(of: now)` in local time.
  - if `start <= end`: in-window ⇔ `start <= t < end`.
  - if `start > end` (overnight, the default 1380→480): in-window ⇔ `t >= start || t < end`.
  - disabled (`quietHoursEnabled == false`) ⇒ never in-window.
- Gating order: master `notificationsEnabled` OFF already short-circuits via `isEnabled`. Mute and quiet-hours are independent additional suppressors. The per-id dedup (`notifiedSeen`/`recordNotified`) stays AFTER these guards — a suppressed notification is NOT recorded as notified, so if the same message is re-pulled when the user is available again it can still surface. (Acceptable: matches "don't permanently swallow a real message".)

### B.3 Settings UI (`SettingsView`)

Promote the single "Уведомления" toggle into its own `settingsSection(title: "Уведомления")`:

- master toggle (existing `notificationsEnabled`),
- 5 per-agent rows — `AgentIdentity.allCases`, each a toggle bound to a mute binding (`displayName` + `accentColor`); ON = notifications allowed, OFF = muted (invert the stored "muted" set so the UI reads naturally),
- quiet-hours enable toggle,
- two time rows (start / end) — `DatePicker(.hourAndMinute)` mapped to/from minutes-since-midnight, shown only when quiet hours is enabled.

Keep the existing `settingsSection` / `settingsToggle` styling; the time rows are a small custom row.

---

## Section C — Testing, version, deploy

### C.1 Host tests

`src/channels/ios-app/v2/reply-endpoint.test.ts` (mirror `image-endpoint.test.ts` / `http-routes.test.ts` harness; add a `routeReply` spy to the handler deps):
- unauth → 401;
- valid body → 200 AND `routeReply` called once with `(token's platform_id, agent_id, text)`;
- missing/empty `text` → 400, `routeReply` not called;
- over-cap `text` → 400;
- missing `agent_id` → defaults to `jarvis`;
- body `platformId` is ignored — routing uses the token's `platform_id` (no cross-person injection).

Existing `http-routes.test.ts` / `image-endpoint.test.ts` may need a `routeReply: () => {}` stub added to their handler-deps construction (tsc will flag the new required dep).

### C.2 iOS tests (`JarvisAppTests`, module `Jarvis`)

- **`LocalNotifierTests`** (extend): muted agent → `schedule` NOT called; quiet-hours active → NOT called; quiet-hours inactive + unmuted + backgrounded + enabled → called once. (Inject `isMuted` / `inQuietHours` / `now`.)
- **`QuietHoursTests`** (new): pure `inQuietHours` logic — overnight window 1380→480: 23:30→true, 07:00→true, exactly 08:00→false, exactly 23:00→true, 12:00→false; same-day window 480→1380: boundaries; disabled → always false.
- **`NotificationReplySenderTests`** (new): with a stubbed HTTP layer (seam the request the way `PendingNotificationsTests` stubs its fetch), `send` issues a POST to `…/ios/reply` with the bearer header and body `{text, agent_id}`; on 200 the local echo is inserted into a stub/temp store with a terminal (non-`queued`) status.

### C.3 Version + build

- iOS change ⇒ bump `CURRENT_PROJECT_VERSION` 70 → **71**; `MARKETING_VERSION` 1.16.0 → **1.17.0** (feature). `xcodegen generate` + commit the regenerated `pbxproj`.
- No new entitlements, no new `Info.plist` keys, no new `BGTaskSchedulerPermittedIdentifiers` (the notification category is a runtime registration).
- Clean iOS sim build + full `JarvisAppTests` run must pass.

### C.4 Deploy

- Host endpoint is additive and safe to ship independently of the iOS build: deploy to the VDS (`git pull --ff-only && pnpm run build && systemctl --user restart nanoclaw`) once host tests are green. Smoke: `POST /ios/reply` unauth → 401.
- iOS build 71 → user installs on device (signing — user's manual step).

### C.5 Build order

1. Host: `routeUserText` extraction + `routeReply` + `POST /ios/reply` + `reply-endpoint.test.ts` (and stub fixes).
2. iOS reply: category registration, `LocalNotifier` content (category + userInfo), `NotificationReplySender` (+ terminal-status echo), `AppDelegate.didReceive` handling, `NotificationReplySenderTests`.
3. iOS controls: `AppSettings` (mute set + quiet-hours), `LocalNotifier` gating, `QuietHoursTests` + `LocalNotifierTests` extension, `SettingsView` UI.
4. Version bump 71 / 1.17.0 + `xcodegen` + clean build + full test run.
5. Deploy host to VDS; hand iOS build to user.

Subagent-driven execution (fresh implementer per task + spec-compliance + code-quality review), as the prior cycle.

## Acceptance criteria

- Backgrounded (not force-quit) app, agent sends a message → lock-screen notification with a "Ответить" action; typing a reply and sending delivers it to that agent (visible as the agent's subsequent response), with the user's reply shown in the chat timeline and NOT double-sent on reconnect.
- A muted agent raises no notification; other agents still do.
- Within the quiet-hours window, no agent raises a notification; outside it, they do.
- Master "Уведомления" OFF suppresses everything (unchanged).
- Host `POST /ios/reply` rejects unauth (401) and routes only by the token's platform_id.
