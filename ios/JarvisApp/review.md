# JarvisApp — Full Multi-Lens Code Review

**Date:** 2026-07-08
**Scope:** `ios/JarvisApp` — ~15.8k LOC app code, ~6.2k LOC tests, watchOS companion (at MARKETING_VERSION 1.24/1.25 split, see P0-1).
**Method:** five independent full-pass reviews (general dev-infra, iOS platform engineering, architecture, SwiftUI/UI craft, UX/product), findings re-pinned to the current tree; all P0 and key P1 claims re-verified by hand against source.

---

## TLDR

**Two apps in one codebase.** The transport/storage core is production-grade — better than most commercial chat apps (documented postmortems in comments, single-clock ordering, durable queues, kill-proof workout resume). Everything around it — degraded-path UX, accessibility, release hygiene — is hobby-grade. The unifying defect: **the system never admits failure**. There is no terminal error state anywhere, so every permanent failure (bad token, poison message, dropped reply) masquerades as an eternal retry.

## Scorecard

| Lens | Grade | Verdict |
|---|---|---|
| Architecture | **B−** | Right macro-shape (coordinator → actor transport → GRDB source of truth). Facade boundary collapsed: views reach `ws.stack.transport` at 14 sites; 2 of 5 transport classes dead/ceremonial |
| iOS engineering | **B** | Inbound pipeline + reconnect discipline excellent. Failure half missing: `auth_fail` ignored, retries uncapped, TSan races in socket wrapper, 1 real crash path |
| UI / SwiftUI | **B** | Inverted diffable chat list, memoized markdown, frame-gated Canvas orbs — real craft. Zero Dynamic Type, zero Reduce Motion, token discipline collapsed in newest code |
| UX / product | **B−** | Happy path + workout journey polished. Degraded paths systematically weak: offline lockout, unwinnable wrong-token loop, silent reply loss, no unread indication |
| Dev infra / tests | **C+** | ~70 test files, cross-language wire-contract pin, real E2E harness — but zero iOS CI so none of it runs automatically; version split-brain armed; CLAUDE.md makes false claims |

---

## Why it's good

1. **Correctness lessons are captured in code, not lost.** Dedup recorded last, after persist+notify+ack, with the previously-shipped wedge documented in place (`Services/TransportV2.swift:410-417`); UPSERT carve-outs so a redelivery never un-reads or un-edits a message (`Storage/ConversationStoreV2.swift:244-267`); single-clock sort `COALESCE(server_ts, ts)` + rowid tiebreak with the full clock-skew rationale (`Storage/ConversationStoreV2.swift:538-563`). Senior-grade discipline.
2. **Durable-outbox thinking.** Send = insert `queued` row → dispatcher drains on auth → `auth_ok` reconciles acked/unacked (`Services/WebSocketClientV2.swift:258-296`, `Services/TransportV2.swift:186-211`). `SetLogQueue` survives app kill; `ActiveWorkoutStore` restores the exact mid-workout cursor, with a collision dialog preventing a silent UPSERT wipe of a paused workout (`Views/ChatView.swift:666-704`).
3. **Performance work in the right places.** Row→bubble mapping runs on the GRDB reduce queue, not main (`Services/WebSocketClientV2.swift:452-459`); cost-bounded NSCache for decoded bitmaps (128 MB, `WebSocketClientV2.swift:500-508`); markdown parse double-memoized + prewarmed off-main (`Components/MarkdownText.swift:103-127,251-268`, `Services/ChatPrewarmer.swift`); orbs frame-gated per mood (30/12fps/static) and paused on scene-inactive (`Components/OrbView.swift:84-100`).
4. **Test substance.** 24 shared JSON fixtures asserted on both the Swift and TS sides — a genuine cross-language wire-contract pin (`JarvisAppTests/ProtocolFixtureTests.swift:34`, `shared/ios-app-protocol/fixtures.test.ts`). Real-socket E2E harness (`JarvisAppTests/E2E/`). Injectable timeouts/backoff/watchdog. Regression tests that encode bug stories, not change-detectors.
5. **Reconnect state machine.** Reentrancy guard, generation-tagged connect watchdog, backoff reset on auth, never stranding `.connecting` (`Services/TransportV2.swift:110-199`); deliberate WS teardown on background with a written justification of the background-storm failure mode it prevents (`Services/WebSocketClientV2.swift:390-399`).

