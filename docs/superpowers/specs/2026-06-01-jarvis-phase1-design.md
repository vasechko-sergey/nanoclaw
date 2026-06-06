# Jarvis Phase 1 — Gmail + Calendar + Morning Brief + iOS Morning Health Push

Date: 2026-06-01
Status: Design approved, ready for implementation

## Goal

Bring Jarvis closer to the cinematic original by giving him calendar + email awareness, a daily proactive brief, and ensuring his health context is fresh when the operator opens the iOS app in the morning.

## Scope

Four discrete additions to the existing `jarvis` agent group plus one iOS-app change:

1. Gmail MCP server (via OneCLI OAuth)
2. Google Calendar MCP server (via OneCLI OAuth)
3. Daily 09:00 local "morning brief" `schedule_task` in Jarvis's session
4. Move Greg (health-analyzer) from 09:00 UTC to 08:00 local
5. iOS app: on `scenePhase == .active`, if last health upload was not today, kick `HealthSync.pushRecent` and record the upload date

## Non-goals

- Web search MCP, Google Maps MCP, Home Assistant — Phase 2/3
- New subagents (news/finance/travel) — Phase 3
- Voice/video modalities — Phase 4
- Work Gmail write/send — accepted limitation if Workspace blocks external OAuth (operator vetoed mail-forwarding workaround)
- Dashboard UI — not in this phase

## Architecture / changes

### 1. Gmail MCP (`/add-gmail-tool`)

Runs the existing skill. End state:
- `groups/jarvis/container.json` gains `mcpServers["gmail"]` entry per the skill template
- `container/Dockerfile` gains pinned `@gongrzhe/server-gmail-autoauth-mcp` install
- `~/.gmail-mcp/{gcp-oauth.keys.json,credentials.json}` written with `onecli-managed` stubs
- OneCLI vault has a Gmail OAuth refresh-token entry tied to `vasechkoss@gmail.com`
- Jarvis agent's secret mode is `all` (or selective with Gmail secret assigned) so the gateway injects the real token on outbound `gmail.googleapis.com` calls

Agent gets tools: `mcp__gmail__search`, `mcp__gmail__send`, `mcp__gmail__list_labels`, `mcp__gmail__draft`, etc.

### 2. Google Calendar MCP (`/add-gcal-tool`)

Same pattern. Same OAuth account (one consent dialog if Calendar scope is bundled with Gmail at connect time; otherwise two separate connects). Agent gets `mcp__gcal__list_events`, `mcp__gcal__create_event`, `mcp__gcal__freebusy`, etc.

### 3. Morning brief (09:00 local)

Single recurring `schedule_task` from inside Jarvis's session:

```
schedule_task({
  prompt: "Собери утренний бриф для Сергея. Источники:
    - Календарь на сегодня (gcal list_events from now to 23:59 local)
    - Непрочитанные важные письма (gmail search, label:unread + starred OR from known VIPs)
    - Последняя строка memories/self/health.md (недельный тренд)
    - Свежий health-finding от Greg если есть в a2a inbox
    - Погода если есть тула (Phase 2)
  Выдай одним <message> Сергею. Важное сверху. Тихие часы §2 уважать
  (если 09:00 попадает в тихое окно по операторской TZ — пропусти).",
  processAfter: "2026-06-02T09:00:00",
  recurrence: "0 9 * * *"
})
```

Cron evaluated in operator's local TZ (from iOS context). Tasks persist across container restarts — the agent-runner reads them on poll.

### 4. Greg → 08:00 local

Currently scheduled daily 09:00 UTC. Two-step rebuild via Greg's own MCP:
1. `list_tasks` → identify the daily-analysis task id
2. `cancel_task <id>`
3. `schedule_task` with `recurrence: "0 8 * * *"` and a fresh `processAfter` at next 08:00 local

08:00 → 09:00 ordering means Greg writes a fresh finding before Jarvis's brief reads the a2a inbox.

### 5. iOS morning health auto-push

**Problem:** HealthKit observers only fire on new samples. If the operator opens the app at 09:00 with no new health samples since yesterday, Greg + Jarvis see stale data.

**Solution:** Add `HealthSync.kickIfStale()`:

```swift
// In Services/HealthSync.swift
static func kickIfStale() {
    let defaults = UserDefaults.standard
    let cal = Calendar.current
    let last = defaults.object(forKey: "lastHealthUploadAt") as? Date
    let today = cal.startOfDay(for: Date())
    if let last, cal.startOfDay(for: last) >= today { return }
    pushRecent {
        UserDefaults.standard.set(Date(), forKey: "lastHealthUploadAt")
    }
}
```

Also update existing `pushRecent` callers (observer path) to write `lastHealthUploadAt` after `HealthUpload.upload` completes — keeps the gate consistent regardless of trigger.

Call site in `JarvisApp.swift:79`:

