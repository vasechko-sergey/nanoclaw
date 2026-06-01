# NanoClaw / Jarvis architecture audit — 2026-05-29

Senior-architect due-diligence pass on a stranger's project. I read the
code first; the README and `CLAUDE.md` were skimmed only at the very end
to cross-check the story against reality.

## 1. Project shape

Two trees that genuinely belong in one repo: a Node/TypeScript host
under `src/` (538 lines `router.ts`, 543 `session-manager.ts`, 515
`container-runner.ts`, 430 `delivery.ts`, ~213 `index.ts`) and a SwiftUI
client under `ios/JarvisApp/Sources/JarvisApp/`. There's also a
container-side agent runtime in `container/agent-runner/` that runs
inside per-session Docker/Apple containers, and a `groups/` directory
holding the user's actual installation state (`jarvis`,
`health-analyzer`). The split between framework code and per-install
state mostly works, except for one egregious leak I'll come back to.

The repo root is busier than it ought to be — three localized READMEs,
two migration shell scripts, a `setup.sh`, a `nanoclaw.sh`,
`migrate-v2-reset.sh`, `migrate-v2.sh`. There's a `dist/` directory
checked in alongside `src/` (the tsconfig must emit there). For a
project that's already shipped a v1→v2 rewrite, this clutter is
expected; for a "clean v2," it isn't.

The `docs/` directory is genuinely useful: separate writeups for the
three-DB model, the session-DB schema, isolation, the build/runtime
split, and a v1→v2 diff. Then `docs/superpowers/specs/` and
`docs/superpowers/plans/` hold seven specs and ten plans dated
2026-05-25 through 2026-05-29 — a five-day blitz of writing about iOS
features. More on that in §5.

## 2. Host architecture

### Does the code match the story?

Yes, mostly, and the story is unusually crisp. The advertised invariant
is "everything is a message; the two session SQLite DBs are the sole IO
surface between host and container." When you walk the actual code
that holds up. `router.ts` writes `messages_in` and wakes a container;
`delivery.ts` reads `messages_out`; `host-sweep.ts` reconciles
`processing_ack` and heartbeat-file mtime; `container-runner.ts`
mounts the session dir and execs `bun run /app/src/index.ts`. There is
no stdin pipe, no shared in-memory bus, no Unix socket between host and
agent. The discipline is real.

The one place the model leaks is `delivery.ts` dynamically importing
`./modules/scheduling/recurrence.js` and `./modules/agent-to-agent/agent-route.js`
from inside the polling loop, guarded by `hasTable()` checks against the
*central* DB to decide whether an *optional module* is installed. That's
clever — it keeps the module barrel honest about being optional — but
it's also one more thing that depends on a table existing for control
flow, and it means a partial migration can change behavior at runtime.

### Message flow

A platform message arrives at a channel adapter, gets wrapped into an
`InboundEvent`, and lands at `routeInbound(event)` in `router.ts`. The
function reads cleanly top-to-bottom: pre-route interceptor →
adapter-thread-policy normalization → combined messaging-group lookup
(with agent count, to short-circuit unwired channels in one DB read) →
optional auto-create → sender resolution via a registered hook → fan-out
across wired agents (each independently evaluated for engagement,
access, scope) → write to `inbound.db` → wake container.

The fan-out is the most architecturally interesting bit: one inbound
event can land in multiple per-agent session DBs simultaneously, with
the `messageIdForAgent` helper namespacing the message id by
`agent_group_id` to keep the per-session primary key unique. That's
exactly the right choice for the "many agents in one chat" use case;
it would have been very easy to half-bake.

Reply delivery in `delivery.ts` runs two poll loops (active 1s, sweep
60s) and uses an `inflightDeliveries` Set to keep the two from
double-delivering the same row. The retry counter lives in-memory
(resets on process restart, which is deliberate per the comment).
System actions are registered via a `Map<string, handler>` registry so
modules can plug in without modifying core. Both the registry pattern
and the in-memory inflight set are right-sized for the workload.

### Are the abstractions earning their keep?