## Why it's bad

### 1. The system cannot fail — and that's a bug

One systemic hole, surfaced independently by three lenses:

- **`auth_fail` is silently ignored.** The protocol decodes it (`Protocol/V2.swift:19,54`) but `handleIncoming` has no `.authFail` case — falls to `default: break` (`Services/TransportV2.swift:291`). Wrong/rotated token → infinite reconnect hammer; UI shows generic "не удалось установить связь". Worse: the token is captured once at stack build (`Services/WebSocketClientV2.swift:160-207`), so fixing it in Settings does nothing until force-quit. **Unwinnable loop.**
- **`markFailed` has zero callers** (`Storage/ConversationStoreV2.swift:134`); ack-retry re-sends every 5s uncapped (`Services/TransportV2.swift:507-519`). The failed state, retry button (`Components/DeliveryChecks.swift:60-69`), and `resetFailedToQueued` are all dead UI. A poison message = a multi-MB frame re-sent every 5s forever behind an eternal "sending" spinner.
- **Lock-screen reply text is dropped silently on failure.** Non-200/network error → log + `completion(false)`, text gone (`Services/NotificationReplySender.swift:23-33`). No queue, no retry, no failure notice.

### 2. Fire-and-forget workout sends = data loss

`workout_complete` — the most valuable event of a 60-minute session — is sent as `Task { try? await coordinator.ws.stack?.transport.sendWorkoutComplete(...) }` from a view closure (`Views/ChatView.swift:255`): nil stack silently skips, socket-down error swallowed, no durable queue, no retry. TransportV2 documents these envelopes as "no store side-effect, no ack tracking" (`Services/TransportV2.swift:610-616`). The codebase contains the exact fix pattern (`SetLogQueue`), built after learning this same lesson once — not reapplied. Same for `workout_abort` and `exercise_swap_confirm` (`ChatView.swift:258,573`).

### 3. Offline lockout contradicts the queue underneath

`isDisabled: !ws.isConnected` (`Views/ChatView.swift:428`) greys the input the moment the socket wobbles — while a complete durable queue-then-drain pipeline sits unused beneath it. "Продолжить автономно" yields a read-only app. Daily-life tax (flights, subway, flaky LTE).

### 4. Accessibility integration ≈ zero

- **No Dynamic Type anywhere.** `Theme.scaled()` scales by *screen width*, never the user's text-size setting (`Utility/Theme.swift:19-39`); message body hardcoded 14pt (`Components/MessageRow.swift:82`). False confidence: the codebase *looks* adaptive, and the homegrown mechanism occupies the place where `@ScaledMetric` should be. 133 font call sites all ignore the accessibility slider.
- **Reduce Motion never consulted.** Orbs rotate continuously, `repeatForever` pulses in banners/rings, no opt-out (`Components/OrbView.swift:94-100`, `Components/ConnectionBanner.swift:19-23`).

### 5. Docs lie to the next agent

`ios/JarvisApp/CLAUDE.md` claims, all false against code:
- APNs push path — **no APNs code exists**: no `registerForRemoteNotifications`, no `aps-environment` entitlement (contradicted correctly by `TESTFLIGHT-MIGRATION.md:13`).
- "Min iOS: 16.0" — actual deployment target 18.0 (`project.yml:5`).
- Tailscale fallback (100.94.184.60) — no fallback in code; `ServerConfig.swift:14` is the only endpoint.
- MessageTimeline drives the UI — it is never started and has zero consumers (`Services/AppCoordinator.swift:141-145`); ChatView reads `ws.messages`.
- 4 agents — code has 5 (`gordon`, `Models/AgentIdentity.swift:17-22`).
- Tables `conversations`/`attachments`/`kv`, index `idx_msg_conv_ts`, `prune(agentId:keep:)` — all dropped/renamed by migrations v3/v6 (`Storage/Schema.swift:65-137`); actual signature `prune(keep:)`.
- In-code variant: `AgentIdentity.swift:25-29` promises a `health-analyzer`→`.greg` alias; `init?(rawValue:)` has no such case — if the host ever stamps the folder slug, Greg's replies get filtered out of the UI.