```swift
.onChange(of: scenePhase) { _, new in
    if new == .active {
        Theme.refreshScale()
        Theme.refreshDrawerWidth()
        HealthSync.kickIfStale()       // NEW
    }
    Task { @MainActor in
        coordinator.ws.handleScenePhase(new)
    }
}
```

Rule chosen by operator: **always if not uploaded today** (no morning-only time window). Opens app at 15:00, last push was yesterday → still kicks. Opens at 09:00, already pushed at 02:00 today → no-op.

**Tests:** `HealthSyncTests.swift` — table-driven with stub `UserDefaults`:
- nil `lastHealthUploadAt` → calls `pushRecent`
- yesterday → calls `pushRecent`
- today (any hour) → no-op
- Future date (clock skew) → no-op

## OneCLI OAuth on VDS

NanoClaw and OneCLI run on the VDS (`148.253.211.164`). OneCLI web UI binds to `127.0.0.1:10254` of the VDS only — no public exposure. Operator's laptop reaches the VDS over Tailscale.

**Why a tunnel is still needed even with Tailscale:** OneCLI's internal Google OAuth client registers `redirect_uri = http://127.0.0.1:10254/...callback` with Google. The browser must hit a URL whose host matches that registration. Browsing the VDS by Tailscale DNS name → Google redirects to the DNS name → Google rejects (whitelist miss). So we need a **local port-forward** that makes the URL `127.0.0.1:10254` on the laptop actually reach OneCLI on the VDS.

**Tunnel via Tailscale SSH:**
```bash
tailscale ssh -L 10254:127.0.0.1:10254 nanoclaw@<vds-tailscale-name> -N
# laptop browser → http://127.0.0.1:10254
# Apps → Gmail → Connect → Google consent → redirect to 127.0.0.1:10254/...
# tunnel forwards the callback to VDS OneCLI, which stores the token in the VDS vault
```