Mostly yes. The "hook" pattern — `setSenderResolver`,
`setAccessGate`, `setSenderScopeGate`, `setMessageInterceptor`,
`setChannelRequestGate`, `setDeliveryAdapter`, `setTypingAdapter`,
`onDeliveryAdapterReady`, `registerDeliveryAction` — looks like a lot
when you list them in one paragraph, but each one corresponds to a real
seam between core and an optional module (permissions, typing,
scheduling, etc.). The comment on each hook explains what happens
without it. That's documentation discipline I rarely see.

`session-manager.ts` is the most rule-laden file in the host — it owns
the cross-mount SQLite invariants (`journal_mode=DELETE`,
open-write-close per op, single writer per file) and the
attachment-safety logic. The invariants are documented in a header
comment that's load-bearing: the rules look paranoid until you remember
WAL doesn't refresh -shm across a Docker bind mount and DELETE-mode
journal-unlink isn't atomic. The attachment defense pipeline (basename
check → lstat for symlink → realpath containment → `wx` flag on
write) is a deliberate, layered defense against a compromised
container pre-placing symlinks. Good.

### Riskiest thing

The container is `--rm` (line 408 of `container-runner.ts`), and the
comment on the build script confirms: "container logs are lost after
the container exits." If the agent silently fails inside the container
— a TypeError in the agent-runner, a Bun-version regression, a stale
mount — there is no persistent log. The host sweep catches the
"claimed a message then went silent" case via the heartbeat file, but
the diagnostic story for "container crashed, message stuck pending,
heartbeat never written" is bad. A new engineer debugging "why doesn't
the agent reply" would have nothing to look at on the host side except
`logs/nanoclaw.log` showing a spawn event and an exit code.

The DB layer is fine. Three SQLite files (one central + two per
session), with the cross-mount footguns called out in the
`session-db.ts` and `session-manager.ts` headers. The fact that `host
even seq, container odd seq` is documented but not enforced anywhere I
saw in core is a minor pothole — it relies on the agent-runner doing
the right thing and the host always going through `nextEvenSeq`.

### Channel adapter seam

The adapter contract in `src/channels/adapter.ts` is small and well
chosen: `setup`, `teardown`, `isConnected`, `deliver`, plus optional
`setTyping`, `syncConversations`, `resolveChannelName`, `subscribe`,
`openDM`. The big design call is `supportsThreads: boolean`, with the
router applying the policy: non-threaded adapters get their thread ids
nulled at the top of `routeInbound`. Adding a new channel is genuinely
"implement this interface, call `registerChannelAdapter`" — the iOS
adapter in `src/channels/ios-app.ts` is a clean example, modulo the
problem I'm about to flag.

## 3. iOS app architecture

### Layout and sizes

Components (14 files), Models (5), Services (19), Utility (4),
Views (10). Total ~5,900 lines of Swift across the app target. The
folder taxonomy is mostly right — Services owns service-level
singletons, Models owns plain data, Views owns SwiftUI, Components
owns reusable view fragments, Utility is the catch-all. `Theme.swift`
sits in Utility but it's really a design-system token bag.

### The big files

`WebSocketClient.swift` is 662 lines, and it is doing too much. By my
count it handles: connection lifecycle and reconnect with backoff,
heartbeat pings and pong-timeout reconnect, APNs token forwarding,
outbox flushing with retry policy and stale-sent bumping, conversation
routing of inbound messages (active vs background, dedup), system /
status / action / file / image / text message-type dispatch,
delivery-status state machine on UI rows, message_ack handling,
auto-speak triggering, context-pull response, feedback,
message_delivered + message_read receipts, proactive envelope, and the
test seams for all of the above. That's a god-object on the iOS side
just as much as anything on the server. Half of it ought to be split
into `WSTransport` (sockets + reconnect), `OutboxFlusher`,
`InboundRouter`, and a thin `WebSocketClient` facade.

`AppCoordinator.swift` (252 lines) is at the boundary of "coordinator"
and "god object." It owns 9 services (outbox, ws, store, location,
health, calendar, speech, proactiveDispatcher, watchBridge), wires
seven callbacks, and is the only thing that knows how the pieces fit.
That's expected at this app size; it would become a problem at 2x.

`ChatView.swift` is 603 lines, `OrbHomeView.swift` is 579,
`ConversationListView.swift` is 503, `SettingsView.swift` is 385. These
are all view files that should each be ~150 lines but aren't, because
SwiftUI invites you to inline a lot. Not a crisis, but if anyone wants
to add a new chat feature they're editing a 600-line view.

