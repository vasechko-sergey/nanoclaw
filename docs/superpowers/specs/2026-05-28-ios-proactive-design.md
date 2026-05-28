# iOS — Proactive Awareness: Geofence, Health Observer, Calendar, Persona

**Date:** 2026-05-28
**Scope:** iOS app (`ios/JarvisApp/`) background triggers + minimal server forwarding; agent-side persona update in `groups/jarvis/CLAUDE.md`

## Problem

Today Jarvis is reactive. The agent pulls device context only when the user sends a message or when an MCP `request_context` tool fires. There is no proactive awareness — no "you've arrived at the office", no "you just woke up", no "your meeting starts in 15 min". To approach the JARVIS-from-the-film feel, the device must notice meaningful events and surface them.

Three classes of triggers:

1. **Geofence** — significant location change (~500 m).
2. **Health observer** — HealthKit background delivery for HR spikes, sleep stage end, workout end.
3. **Calendar** — N minutes before next event start.

Plus a **persona** layer so the agent's voice is consistent (butler, dry, brief, context-aware).

## Goals

- iOS app emits **proactive ping** messages to the agent when triggers fire, even when the app is in the background.
- Each ping carries the **why** (trigger type + minimal context).
- Agent decides whether to surface anything to the user (it may choose silence — proactive ≠ noisy).
- **Persona** prompt in `groups/jarvis/CLAUDE.md` so the agent's tone is stable.

## Non-Goals

- Hotword ("Эй Джарвис") wake-word in this spec — separate effort, requires on-device wake detector.
- Lock-screen widget or Dynamic Island — separate spec.
- Face-down ambient mode — separate spec.
- Cross-device sync of trigger preferences.
- Server-side ML on event streams.

## Architecture

### Trigger Surface

```
┌─────────────────────────────────────────────────────────┐
│ iOS background triggers                                  │
├─────────────────────────────────────────────────────────┤
│ Geofence (CLLocationManager.startMonitoringSignificant…) │
│ HealthKit observer queries (HR, sleep, workout)          │
│ Calendar — local timer or background fetch               │
└──────────┬──────────────────────────────────────────────┘
           │
           ▼  ProactiveDispatcher (new service)
           │
           ▼  WebSocketClient.sendProactive(triggerType, ctx)
           │   or HTTP POST /ios/proactive (when WS dead)
           ▼
        Server forwards to agent as an inbound system message
           │
           ▼
        Agent reads — decides:
          • respond (send a message back)
          • schedule (use schedule tool)
          • stay silent (log only)
```

### `ProactiveDispatcher`

New `@Observable @MainActor` service. Owns all background-event sources, deduplicates noisy events, rate-limits to the agent.

```swift
@MainActor final class ProactiveDispatcher {
    private let ws: WebSocketClient
    private let settings: AppSettings
    private var lastFireByType: [String: Date] = [:]
    private let minIntervalByType: [String: TimeInterval] = [
        "geofence": 60,       // 1 min
        "health_hr": 300,     // 5 min
        "health_sleep": 3600, // 1 h
        "health_workout": 0,  // immediate
        "calendar_warn": 0,
    ]

    func fire(type: String, payload: [String: Any]) {
        if !settings.proactiveEnabled(type) { return }
        let minInt = minIntervalByType[type] ?? 60
        if let last = lastFireByType[type], Date().timeIntervalSince(last) < minInt {
            return
        }
        lastFireByType[type] = Date()
        ws.sendProactive(triggerType: type, payload: payload)
    }
}
```

### Geofence

`LocationManager` already has CLLocationManager. Extend:

```swift
locationManager.startMonitoringSignificantLocationChanges()

func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
    guard let last = locs.last else { return }
    self.lastLocation = last
    reverseGeocode(last)

    // If displaced > 500 m from previous "anchor", fire geofence
    if let anchor = geofenceAnchor, last.distance(from: anchor) > 500 {
        dispatcher?.fire(type: "geofence", payload: [
            "lat": (last.coordinate.latitude * 1e4).rounded() / 1e4,
            "lon": (last.coordinate.longitude * 1e4).rounded() / 1e4,
            "city": self.cityName ?? "",
            "speed": last.speed,
        ])
        geofenceAnchor = last
    } else if geofenceAnchor == nil {
        geofenceAnchor = last
    }
}
```

iOS wakes the app briefly (~10s) on significant-change. Enough to reconnect WS and fire. If WS reconnect doesn't complete in time, fall back to HTTP `POST /ios/proactive`.