In this repo, agents act on CLAUDE.md — each false claim is a future wasted debugging session.

### 6. Release hygiene armed traps

- **Version split-brain:** committed `project.pbxproj` says `1.25.0`/`94`; `project.yml:76-77` — the declared single source of truth — says `1.24.0`/`93`. The documented workflow (run `xcodegen generate` after any file add) silently regresses the version; TestFlight requires monotonic build numbers (`TESTFLIGHT-MIGRATION.md:172`).
- **Zero iOS CI.** `.github/workflows/ci.yml` is ubuntu/Node only. The Swift half of the wire contract and all ~70 test files run only on manual Cmd-U. No shared scheme (`xcshareddata` absent) — a fresh clone can't run tests headless.
- **ATS globally disabled** (`NSAllowsArbitraryLoads: true`, `project.yml:46-47`) with no current cleartext endpoint to justify it.
- **Bearer token in plaintext UserDefaults** — the single credential to chat history + health uploads (`Models/AppSettings.swift:9`), with 6 more raw `UserDefaults.standard.string(forKey: "bearerToken")` readers scattered across services. No Keychain usage anywhere.
- Tracked `xcuserdata` (3 files, one binary `.xcuserstate`; one churns in git status on every Xcode open).

### 7. Dead weight, duplication, boundary decay

- **~580 lines dead UI** still in target: `Components/InputBar.swift` (struct part), `Components/OrbInputBar.swift`, `Views/AgentPickerInline.swift` — zero call sites; CLAUDE.md still describes them as current.
- **`MessageTimeline` dead but wired** — and its `insertInboundIfNew` records dedup *before* insert (`Storage/MessageTimeline.swift:85-90`): the exact wedge ordering `TransportV2` documents as a fixed production bug. Landmine API for any future caller.
- **Two parallel context subsystems.** Live pull path (`TransportV2.handleContextRequest` → `InboundDispatcherV2` → `AppContextCoordinator`) **bypasses the privacy toggles** — health/location/calendar ship even when switched off (`Services/AppContextCoordinator.swift` has zero settings checks). The settings-respecting `ws.onContextRequest` wiring (`Services/AppCoordinator.swift`) is declared and never invoked.
- **Facade collapsed:** `ws.stack` reached from views at 14 sites in ChatView alone (`Views/ChatView.swift:161,181,201,217,255,258,568,571,573,595,694`), plus a `stackReady` flag added just to let views poll the stack's build lifecycle. The 4-layer transport design exists in file structure, not in the call graph.
- ~320 lines of drawer/gesture code duplicated verbatim between `ChatView` and `OrbHomeView`; 3 URL normalizers; `spaced()` ×3; `WebSocketClientV2` imports SwiftUI+UIKit and does image decoding — a view-model living in the transport layer.

### 8. Assorted verified bugs