`Theme.swift` (119 lines) is actually fine. It's a design-system token
bag with adaptive scaling — colors, font sizes, corner radii, spacings,
animation durations, and five haptic helpers. The only thing it does
that doesn't belong is reading `UIApplication.shared.connectedScenes`
on every access of `scale` (lines 8–17 and 81–85). That's a hot path
for a token lookup — cache it in a property the scene-update lifecycle
refreshes.

### Message flow on the client

User types → `ChatView.sendCurrent` → `coordinator.sendMessage` →
`WebSocketClient.send`. Inside `send`: the message is appended to the
UI list as `.sending`, enqueued into the outbox, then `flushOutbox`
attempts immediate delivery. On reconnect the outbox replays; on
`message_ack` from the server the row flips to `.delivered` and the
outbox entry is removed; if no ack arrives within 30s the row is
bumped to `.failed` and the next flush retries with backoff. This is
serious offline-first thinking: the outbox is persisted, has bounded
overflow handling, and survives crashes.

Inbound: `receive(ws:)` → `handleIncoming` → dispatch by type to
`route(...)`, which forwards to either the active conversation's
message list (with dedup against assistant ids the host re-flushes on
reconnect) or to a background conversation's store. The agent-pulls-
device-context flow runs through the same `handleIncoming`: server
sends `context_request`, the coordinator's
`onContextRequest` callback gathers the current location / health /
calendar snapshot, and the client replies with `context_response`.

### State / observation

Consistent. Everything observable is `@Observable` (the modern
Swift macro), settings are `@AppStorage` wrapped inside an
`@Observable AppSettings` with `@ObservationIgnored` to prevent double
tracking — that pattern is documented at the top of `AppSettings.swift`
and it's correct. Views consume `@Environment(AppSettings.self)` and
read services off the coordinator. There is no `@StateObject`/
`@ObservedObject`/Combine residue I could find. That's a clean migration
to the new observation model.

### Test coverage

14 unit-test files under `JarvisAppTests/`, 6 UI-test files under
`JarvisUITests/`. The unit tests cover what's testable as pure logic:
`OutboxStore`, `HrSpikeDetector`, `WebSocketClientOutbox`,
`WebSocketClientBusy`, `Heartbeat`, `DeliveryChecks`,
`ConversationSatelliteBuilder`, `ContextBuilder`,
`VoiceLoopController`, `WatchConnectivityBridge`,
`ProactiveDispatcher`, `MessageCacheDeliveryStatus`,
`DraftAttachmentVideo`, `HeaderStatusDot`. That's good triage —
exactly the spots where a regression would silently corrupt user
state (outbox persistence, delivery status, ack handling, heartbeat
timeout).