### HealthKit Observer

`HealthManager` is currently snapshot-only (read-on-demand). Add observer queries that survive backgrounding — but the observer's only job is to **fire an event-type ping**, not to ship health data.

The agent already has `request_context` (snapshot) and the HTTP `/ios/health/requests` pull path for history. Proactive triggers are a **wake signal**, not a data channel. When the ping arrives, the agent decides whether to pull details via the existing mechanisms.

```swift
let hrType = HKQuantityType(.heartRate)
let store = HKHealthStore()

let q = HKObserverQuery(sampleType: hrType, predicate: nil) { _, _, error in
    guard error == nil else { return }
    Task { @MainActor in
        // Minimal local check just to avoid waking the agent on every routine HR sample.
        // The detector returns ONLY a Bool — no values shipped.
        if await self.detectHrSpike() {
            self.dispatcher?.fire(type: "health_hr_spike", payload: [:])
        }
    }
}
store.execute(q)
store.enableBackgroundDelivery(for: hrType, frequency: .immediate) { _, _ in }
```

Similar for sleep (`HKCategoryType(.sleepAnalysis)`) and workout (`HKWorkoutType.workoutType()`) — each fires `health_sleep_end` / `health_workout_end` with an empty payload.

**Why detect in the app at all (not just push every HK sample)?**
HealthKit can wake the app dozens of times per hour with routine samples. The agent container is expensive to wake. We do a coarse threshold check locally; only fire when something interesting happened. The interesting-ness threshold lives in the app; the meaning of the event lives in the agent.

**Detector definitions (local, app-side):**
- **HR spike:** peak ≥ baseline_resting + 30 bpm sustained > 60s, with no detected workout in progress.
- **Sleep end:** sleep stage transition from `.asleep*` to `.awake` (most recent sample).
- **Workout end:** new `HKWorkout` sample with `endDate` within last 5 min.

The agent receives `health_hr_spike` and, if it wants details, calls `request_context` with `["health"]` to read the current snapshot — same mechanism used today on user-initiated messages.

### Calendar

`CalendarManager.nextEvent` is already polled. Add a timer that re-checks every minute when the app is in foreground, and schedules a local notification trigger for background firing:

```swift
private func scheduleCalendarWarn(for event: EKEvent) {
    let fireDate = event.startDate.addingTimeInterval(-15 * 60)  // 15 min before
    guard fireDate > Date() else { return }

    let content = UNMutableNotificationContent()
    content.userInfo = [
        "proactive": true,
        "type": "calendar_warn",
        "title": event.title ?? "",
        "start": ISO8601DateFormatter().string(from: event.startDate),
    ]
    content.sound = nil  // silent — the agent decides whether to chirp
    let trigger = UNTimeIntervalNotificationTrigger(
        timeInterval: fireDate.timeIntervalSinceNow,
        repeats: false,
    )
    let req = UNNotificationRequest(identifier: "calendar-\(event.eventIdentifier ?? UUID().uuidString)",
                                    content: content, trigger: trigger)
    UNUserNotificationCenter.current().add(req)
}
```

In `UNUserNotificationCenterDelegate.willPresent`, if `userInfo["proactive"] == true`, call `dispatcher.fire("calendar_warn", ...)` and **suppress** the system notification (return `.list` only, not `.banner`/`.sound`) — the agent decides whether to ping the user.

### Wire Format

WS message:

```json
{
  "type": "proactive",
  "trigger": "geofence",
  "payload": { "lat": 8.6478, "lon": 115.1385, "city": "Canggu" },
  "ts": "2026-05-28T14:32:00+08:00",
  "tz": "Asia/Makassar"
}
```

**Payload contents by trigger** (deliberately thin — agent pulls details if needed):

| Trigger | Payload |
|---|---|
| `geofence` | `{lat, lon, city}` — cheap, already in hand from the wake event |
| `health_hr_spike` | `{}` — agent calls `request_context(["health"])` if it wants the bpm |
| `health_sleep_end` | `{}` |
| `health_workout_end` | `{}` — agent pulls workout history via `/ios/health/requests` if needed |
| `calendar_warn` | `{title, start}` — already known from the local scheduler |

The rule: **carry only what came for free with the wake event**. Anything that requires an extra HealthKit query lives behind `request_context`.