| Bug | Where |
|---|---|
| Empty-exercise plan → index-out-of-range crash in runner (tolerant decode `?? []` + unguarded `exercises[previewIdx]`) | `Models/Workout.swift:130`, `Views/WorkoutView.swift:101` |
| Mic restarts **after** voice screen dismissed — untracked polling tasks call `speech.start()` post-`onDisappear`; orange-dot privacy bug | `Views/OrbVoiceView.swift:298-320` vs `:191-200` |
| `@State` feedback thumbs leak across recycled cells; never persisted | `Components/MessageRow.swift:26` + `Components/MessageListView.swift:96-102` |
| Full snapshot re-diff on every ChatView body pass — up to 120Hz during drawer drags over 500 items | `Components/MessageListView.swift:68-70,164-216` |
| `set_log` drains only on `auth_ok` — live coach-hint loop inert while connected | `Services/WorkoutCoordinator.swift:83-106`, `Services/WebSocketClientV2.swift:735-740` |
| `URLSessionWebSocket` `@unchecked Sendable` with real races (`task`/`session`/`pingTimer`/`didFireClose` across actor thread, URLSession queue, main timer); header threading claim is wrong | `Services/URLSessionWebSocket.swift:16-21,65-110` |
| Cold-launch storm: first observation emit treats whole history as new → haptic + watch push per historical row | `Services/WebSocketClientV2.swift:461-490` |
| `tickDispatcher` not gated on `.authed` — offline sends stuck at "sending", not "queued" | `Services/TransportV2.swift:202-211` |
| Failed health upload still stamps "done for today" — no retry until tomorrow, stale data silently | `Services/HealthUpload.swift:35-37`, `Services/HealthSync.swift:142-151` |
| `inbound_dedup` never pruned; `ChatImageStore`/`ExerciseImageCache` files never GC'd | `Storage/ConversationStoreV2.swift:191-221`, `Services/ChatImageStore.swift:50-57` |
| Notification deep-link dropped unless `connectionPhase == .connected` — offline tap lands on wrong screen | `Views/ContentView.swift:88-99` |
| No unread indication anywhere; cross-agent replies invisible while foregrounded (haptic only) | `Views/LeftDrawerContent.swift:57-82`, `Services/LocalNotifier.swift:71` |
| Voice fullscreen reacts to any agent's message — proactive Greg message spoken as the answer | `Views/OrbVoiceView.swift:80-88,252-282` |
| Drafts leak across agent switches (single `inputText`/`drafts` state) | `Views/ChatView.swift:29-31` |
| `ActionRow`/`FileRow`/`WorkoutPlanRow` hardcode "JARVIS"/teal regardless of agent | `Components/MessageRow.swift:486,565,659-672` |
| Mic-denied voice mode = permanent fake-"listening", no error, no Settings link | `Services/SpeechManager.swift:44-65` (no consumers), `Views/OrbVoiceView.swift:204-211` |
| No pause/minimize in workout runner — leaving = aborting | `Views/WorkoutView.swift:57-66,141` |
| `Package.swift` vestigial: no test target, `swift test` runs nothing, platform pin drifted (iOS 16 vs real 18) | `Package.swift:8-18` |
| Watch app not embedded in iOS target — never ships in archive; watch dictation has no local echo, errors swallowed | `project.yml:26-28`, `JarvisWatch/WatchAppState.swift:34-55` |
| Orb mood transitions snap and re-phase (Canvas isn't animatable; absolute-t phase math) | `Components/OrbView.swift:138-199,339-349` |
| 28 timing sleeps in tests; 4 perma-skipped E2E skeletons with stale reasons | `WebSocketClientV2Tests.swift`, `E2E/PendingScenariosE2ETests.swift:24-38` |

## The worst part

**No terminal failure state, anywhere.** Auth (`auth_fail` ignored), message send (`failed` unreachable, retries uncapped), lock-screen reply (text dropped), health upload (failure stamps success), Сводка board (`lastError` set, never rendered), location (`didFailWithError` empty). One design blind spot expressed six independent ways. It converts the app's best property — a meticulously correct at-least-once pipeline — into a liability: machinery so good at retrying that nothing ever admits defeat, and the user's only signal is an eternal spinner. The `auth_fail` variant is a guaranteed future incident on the first token rotation.

Close second: workout-complete fire-and-forget — data loss of an hour's work, with the pattern to fix it (`SetLogQueue`) twenty lines away.

## Improvement plan

### Phase 0 — defuse traps (hours, do now)
1. Copy `1.25.0`/`94` into `project.yml:76-77`, regenerate; `git rm --cached` the 3 xcuserdata files; add `**/xcuserdata/` to `.gitignore`.
2. Handle `.authFail` in `handleIncoming`: stop reconnect, surface "токен отвергнут" via `onStateChange`/dedicated callback; re-read token on every `connect()`.
3. Guard empty `exercises` in `startRunning` (1 line). Cancel voice polling tasks in `onDisappear` (mic bug).
4. CLAUDE.md truth pass: delete APNs/Tailscale/MessageTimeline/min-iOS-16/table-schema claims; fix `AgentIdentity` alias comment.

### Phase 1 — failure states + data loss (1–2 days)
5. Cap ack-retry (N≈5) → `markFailed` — wakes up the already-built failed UI + retry button.
6. Route `workout_complete`/`workout_abort`/`exercise_swap_confirm` through a durable outbox (generalize `SetLogQueue`); make `ws.stack` private, expose typed intents on `AppCoordinator`.
7. Lock-screen reply failure → insert as `queued` outbound row (pipeline already drains it on next connect).
8. Enable compose offline (`stack != nil` instead of `isConnected`) — biggest daily-use UX win; infra already exists.
9. Honor privacy toggles in `AppContextCoordinator`/`InboundDispatcherV2` (map to the existing `.denied` error kind).

### Phase 2 — hygiene (2–3 days)
10. Keychain wrapper behind one `TokenProvider` (kills the 7 scattered UserDefaults readers).
11. Delete dead code: `MessageTimeline`, `InputBar` (struct), `OrbInputBar`, `AgentPickerInline`, `onContextRequest`+ContextBuilder pull wiring, `sendProactive`/`sendContextResponse` stubs (~1.2k LOC).
12. macOS CI job: shared scheme in `project.yml` + `xcodebuild test` on a simulator — makes the 70-file suite and the Swift half of the wire-contract pin actually gate changes.
13. Drop `NSAllowsArbitraryLoads`; nudge `drainSetLogQueue` after each enqueue while authed; gate `tickDispatcher` on `.authed`; fix double-drain with an in-flight flag.

### Phase 3 — platform citizenship (a week, incremental)
14. Dynamic Type: route `Theme` tokens through `@ScaledMetric`/`UIFontMetrics` (hosted cells), cap with `.dynamicTypeSize(...upTo:)` where layout requires.
15. Reduce Motion: static orb frame (already exists for scene-inactive) + kill `repeatForever` pulses.
16. Per-agent unread dots in drawer/picker (store already has read status + `countMessages(agentId:)`); per-agent drafts; snapshot-diff early-return on unchanged `messagesVersion`.
17. Extract `DrawerHost` (dedupes ChatView/OrbHomeView); split a ChatTimelineViewModel out of `WebSocketClientV2` (drops SwiftUI/UIKit from the transport layer); force dark scheme once at the WindowGroup root instead of 10 per-view copies.
18. Workout runner "свернуть" (minimize without abort) — resume banner/CTA already exist.

## Bottom line

This codebase's defining instinct — write every bug lesson down where the fix lives — is its superpower and worth preserving over any refactor. Spend effort where the pattern breaks: give failure paths the same rigor as the happy path, and close the `ws.stack` boundary so the next feature can't bypass the good machinery. No rewrite needed; nothing here deserves one.

---

## Appendix — per-lens worst-single-thing

| Lens | Worst thing |
|---|---|
| Architecture | Facade collapse: `ws.stack` reachable from views → fire-and-forget workout sends with silent data loss, despite the durable-outbox precedent existing in-tree |
| iOS engineering | Transport has no concept of terminal failure (`auth_fail` ignored + `failed` unreachable + uncapped retries = one systemic hole) |
| UI / SwiftUI | Complete absence of Dynamic Type, masked by a width-based `Theme.scaled()` that looks adaptive but ignores the accessibility slider |
| UX / product | Offline compose lockout (`ChatView.swift:428`) contradicting ~500 lines of durable-queue infrastructure directly underneath |
| Dev infra | pbxproj/project.yml version split-brain — the documented happy path (`xcodegen generate`) silently regresses the app version |