What's NOT covered: the actual `WebSocketClient.receive` →
`handleIncoming` → `route` dispatch (which is where most of the
650-line monolith's logic lives), the
`AppCoordinator.wireUp` callback graph, the `HealthManager`
observer wiring, the cross-cutting effect of changing
`AppSettings.proactive*` flags. The UI tests are mostly drawer /
voice-fullscreen / thinking-row scenarios — happy path, not
regression coverage of the message dispatch.

A regression would slip through most easily in `handleIncoming`'s
type dispatch (someone adds a new message type, forgets to wire it,
no test catches it) or in the reconnect / dedup path (when the host
re-flushes queued messages on reconnect, the dedup is "id already in
`messages`" — bypassable if the host re-issues a different id).

## 4. Cross-cutting concerns

### Where is the protocol contract written?

It isn't. The WebSocket message types live in two places: the
TypeScript `createIosWsHandler` switch in `src/channels/ios-app.ts`
(lines ~318–515) and the Swift `handleIncoming` switch in
`WebSocketClient.swift` (lines ~525–629). There is no shared schema,
no generated types, not even a markdown doc that both sides reference.
There IS a paragraph at the top of `JarvisApp/CLAUDE.md` that lists
"client → server" and "server → client" message shapes, but that's
informational, not normative — neither side reads it.

Right now this is fine because there's one client and one server and
one human switching between them. The day there's a watchOS-only
release branch, or someone changes the proactive envelope's `tz`
field name, the two halves will drift silently. A single
`docs/ios-protocol.md` with both ends pointing to it would cost almost
nothing.

### Security / auth

iOS app stores `bearerToken` in `@AppStorage` (i.e., `NSUserDefaults`,
not Keychain). The token is hand-typed into Settings by the user; the
server validates a single shared static token in the WS auth handshake
and either accepts or closes with code 4001. Transport is plain `ws://`
when the URL doesn't start with `https://` or `wss://`; in the user's
documented setup they're using a Tailscale-routed `ws://100.x.x.x:3001`,
so the network is locally encrypted by Tailscale, but the iOS adapter
doesn't enforce TLS itself. The HTTP endpoints (`/ios/proactive`,
`/ios/health/upload`, `/ios/health/requests`) accept the same Bearer
token. This is fine for a personal install reachable only over
Tailscale; it would not be fine on a hostile network.

### Error handling

Host side: `routeInbound` is wrapped in `.catch` by every caller in
`src/index.ts`. `wakeContainer` is documented as never-throwing and
returns a bool so callers don't need try/catch. Delivery retries up to
3 attempts, then marks `delivered` row with `status='failed'` so
nothing is silently lost. Sweep retries with exponential backoff up to
5 tries. There's a `circuit-breaker.ts` for rapid-restart backoff.
That's a sensible error budget — failures get surfaced via
`logs/nanoclaw.error.log` or the `dropped_messages` table.

iOS side: every WS send has a `print("WS send failed: \(e)")` on the
completion handler — no retry, no UI surface. The outbox layer ABOVE
the send does have retry, but several of the send paths
(`sendFeedback`, `sendActionResponse`, `sendContextResponse`,
`sendMessageDelivered`, `sendMessageRead`, `sendProactive`,
`sendApnsToken`) bypass the outbox entirely and just print on error.
Feedback and read receipts probably tolerate the loss; a dropped
`action_response` is silently swallowed and the user wonders why
nothing happened. Those should either go through the outbox or have
their own retry.

### Observability

Host: structured `log.info` / `log.warn` / `log.error` with a
`{ context }` object on each call; logs land in
`logs/nanoclaw.log` and `logs/nanoclaw.error.log`. The setup process
has per-step logs under `logs/setup-steps/`. The DBs are inspectable
with the in-tree `scripts/q.ts` wrapper. That's enough.

Container: nothing persists after exit. If the agent crashed mid-turn
you have a `processing_ack` row that times out and gets retried.

iOS: 30+ `print(...)` calls across `WebSocketClient`, `SpeechManager`,
`OutboxStore`, `MessageCache`, `WatchConnectivityBridge`. No
structured logger, no rotation, no upload. You'd debug a production
issue by attaching Xcode to a running instance.

## 5. Plans and specs

Ten plans (`docs/superpowers/plans/`) and seven specs
(`docs/superpowers/specs/`) dated within five days of the audit. All
of them are iOS-side: chat redesign, navigation cleanup,
reliability, conversation satellites, media, proactive triggers, voice
fullscreen, watch companion, delivery-status read-receipts, automated
testing. By word count this is 16,000+ lines of planning text against
~5,900 lines of iOS code. That's a lot.

To the question of whether the documentation discipline matches the
code discipline: it doesn't. The code has tight, load-bearing comments
right where the invariants live. The plans/specs are more like
brainstorming snapshots — useful while they're current but they
accumulate. None of them are dated as "done" or moved out of the
folder; you can't tell at a glance which represents what shipped. If
the project keeps adding 2-3 plans per day with no archival workflow,
the planning directory will become noise.

The implementation HAS clearly followed the plans (HealthKit observer
queries, watch connectivity bridge, voice loop controller,
ProactiveDispatcher with multiple trigger types, conversation
satellites, drawer animations — they all exist as named services
matching the plan filenames). So this isn't "thin execution under
heavy planning"; it's heavy planning under solid execution, with no
cleanup pass to mark things done.

## 6. Tech debt and shortcuts

**TODOs:** one. `src/claude-md-compose.ts:65` — a "respect container
skill selection" TODO that already looks half-implemented. That's
unusually clean for a project this size.

**`@deprecated`:** three. `sessionDbPath` and `openSessionDb` in
`session-manager.ts` are kept for test compatibility. `Session.agent_provider`
in `types.ts` is shadowed by `container_configs.provider`. Each one has a
clear migration note and isn't blocking anything.

**The bad one.** The shipped iOS channel adapter in
`src/channels/ios-app.ts` has `groups/health-analyzer/health/` hardcoded
as the path it writes daily health-history JSONL to (lines 50–52,
referenced again in 70, 75, 92, 94). This is the user's personal
agent-group folder name leaking into framework code. If someone clones
the repo and doesn't have a `health-analyzer` group, every health
upload silently creates that directory under `groups/` whether they
want it or not. If someone renames their analyzer agent, the adapter
breaks. The comment at line 44 even says "Lives INSIDE Greg's group
folder" — referring to the user's personal analyzer agent by its
in-app nickname, in a file that is supposedly part of upstream
infrastructure. This needs to come out of `src/channels/` and live
either as a configurable path on `IosChannelConfig`, or as a separate
module under `groups/health-analyzer/` that the channel adapter
delegates to.

**`print(` calls on iOS:** 30+. Not catastrophic, but
unstructured.

**Logging on the host:** consistent, structured, good. There IS one
`console.log` in `src/channels/ios-app.ts:14` (the iOS adapter's own
`log()` helper writes to console instead of the host's `log` logger).
That makes ios-app the only adapter whose output bypasses the central
log routing.

**Half-finished features:** none I'd flag with confidence. The
codebase's main feature surface is exposed and tested. The plans
folder is the only place "future work" lives, and that's the right
place for it.

**Tech debt that would compound at 10x:**

1. WebSocket protocol with no schema. At 10 channel adapters the
   pattern of "literal string `msg.type === '...'` in two languages
   with no source of truth" is bad. At 1 it's mostly OK.

2. The 662-line `WebSocketClient.swift`. Adding the 10th message type
   to that switch is going to hurt. It already encodes too many
   concerns.

3. Container has no log persistence. Already painful; would be
   crippling with more session volume.

4. Adapter-level state files under `groups/<personal-group>/`. The iOS
   adapter is the only offender, but the pattern is dangerous to
   normalize.

5. The `inflightDeliveries` Set is per-process. Fine for one host; if
   anyone ever splits the host into two roles (router + delivery as
   separate processes) this becomes a duplicate-send.

## 7. Three things I'd do tomorrow

**High leverage:**

1. Fix the hardcoded `groups/health-analyzer/health/` paths in the iOS
   adapter. Either move that directory into a runtime config knob, or
   carve out a small "host-side data sink" module under
   `src/modules/` and let the iOS adapter delegate. This is a 30-line
   change that removes a real install-coupling bug.

2. Split `WebSocketClient.swift` into transport + outbox flusher +
   inbound router. The seams are already there in the comments. Doing
   this now, while the file is 662 lines, is cheap; later it won't
   be.

3. Write `docs/ios-protocol.md` and link both `src/channels/ios-app.ts`
   and `WebSocketClient.swift` to it. Doesn't need to be generated
   types — just a single source of truth that someone touching either
   side has to read.

**Doing more harm than good:**

1. The 17 plan/spec documents with no archival workflow. They should
   either be moved into a `docs/superpowers/done/` directory when
   shipped, or carry a frontmatter `status: shipped|in-progress|
   abandoned`. As-is they'll bury legitimate planning under
   stale-but-recent noise within a quarter.

2. iOS `print(...)` statements scattered through service files. The
   App Store doesn't see them but anyone reading the code does. A
   12-line `Log.swift` with `Log.warn(category:_:)` and a
   `#if DEBUG` print would clean up 30 sites and stop hiding the
   genuine error paths in noise.

3. Reading `UIApplication.shared.connectedScenes` from `Theme.scale`
   on every token lookup. It's called inside `Theme.scaled(_:)` which
   is itself called inside `var fontBody` etc., which view bodies
   recompute. Cache it.

## Closing

This is one of the more thoughtful one-person codebases I've audited.
The invariants are documented at exactly the places they're load-
bearing, the host abstractions earn their keep, the iOS app is a real
offline-first client with persistent outbox and good observability of
delivery state, and the architecture story in `CLAUDE.md` matches what
the code does. The two real problems are the personal-config leak in
the iOS channel adapter and the absence of a shared protocol contract
between client and server. Both are fixable in a day. Everything else
is the normal accretion of a fast-moving solo project.