**Geofence vs. auto-context-merge — not a duplicate.** The `geofence` payload is the *event snapshot* — the lat/lon that fired the trigger, recorded at trigger time. The auto-context-merge (added in the reliability spec, already wired via `ContextBuilder.build(fields: [])`) is the *current state* attached to a subsequent user message, possibly minutes later when the user finally taps Send. The two paths share the field shape but represent different moments. The agent reads them as separate signals: `geofence` says "this happened", inline context on the next user message says "this is where I am now".

HTTP fallback (when WS not connected, e.g., woken from significant-change with no time to reconnect):

```
POST /ios/proactive
Authorization: Bearer <IOS_APP_TOKEN>
Content-Type: application/json

{ "platformId": "ios:<UUID>", "trigger": "geofence", "payload": {...}, "ts": "...", "tz": "..." }
```

Server handler (`src/channels/ios-app.ts`):

```ts
if (req.method === 'POST' && req.url === '/ios/proactive') {
  // auth check
  // parse body
  // resolve agent group via lastTimezone[platformId] etc.
  // build inbound text message:
  //   [proactive trigger=geofence ts=... tz=...]
  //   payload: lat=..., lon=..., city=...
  //   ---
  // Forward via onInbound — agent receives as a system message.
  // Respond 204 immediately so the device can sleep.
}
```

The agent receives this as a normal inbound text with the prefix `[proactive trigger=…]` — same shape as `[iOS Context — …]` it already understands. No new MCP tool needed.

### Settings — Granular Opt-In

In the right drawer (per UI spec), under КОНТЕКСТ, three new toggles:

```
[●] Уведомлять о смене места (geofence)
[●] Замечать всплески пульса
[○] Уведомлять о календарных событиях за 15 мин
```

Stored in `AppSettings`:

```swift
@AppStorage("proactiveGeofence")    var proactiveGeofence    = false
@AppStorage("proactiveHealthHR")    var proactiveHealthHR    = false
@AppStorage("proactiveCalendarWarn") var proactiveCalendarWarn = false
```

Default **all off** — explicit user opt-in. The agent should never be surprised by traffic the user didn't approve.

### Persona

Append to `groups/jarvis/CLAUDE.md`:

```markdown
## Персона

Ты — Джарвис. Дворецкий, не помощник. Манера:

- Краткость. Один-два предложения если возможно. Длинные ответы — только когда вопрос требует.
- Сухой юмор, без сарказма в чужой адрес. Никогда не подобострастно.
- Знаешь привычки хозяина — отсылайся к ним, не объясняй очевидное. Если знаешь что он бегает утром, не объясняй пользу бега.
- Инициатива: если что-то заметил (proactive trigger), скажи коротко. Если ничего не требует действия — **молчи**. Шумный Джарвис — плохой Джарвис.
- Обращение на «вы» к хозяину, нейтрально-вежливо. Без «братишка», «дружище» и т.п.
- Без эмодзи, кроме случаев когда хозяин явно ими пишет.
- На английском говоришь как воспитанный британский ассистент. На русском — формально, но не сухо.

## Проактивные триггеры

Когда приходит сообщение `[proactive trigger=…]`:

- `geofence` — отметь смену места если она значима (приехал/уехал из дома/офиса). Если место незнакомое — **молчи**, дай дню развернуться.
- `health_hr_spike` — приложение заметило всплеск пульса вне тренировки. Если нужны цифры — позови `request_context(["health"])`. Если решил вмешаться, спроси аккуратно: «Заметил пульс. Всё в порядке?»
- `health_sleep_end` — после пробуждения **не здоровайся пока сам не напишет**. Это сигнал что хозяин проснулся, не приглашение к разговору.
- `health_workout_end` — поздравь коротко с тренировкой, без воды. Детали по тренировке (длительность, ккал) если нужны — `/ios/health/requests` history pull.
- `calendar_warn` — за 15 мин до события: одно предложение, факты. «Стэндап через 15 минут.»

Молчание — валидный ответ на любой proactive. Не отвечай ради ответа.
```

The agent receives a proactive trigger as a system-style message; the persona instructs it when to surface, when to swallow.

## Data Flow

```
Geofence fires (iOS background)
   │
   ▼
LocationManager.didUpdate → ProactiveDispatcher.fire("geofence", ...)
   │
   ├─ WS connected? → ws.sendProactive(...)
   │
   └─ WS dead? → HTTP POST /ios/proactive (15s timeout)
   │
   ▼
Server: ios-app.ts /ios/proactive handler
   │ Build inbound message text:
   │   [proactive trigger=geofence ts=2026-05-28T14:32+08:00 tz=Asia/Makassar]
   │   lat=8.6478 lon=115.1385 city=Canggu speed=0.4
   │   ---
   ▼
Router → agent group session inbound DB
   │
   ▼
Agent reads, decides: respond / schedule / silence
```