**Verification (task #9):** before running `/add-gmail-tool`, open the tunnel and confirm `http://127.0.0.1:10254` loads on laptop, Apps tab renders. If yes → run skill, do the connect step over the tunnel. If no → debug network/firewall, do not attempt OAuth blindly.

## Two Google accounts (personal + work)

Two accounts in play:

- **Personal — `vasechkoss@gmail.com`** — full read/write via OneCLI built-in OAuth. No special handling.
- **Work — Google Workspace, operator is NOT admin.** Workspace policies may block external OAuth apps from accessing user data. Try the normal path first; have a fallback ready.

### Plan A (try first) — direct OAuth via OneCLI for both accounts

`gcal` MCP supports multi-account natively (per `add-gcal-tool` skill). In OneCLI web UI, do the Connect flow twice — once for personal, once for work. Each connect creates a separate vault secret. `gmail` MCP is single-account in its default form; for work-mail-read we'd need a second MCP instance pointed at a different OAuth secret + different mount path (defer until known to work).

**Indicators Plan A failed:** during work-account consent, Google shows "access blocked: this app is blocked", "your administrator has restricted access", `access_denied + policy_disabled`, or a Workspace-controlled consent screen with the Connect button disabled. Token never lands in the vault.

### Plan B (fallback if Plan A blocked on work) — read-only via iCal URL

If Workspace blocks the OAuth for work, **work calendar** drops to read-only via Google Calendar's per-user secret iCal URL. No admin involvement, no OAuth:

- Settings (in work calendar) → Integrate calendar → Secret address in iCal format → copy URL
- Store in OneCLI as generic secret: `onecli secrets create --name work-cal-ical --type generic --value '<url>' --host-pattern 'calendar.google.com/calendar/ical/*'`
- Add a small script `/workspace/agent/scripts/work-calendar.js` (Bun) that fetches and parses ics, exposes a JSON view. Jarvis calls it when work-calendar context is requested (morning brief, "what do I have at work today").
- ics parsing: pin a maintained pure-JS library (`ical.js` or `node-ical`); cache the fetched ics in `/workspace/agent/.cache/work-cal.ics` with 5min TTL.

**Work email** under Plan B: **not in scope.** Operator vetoed mail-forwarding to personal. If a write-side workaround is ever needed, the invite-flow (create event on personal calendar, invite work address) is documented in §10 of `groups/jarvis/CLAUDE.md`.

### Decision point

Verify Plan A for the work account within task #2 or #3 (whichever does the work-account connect first). If consent fails → execute Plan B as a follow-up task within this phase. Do not stall the personal-account flow on work-account issues.

## Files touched

| File | Change |
|---|---|
| `groups/jarvis/container.json` | `mcpServers.gmail`, `mcpServers.gcal`, `additionalMounts.{.gmail-mcp, .gcal-mcp}` |
| `container/Dockerfile` | pinned `pnpm install -g` for gmail+gcal MCP servers + version ARGs |
| `groups/jarvis/CLAUDE.md` | new §10 "Внешние данные" — правила gmail/gcal usage, утренний бриф |
| `ios/JarvisApp/Sources/JarvisApp/Services/HealthSync.swift` | `kickIfStale()` + write `lastHealthUploadAt` in upload callbacks |
| `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift` | call `HealthSync.kickIfStale()` on `scenePhase == .active` |
| `ios/JarvisApp/Sources/JarvisAppTests/HealthSyncTests.swift` | new test file |

No host code changes (no `src/` edits). All work is config + container image + iOS + scheduling.

## CLAUDE.md additions (Jarvis §10)

```
## 10. Внешние данные (gmail, gcal)

- gmail и gcal — твои руки в почте и календаре. Используешь молча, без объявлений.
- Не цитируй raw содержимое писем и событий — пересказывай суть. Цитата только если Сергей просит дословно или конкретный фрагмент важен.
- Деструктив (отправить письмо, удалить событие, ответить за Сергея) — §6 правило: один confirm. Чтение — без подтверждения.
- Утренний бриф 09:00 local собирает gcal + gmail unread important + последний health. Это твой проактивный канал — не дублируй вручную если бриф уже был сегодня.
- Поиск писем — сначала фильтры (label:unread, from:, subject:, before:/after:), потом контент. Не вытягивай весь inbox.
- Создание событий — заполняй обязательные поля. Если Сергей дал относительное время («завтра в 3») — резолви в ISO с операторской TZ из iOS-контекста.
- **Два календаря** (personal + work). Если запрос неоднозначен («что у меня завтра?») — показывай оба, отметив источник. Если явно «по работе» / «личное» — фильтруй.
- **Если work-календарь read-only через iCal** (Plan B): создавать события на нём нельзя. На запрос «поставь встречу на work» — создай событие на personal calendar и пригласи work-email; объясни одной фразой.
- **Work email** — если OAuth не сработал, ты не имеешь к нему доступа. На запрос «прочти рабочее письмо» — констатируй ограничение, не выдумывай.
```

## Order of execution

1. Task #9 — verify Tailscale SSH tunnel + OneCLI web UI access (blocker check)
2. Task #1 — write this spec ✓
3. Task #2 — `/add-gmail-tool`, connect **personal** account
4. Task #3 — `/add-gcal-tool`, connect **personal** account (multi-account-ready)
5. Task #3b (new) — try Plan A connect for **work** account (gcal first, gmail if applicable). If blocked → Plan B (work iCal URL + fetch script).
6. Task #7 — CLAUDE.md §10 (covers both accounts + Plan B notes)
7. Restart Jarvis container (skills usually do this; verify)
8. Task #4 — reschedule Greg to 08:00
9. Task #5 — Jarvis schedules morning brief 09:00 (brief reads both calendars)
10. Task #6 — iOS HealthSync.kickIfStale + tests, push
11. Task #8 — smoke-test all criteria including work-calendar visibility

## Risks

- **OAuth redirect URI mismatch on tunnel.** If Google rejects `127.0.0.1:10254` because OneCLI registered a different one — fall back to B/C.
- **OneCLI secret mode `selective` by default for new agents** (per CLAUDE.md note). After install: `onecli agents set-secret-mode --id <jarvis> --mode all` or assign secrets explicitly. Without this, Gmail/Gcal calls 401.
- **MCP server version drift.** Skills pin versions; do not bump without re-reading the `zod-to-json-schema` note in the gmail skill.
- **Cron TZ mismatch.** `schedule_task` evaluates cron in operator's `TIMEZONE` env. Verify the container's `TIMEZONE` matches iOS-context TZ before scheduling brief and Greg.
- **Greg rescheduling needs Greg's CLI access.** If Greg has `cli_scope: disabled`, manual SQL or CLI invocation on host is needed to cancel old task. Check before attempting.
- **iOS test infra for HealthSync.** Existing tests may already stub HKHealthStore. If not, write a minimal protocol-shim to inject a fake store for `kickIfStale` only — keep scope tight.

## Acceptance criteria

1. `ask Jarvis "прочти последнее письмо"` → real subject + summary
2. `ask Jarvis "что у меня завтра?"` → real gcal events
3. Greg's `list_tasks` shows the daily task at `0 8 * * *`, old one cancelled
4. Jarvis's `list_tasks` shows the morning brief at `0 9 * * *`
5. Next morning: brief arrives 09:00 ± 1min, in operator local TZ
6. Open iOS app today (last upload yesterday) → new entry in NanoClaw inbound DB on the health channel within ~2s of `.active`
7. Re-open iOS app the same day → no extra upload

## Out of scope follow-ups

- Phase 2: web search MCP, maps MCP
- Phase 3: home assistant, news/finance subagents
- Long-term: video understanding tool, music/media control, dashboard