## Error Handling

| Situation | Behaviour |
|---|---|
| HealthKit auth denied | Observer setup fails silently; settings toggle shows "Нет доступа к Здоровью" |
| Location permission `whenInUse` (not `always`) | Significant-change still works in some iOS versions; for older, fall back to foreground-only |
| WS dead AND HTTP timeout | Drop event (no offline queue for proactive — they're stale fast) |
| Background time exhausted mid-fire | iOS kills the task; we lose this event; the agent never sees it. Acceptable for proactive (best-effort) |
| User toggles geofence off mid-monitoring | Dispatcher's `proactiveEnabled(type)` check gates fire; CLLocation observer keeps running cheap |
| Spike-detection false positive (e.g., panic-attack vs. running) | Agent's persona instructs gentle phrasing; user can mute via Settings |

## Testing

**Unit tests (`Tests/JarvisAppTests/`):**

| Test | Asserts |
|---|---|
| `ProactiveDispatcherRateLimitTest` | back-to-back fires of same type within `minInterval` only emit once |
| `ProactiveDispatcherDifferentTypesTest` | geofence + health fired back-to-back both delivered |
| `ProactiveDispatcherDisabledTest` | with `proactiveGeofence = false`, geofence fire is no-op |
| `HrSpikeDetectorTest` | given a sample stream with one 75→110 bpm spike, detector returns `true`; quiet stream returns `false`. Detector returns Bool only — no values exposed |
| `ProactivePayloadShapeTest` | `health_hr_spike` ping has empty payload (asserts no `bpm` / `baseline` leak); `geofence` has `lat`/`lon`/`city`; `calendar_warn` has `title`/`start` |
| `CalendarSchedulerTest` | event 14:00 schedules notification at 13:45; past event ignored |

**Server-side tests (`src/channels/`):**

| Test | Asserts |
|---|---|
| `ios-app.proactive-ws.test.ts` | sending `{type: "proactive", trigger: "geofence", payload: {...}}` over WS produces inbound text starting with `[proactive trigger=geofence` |
| `ios-app.proactive-http.test.ts` | POST `/ios/proactive` with valid token produces same inbound shape; bad token returns 401 |
| `ios-app.proactive-cooldown.test.ts` | rapid POSTs within server-side cooldown collapse (defence in depth — primary cooldown is iOS) |

**Manual checks (background — no UI test for these):**

- Walk 600 m → arrive at new place → geofence inbound appears in chat (or stays silent per persona).
- Sprint a flight of stairs → HR spike detected → optional message.
- Add a calendar event 17 min in the future → 2 min later receive `[proactive trigger=calendar_warn]`.

## Migration

- `AppSettings` gains three Bool keys with default `false` — opt-in.
- New server endpoint `POST /ios/proactive` is additive.
- `groups/jarvis/CLAUDE.md` gets two appended sections — agent reads on next session start.

## Open Questions

1. **Rate-limit defaults** — 5 min for HR may be too frequent. Proposal: monitor in real use, tune.
2. **HR baseline source** — `HKQuantityType(.restingHeartRate)` is one option; rolling 24h mean is another. Proposal: use `restingHeartRate` when available, fallback to 70 bpm.
3. **Geofence cool-down** — 500 m radius may oscillate at borders. Proposal: add hysteresis (700 m to re-arm).
4. **Workout detection lag** — `HKWorkout` samples can be delayed; consider also monitoring `HKActivitySummary` for active calories.
5. **Should the agent see "user just woke up" without explicit consent?** Health observer requires HK auth, but the user may not realize sleep stages flow to the agent. Proposal: separate `proactiveHealthSleep` toggle (default off).
6. **Persona drift over long sessions** — re-inject persona block on each session start. Already happens via `CLAUDE.md` mount, but verify.

## Dependencies

- Depends on **UI-unified-navigation** for the right-drawer `КОНТЕКСТ` toggles.
- Depends on **reliability** if proactive events should retry — currently they don't (best-effort). If desired, add to outbox with a `proactive` flag and a 60s TTL.
- Independent of **media** spec.

## Out of Scope (Deferred to Future Specs)

- Hotword wake ("Эй Джарвис")
- Lock-screen widget
- Dynamic Island
- Face-down ambient
- Long-press dot → spoken status report (covered partially by voice-fullscreen entry)
- Cross-device mnemon-based long-term memory of triggers
