# Jarvis Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Jarvis closer to the cinematic JARVIS by giving him calendar + email awareness for personal and work Google accounts, a daily 09:00 morning brief, an earlier Greg schedule (08:00), and a fresh iOS health snapshot on each morning app-open.

**Architecture:** Two MCP servers (`@gongrzhe/server-gmail-autoauth-mcp`, `@cocal/google-calendar-mcp`) bolted into the `jarvis` agent group via existing skills `/add-gmail-tool` and `/add-gcal-tool`. OneCLI mediates OAuth and per-request token injection — no raw credentials in the container. Two recurring `schedule_task` cron entries are created from inside the running containers (Greg and Jarvis). The iOS app gains a single `HealthSync.kickIfStale()` call on `scenePhase == .active` to guarantee a fresh upload before the brief lands.

**Tech Stack:** NanoClaw v2 on VDS (Node host + Bun agent-runner), OneCLI 1.1.0 gateway, MCP via stdio, Swift/SwiftUI iOS app, HealthKit, UserDefaults, XCTest, `tailscale ssh` for OAuth port-forwarding.

**Spec:** [`docs/superpowers/specs/2026-06-01-jarvis-phase1-design.md`](../specs/2026-06-01-jarvis-phase1-design.md)

---

## File Inventory

**Modified (via skills, no manual diff):**
- `groups/jarvis/container.json` — adds `mcpServers.gmail`, `mcpServers.gcal`, `additionalMounts` entries
- `container/Dockerfile` — pinned `pnpm install -g @gongrzhe/server-gmail-autoauth-mcp@<v>` + `@cocal/google-calendar-mcp@<v>` + ARGs
- `~/.gmail-mcp/{gcp-oauth.keys.json, credentials.json}` on VDS — onecli-managed stubs
- `~/.config/google-calendar-mcp/...` (or skill-equivalent path) on VDS — onecli-managed stubs

**Modified (manual edit):**
- `groups/jarvis/CLAUDE.md` — appends §10 «Внешние данные»

**Modified (Swift):**
- `ios/JarvisApp/Sources/JarvisApp/Services/HealthSync.swift` — adds `kickIfStale()`; pipes `lastHealthUploadAt` writes through every upload path

- `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift` — calls `HealthSync.kickIfStale()` in scenePhase handler

**Created (Swift tests):**
- `ios/JarvisApp/Sources/JarvisAppTests/HealthSyncTests.swift` — gating logic for `kickIfStale()`

**Created on VDS (only if Plan B triggers for work calendar):**
- `groups/jarvis/scripts/work-calendar.js` — Bun script: fetch iCal URL, parse, emit JSON window query
- OneCLI secret `work-cal-ical` (type generic) holding the iCal URL

**Scheduling (no file change, runtime state in session DBs):**
- One cron task in Greg's session: `0 8 * * *`
- One cron task in Jarvis's session: `0 9 * * *`

---

## Task 1: Verify Tailscale tunnel + OneCLI web UI

**Goal:** Confirm operator can reach OneCLI web UI via `http://127.0.0.1:10254` on laptop, with the request actually hitting OneCLI on the VDS. This is a blocker check for every OAuth-dependent task below.

**Files:** none modified

- [ ] **Step 1:** From the laptop, open a port-forward tunnel.

Run:
```bash
tailscale ssh -L 10254:127.0.0.1:10254 nanoclaw@<vds-tailscale-name> -N
```

Replace `<vds-tailscale-name>` with the actual Tailscale machine name. The `-N` makes ssh open the tunnel without an interactive shell. Leave this terminal open during OAuth.

- [ ] **Step 2:** In a separate terminal on the laptop, sanity-check the tunnel.

Run:
```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:10254/
```

Expected: `200` (or `30x` redirect to a login/dashboard page). Anything else (`connection refused`, `502`) → tunnel is wrong, abort and fix before continuing.

- [ ] **Step 3:** Open `http://127.0.0.1:10254` in the laptop browser. Confirm the OneCLI dashboard loads, the Apps section is present, and Gmail + Google Calendar tiles are visible (even if not connected).

Expected: dashboard renders, no TLS errors (it's plain HTTP over the tunnel), Apps tab clickable.

- [ ] **Step 4:** Leave the tunnel up. Proceed to Task 2.

---

## Task 2: Install Gmail MCP into Jarvis (personal account)

**Goal:** Wire `@gongrzhe/server-gmail-autoauth-mcp` into the `jarvis` agent group, finish OneCLI OAuth for `vasechkoss@gmail.com`, confirm `mcp__gmail__*` tools are usable.

**Files:**
- Modify: `groups/jarvis/container.json` (via skill)
- Modify: `container/Dockerfile` (via skill)
- Create (on VDS): `~/.gmail-mcp/gcp-oauth.keys.json`, `~/.gmail-mcp/credentials.json`

- [ ] **Step 1:** From the working tree at `/Users/serg/git/nanoclaw`, invoke the install skill.

In Claude Code, type: `/add-gmail-tool`

Follow the skill prompts: select agent group `jarvis`. The skill will edit `container.json`, Dockerfile, and ask you to do the OneCLI Connect step.

- [ ] **Step 2:** During the Connect step, use the laptop browser (tunnel from Task 1 still open). Apps → Gmail → Connect → sign in as **`vasechkoss@gmail.com`** → grant the scopes the skill requests.

Expected: OneCLI shows Gmail as Connected; a new secret with name matching `gmail` and account `vasechkoss@gmail.com` is in the vault.

- [ ] **Step 3:** From the host, verify the secret landed in the VDS OneCLI vault.

Run (on VDS):
```bash
onecli secrets list | jq '.data[] | select(.name|test("(?i)gmail"))'
```

Expected: one entry with the personal-account email visible (or referenced via metadata). If empty → OAuth didn't reach OneCLI on the VDS. Check tunnel and retry.

- [ ] **Step 4:** Flip the Jarvis agent's secret mode if it's still `selective`.

Run (on VDS):
```bash
JARVIS_AGENT_ID=$(onecli agents list | jq -r '.data[] | select(.identifier=="ba3aa121-a9b2-40b4-b208-7d81c61c739b") | .id')
onecli agents set-secret-mode --id "$JARVIS_AGENT_ID" --mode all
onecli agents secrets --id "$JARVIS_AGENT_ID"
```

Expected: secrets list shows the Gmail secret assigned to the Jarvis agent.

- [ ] **Step 5:** Rebuild the agent container so the Dockerfile changes apply.

Run (on VDS):
```bash
./container/build.sh
```

Expected: build succeeds, mention of `@gongrzhe/server-gmail-autoauth-mcp@<pinned-version>` in the pnpm install log.

- [ ] **Step 6:** Restart the Jarvis agent group.

Run (on VDS):
```bash
ncl groups restart --id ba3aa121-a9b2-40b4-b208-7d81c61c739b
```

Expected: ncl confirms restart; next user message will spawn a fresh container.

- [ ] **Step 7:** Smoke-test Gmail from Jarvis.

Send Jarvis a message: `прочти заголовки последних трёх писем`. Wait for a `<message>` response.

Expected: real subjects from `vasechkoss@gmail.com` inbox, in Jarvis's voice. If 401 → secret mode (Step 4) or the wrong account connected.

- [ ] **Step 8:** Commit the host-side config changes generated by the skill.

Run:
```bash
git status
git add groups/jarvis/container.json container/Dockerfile
git commit -m "feat(jarvis): wire gmail MCP via OneCLI OAuth"
git push origin main
```

---

## Task 3: Install Google Calendar MCP into Jarvis (personal account)

**Goal:** Wire `@cocal/google-calendar-mcp` into the same agent group, OAuth the personal account.

**Files:**
- Modify: `groups/jarvis/container.json` (via skill)
- Modify: `container/Dockerfile` (via skill)
- Create (on VDS): credential stub files per the gcal skill

- [ ] **Step 1:** Tunnel from Task 1 should still be open. If not, re-open it.

- [ ] **Step 2:** In Claude Code: `/add-gcal-tool`. Pick `jarvis` group. Follow prompts.

- [ ] **Step 3:** OneCLI Connect via tunneled web UI → Apps → Google Calendar → Connect as `vasechkoss@gmail.com` → grant `calendar.readonly` + `calendar.events`.

Expected: gcal shows Connected.

- [ ] **Step 4:** Verify secret on VDS.

Run (on VDS):
```bash
onecli secrets list | jq '.data[] | select(.name|test("(?i)calendar|gcal"))'
```

Expected: one or more entries. (Multi-account-ready MCP may store account-scoped entries.)

- [ ] **Step 5:** Rebuild + restart.

Run (on VDS):
```bash
./container/build.sh
ncl groups restart --id ba3aa121-a9b2-40b4-b208-7d81c61c739b
```

- [ ] **Step 6:** Smoke-test calendar from Jarvis.

Send: `что у меня завтра в календаре?`

Expected: real events from personal calendar (or empty-day acknowledgement).

- [ ] **Step 7:** Commit.

Run:
```bash
git add groups/jarvis/container.json container/Dockerfile
git commit -m "feat(jarvis): wire gcal MCP via OneCLI OAuth"
git push origin main
```

---

## Task 4: Connect work Google account (Plan A → fallback Plan B)

**Goal:** Add work-account access. Try direct OAuth via OneCLI first; if Workspace policy blocks it, drop to iCal-URL read-only for the calendar.

**Files (Plan B path only):**
- Create: `groups/jarvis/scripts/work-calendar.js`
- Create: OneCLI secret `work-cal-ical`

- [ ] **Step 1 (Plan A try):** Tunnel open. In OneCLI web UI → Apps → Google Calendar → click Connect a second time → sign in with **work Google account** → grant `calendar.readonly`.

Possible outcomes:
- **Success:** OneCLI now shows two connected calendar accounts. Proceed to Step 2.
- **Blocked:** Google shows "access blocked", "your administrator has restricted access", or `access_denied` with `policy_disabled`. Skip to Step 4 (Plan B).

- [ ] **Step 2 (Plan A success):** Verify both secrets present.

Run (on VDS):
```bash
onecli secrets list | jq '.data[] | select(.name|test("(?i)calendar|gcal")) | {id, name}'
```

Expected: two entries.

- [ ] **Step 3 (Plan A success):** Optionally repeat for Gmail (work). If the same blocking dialog appears, accept that work-mail is out of scope for this phase and proceed to Step 7.

If Gmail work succeeds, the agent will see both accounts via the same MCP server (note: `@gongrzhe/server-gmail-autoauth-mcp` typically operates against one account per server instance — verify in the agent that `mcp__gmail__search` returns work-mailbox results; if not, defer multi-mailbox support to a follow-up phase).

- [ ] **Step 4 (Plan B fallback for calendar):** On the laptop, open work Google Calendar in the browser → Settings → select the work calendar → scroll to "Integrate calendar" → copy "Secret address in iCal format".

- [ ] **Step 5 (Plan B):** Store the URL as an OneCLI secret on the VDS.

Run (on VDS, replacing `<URL>` with the copied address):
```bash
onecli secrets create \
  --name work-cal-ical \
  --type generic \
  --value '<URL>' \
  --host-pattern 'calendar.google.com/calendar/ical/*'
```

If Jarvis is in `secret-mode=all`, the new secret is auto-injected — no further step. If it's `selective`, run:
```bash
NEW_ID=$(onecli secrets list | jq -r '.data[] | select(.name=="work-cal-ical") | .id')
EXISTING=$(onecli agents secrets --id "$JARVIS_AGENT_ID" | jq -r '[.data[].id] | join(",")')
onecli agents set-secrets --id "$JARVIS_AGENT_ID" --secret-ids "${EXISTING},${NEW_ID}"
```

Expected: secret created, assigned to Jarvis agent.

- [ ] **Step 6 (Plan B):** Create the fetch script.

Create `groups/jarvis/scripts/work-calendar.js`:

```javascript
#!/usr/bin/env bun
// Read-only work calendar via Google's per-user iCal URL.
// Usage:  bun run scripts/work-calendar.js <from-iso> <to-iso>
//         (omit args → next 24h)
// Output: JSON array of {summary, start, end, location, description}

import { statSync } from "node:fs";

const ICAL_URL = process.env.WORK_CAL_ICAL_URL;
if (!ICAL_URL) {
  console.error("WORK_CAL_ICAL_URL not set (OneCLI injects this)");
  process.exit(1);
}

const now = new Date();
const from = process.argv[2] ? new Date(process.argv[2]) : now;
const to = process.argv[3] ? new Date(process.argv[3]) : new Date(now.getTime() + 24 * 3600_000);

const cacheFile = `${process.env.HOME}/.cache/work-cal.ics`;
const cacheTtlMs = 5 * 60_000;

async function loadIcs() {
  try {
    const ageMs = Date.now() - statSync(cacheFile).mtimeMs;
    if (ageMs < cacheTtlMs) return await Bun.file(cacheFile).text();
  } catch {
    // cache miss
  }
  const res = await fetch(ICAL_URL);
  if (!res.ok) throw new Error(`fetch failed: ${res.status}`);
  const text = await res.text();
  await Bun.write(cacheFile, text);
  return text;
}

function parseIcs(text) {
  const events = [];
  let cur = null;
  for (const line of text.split(/\r?\n/)) {
    if (line === "BEGIN:VEVENT") cur = {};
    else if (line === "END:VEVENT") { if (cur) events.push(cur); cur = null; }
    else if (cur) {
      const m = line.match(/^([A-Z]+)(?:;[^:]*)?:(.*)$/);
      if (!m) continue;
      const [_, k, v] = m;
      if (k === "SUMMARY") cur.summary = v;
      else if (k === "DTSTART") cur.start = parseIcsDate(v);
      else if (k === "DTEND") cur.end = parseIcsDate(v);
      else if (k === "LOCATION") cur.location = v;
      else if (k === "DESCRIPTION") cur.description = v;
    }
  }
  return events;
}

function parseIcsDate(s) {
  // 20260602T090000Z  → 2026-06-02T09:00:00Z
  const m = s.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z?$/);
  if (!m) return s;
  return `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}Z`;
}

const ics = await loadIcs();
const all = parseIcs(ics);
const filtered = all.filter(e => {
  const s = new Date(e.start);
  return s >= from && s < to;
});
console.log(JSON.stringify(filtered, null, 2));
```

- [ ] **Step 7:** Commit (whichever path was taken).

Run:
```bash
git status
# If Plan B:
git add groups/jarvis/scripts/work-calendar.js
git commit -m "feat(jarvis): work calendar via iCal URL fallback"
git push origin main
# If Plan A only: nothing to commit (OneCLI vault is not in git)
```

---

## Task 5: Append §10 to Jarvis CLAUDE.md

**Goal:** Document the new tools, two-account behavior, and Plan-B caveats so Jarvis uses them correctly without operator hand-holding.

**Files:**
- Modify: `groups/jarvis/CLAUDE.md` (append §10 before the `@./.claude-fragments/...` includes)

- [ ] **Step 1:** Open `groups/jarvis/CLAUDE.md` and locate the line `@./.claude-fragments/module-core.md`. Insert the §10 block **above** that include line (i.e. after §9 «Health-аналитик (Грег)»).

Block to insert:

```markdown
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

- [ ] **Step 2:** Sanity-check the file.

Run:
```bash
grep -n "^## " groups/jarvis/CLAUDE.md
```

Expected: sections 1 through 10 listed in order, §10 is "Внешние данные (gmail, gcal)".

- [ ] **Step 3:** Commit.

Run:
```bash
git add groups/jarvis/CLAUDE.md
git commit -m "docs(jarvis): add §10 — внешние данные (gmail, gcal)"
git push origin main
```

- [ ] **Step 4:** Pull on VDS and restart Jarvis so the new CLAUDE.md is picked up.

Run (on VDS):
```bash
cd ~/nanoclaw && git pull && pnpm run build
ncl groups restart --id ba3aa121-a9b2-40b4-b208-7d81c61c739b
```

Expected: build succeeds, restart confirmed.

---

## Task 6: Reschedule Greg to 08:00 local

**Goal:** Move Greg's daily analysis from 09:00 UTC to 08:00 in the operator's local TZ.

**Files:** none (runtime state in Greg's session DB)

- [ ] **Step 1:** Identify Greg's agent group id.

Run (on VDS):
```bash
ncl groups list | grep -i 'greg\|health'
```

Note the id (call it `$GREG_ID`).

- [ ] **Step 2:** Open a chat with Greg (or send a system message via the host) telling him to reschedule:

> Перенеси daily-analysis расписание на 08:00 локального времени. Список своих задач: `list_tasks`. Найди текущий daily, отмени через `cancel_task`, создай новый через `schedule_task` с `recurrence: "0 8 * * *"` и `processAfter` = ближайшие 08:00 local в ISO. Подтверди новой строкой из `list_tasks`.

Expected: Greg returns updated `list_tasks` output showing one daily task at `0 8 * * *`, old task gone.

- [ ] **Step 3:** Verify next-fire time.

Ask Greg: `следующий запуск?` — should give an ISO timestamp matching 08:00 local tomorrow (or today if before 08:00).

- [ ] **Step 4:** Update the project memory note about Greg's schedule.

Run:
```bash
grep -l "09:00 UTC" /Users/serg/.claude/projects/-Users-serg-git-nanoclaw/memory/*.md
```

If matches found, edit them so the schedule reflects `08:00 local`.

---

## Task 7: Schedule Jarvis morning brief at 09:00 local

**Goal:** Create a recurring `schedule_task` in Jarvis's session that fires at 09:00 every day, generating the morning brief.

**Files:** none (runtime state in Jarvis's session DB)

- [ ] **Step 1:** Send Jarvis the following message verbatim:

> Запланируй ежедневный утренний бриф. Используй `schedule_task` с:
> - `prompt`: «Собери утренний бриф для Сергея. Источники: события из обоих gcal-аккаунтов на сегодня (до 23:59 local); непрочитанные важные письма из gmail (label:unread + starred OR from VIPs); последняя строка `memories/self/health.md`; свежий health-finding от Greg если есть в a2a inbox. Выдай одним `<message>`. Важное сверху. Тихие часы §2 уважать.»
> - `processAfter`: ближайшие 09:00 local в ISO
> - `recurrence`: `0 9 * * *`
>
> После создания вызови `list_tasks` и пришли строку про новый бриф.

Expected: Jarvis confirms, lists the new task with cron `0 9 * * *`.

- [ ] **Step 2:** Confirm TZ alignment. Ask Jarvis:

> Какая таймзона у твоего scheduler? Покажи `processAfter` нового брифа.

Expected: TZ matches operator's iOS-context TZ. If mismatch, the cron will fire at the wrong wall-clock time — fix via `update_task` or environment.

---

## Task 8: iOS HealthSync.kickIfStale — write the test first

**Goal:** TDD `HealthSync.kickIfStale()`. The test asserts that, given various `lastHealthUploadAt` values, the helper either invokes `pushRecent` or no-ops.

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisAppTests/HealthSyncTests.swift`
- Modify (next task): `ios/JarvisApp/Sources/JarvisApp/Services/HealthSync.swift`

The existing `HealthSync` exposes `pushRecent(_ done:)` as a static func that ultimately calls `HealthHistory.fetch` + `HealthUpload.upload`. To make `kickIfStale` testable without touching HealthKit, the test will assert behavior through a seam: an injectable `pushRecent` closure plus an injectable `now` provider and `UserDefaults` instance.

- [ ] **Step 1:** Create the test file.

Create `ios/JarvisApp/Sources/JarvisAppTests/HealthSyncTests.swift`:

```swift
import XCTest
@testable import JarvisApp

final class HealthSyncTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "HealthSyncTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        defaults = nil
        super.tearDown()
    }

    func test_kickIfStale_noPriorUpload_callsPushRecent() {
        var pushed = false
        let calls = HealthSync.kickIfStaleForTesting(
            now: Date(timeIntervalSince1970: 1_800_000_000),
            calendar: Calendar(identifier: .gregorian),
            defaults: defaults,
            push: { done in pushed = true; done() }
        )
        XCTAssertTrue(pushed)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(defaults.object(forKey: "lastHealthUploadAt"))
    }

    func test_kickIfStale_uploadedYesterday_callsPushRecent() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        defaults.set(yesterday, forKey: "lastHealthUploadAt")

        var pushed = false
        let calls = HealthSync.kickIfStaleForTesting(
            now: now,
            calendar: cal,
            defaults: defaults,
            push: { done in pushed = true; done() }
        )
        XCTAssertTrue(pushed)
        XCTAssertEqual(calls, 1)
    }

    func test_kickIfStale_uploadedToday_noOps() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let earlierToday = cal.date(byAdding: .hour, value: -3, to: now)!
        defaults.set(earlierToday, forKey: "lastHealthUploadAt")

        var pushed = false
        let calls = HealthSync.kickIfStaleForTesting(
            now: now,
            calendar: cal,
            defaults: defaults,
            push: { done in pushed = true; done() }
        )
        XCTAssertFalse(pushed)
        XCTAssertEqual(calls, 0)
    }

    func test_kickIfStale_futureDate_noOps() {
        // Clock skew safety: a future lastUpload should be treated as "uploaded today".
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        defaults.set(tomorrow, forKey: "lastHealthUploadAt")

        var pushed = false
        _ = HealthSync.kickIfStaleForTesting(
            now: now,
            calendar: cal,
            defaults: defaults,
            push: { done in pushed = true; done() }
        )
        XCTAssertFalse(pushed)
    }
}
```

- [ ] **Step 2:** Run the test, verify it fails with "no such symbol kickIfStaleForTesting".

Run:
```bash
cd ios/JarvisApp && swift test --filter HealthSyncTests
```

Expected: build error referencing `HealthSync.kickIfStaleForTesting`.

---

## Task 9: iOS HealthSync.kickIfStale — implement

**Goal:** Make the tests pass with a minimal `kickIfStale()` plus a testable shim.

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthSync.swift`

- [ ] **Step 1:** Add the two methods to `HealthSync` (keep the existing `start()` and `pushRecent(_:)` as-is).

Edit `ios/JarvisApp/Sources/JarvisApp/Services/HealthSync.swift` and append before the closing `}` of the `HealthSync` enum:

```swift
    /// Public production entrypoint. Called from scenePhase == .active.
    /// If `lastHealthUploadAt` is missing or not in today's calendar day,
    /// kicks `pushRecent` and stamps the date afterward. Otherwise no-op.
    static func kickIfStale() {
        _ = kickIfStaleForTesting(
            now: Date(),
            calendar: Calendar.current,
            defaults: UserDefaults.standard,
            push: { done in pushRecent(done) }
        )
    }

    /// Pure decision + side-effect seam for tests. Returns the number of times
    /// `push` was invoked (0 or 1).
    @discardableResult
    static func kickIfStaleForTesting(
        now: Date,
        calendar: Calendar,
        defaults: UserDefaults,
        push: (@escaping () -> Void) -> Void
    ) -> Int {
        let last = defaults.object(forKey: "lastHealthUploadAt") as? Date
        let today = calendar.startOfDay(for: now)
        if let last, calendar.startOfDay(for: last) >= today {
            return 0
        }
        push {
            defaults.set(Date(), forKey: "lastHealthUploadAt")
        }
        return 1
    }
```

- [ ] **Step 2:** Run the tests.

Run:
```bash
cd ios/JarvisApp && swift test --filter HealthSyncTests
```

Expected: all four tests pass.

- [ ] **Step 3:** Commit.

Run:
```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/HealthSync.swift \
        ios/JarvisApp/Sources/JarvisAppTests/HealthSyncTests.swift
git commit -m "feat(ios): HealthSync.kickIfStale guards once-per-day upload"
```

---

## Task 10: Wire HealthSync.kickIfStale into scenePhase handler

**Goal:** Call `HealthSync.kickIfStale()` when the app becomes active.

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift:79-87`

- [ ] **Step 1:** Edit `JarvisApp.swift`. Inside `.onChange(of: scenePhase)`, in the `if new == .active { ... }` block, add the call.

Replace:
```swift
                .onChange(of: scenePhase) { _, new in
                    if new == .active {
                        Theme.refreshScale()
                        Theme.refreshDrawerWidth()
                    }
                    Task { @MainActor in
                        coordinator.ws.handleScenePhase(new)
                    }
                }
```

with:
```swift
                .onChange(of: scenePhase) { _, new in
                    if new == .active {
                        Theme.refreshScale()
                        Theme.refreshDrawerWidth()
                        HealthSync.kickIfStale()
                    }
                    Task { @MainActor in
                        coordinator.ws.handleScenePhase(new)
                    }
                }
```

- [ ] **Step 2:** Build the iOS target.

Run:
```bash
cd ios/JarvisApp && swift build
```

Expected: build succeeds. (`swift test` was run in Task 9 and still passes.)

- [ ] **Step 3:** Commit.

Run:
```bash
git add ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift
git commit -m "feat(ios): kick stale health upload on scenePhase==.active"
git push origin main
```

---

## Task 11: iOS device smoke test

**Goal:** Confirm `kickIfStale` actually triggers an upload when the app reopens with stale state.

**Files:** none modified

- [ ] **Step 1:** Build and install the app on the test device (Xcode + your usual deploy flow). Open the app once with a known fresh upload state (look for the upload log in NanoClaw inbound DB for today's date).

- [ ] **Step 2:** Force the gate stale. On the device, fully quit the app, then in another way (or by waiting until tomorrow) ensure `lastHealthUploadAt` is from yesterday — easiest: open the app today, then come back tomorrow morning.

Alternatively, for same-day verification: temporarily wipe the key via a debug command or reinstall the app (which clears UserDefaults).

- [ ] **Step 3:** Open the app. Within ~2 seconds, check that an upload landed.

Run (on VDS):
```bash
pnpm exec tsx scripts/q.ts data/v2-sessions/<jarvis-agent>/<session>/inbound.db \
  "SELECT id, type, substr(content,1,80), seq FROM messages_in ORDER BY seq DESC LIMIT 5"
```

Expected: a recent `health_update` (or whatever the channel labels it) with today's timestamp.

- [ ] **Step 4:** Re-open the app within the same day. Confirm **no** new upload (the gate held).

Run the same query; the count should not increase.

---

## Task 12: End-to-end acceptance

**Goal:** Walk through all spec acceptance criteria and confirm.

**Files:** none modified

- [ ] **Step 1:** Gmail check. Send Jarvis: `прочти заголовок последнего письма`. Expected: real subject.

- [ ] **Step 2:** Gcal personal check. Send Jarvis: `что у меня в личном календаре завтра?`. Expected: real events or "ничего".

- [ ] **Step 3:** Gcal work check (whichever path).
  - Plan A: `что у меня в рабочем календаре завтра?` → real events.
  - Plan B: same prompt → Jarvis runs `bun run scripts/work-calendar.js` and returns parsed events.

- [ ] **Step 4:** Greg schedule check. Ask Greg: `list_tasks`. Expected: daily task at `0 8 * * *`, no old `09:00 UTC` task.

- [ ] **Step 5:** Jarvis brief schedule check. Ask Jarvis: `list_tasks`. Expected: daily morning brief at `0 9 * * *`.

- [ ] **Step 6:** Wait for next 09:00 local. Confirm a brief arrives unprompted, mentions calendar + email + health context.

- [ ] **Step 7:** iOS once-per-day check from Task 11 — record pass/fail.

- [ ] **Step 8:** Final commit if any cleanup remains; otherwise note completion in memory.

Run:
```bash
git status
```

If clean, update memory:

Edit `/Users/serg/.claude/projects/-Users-serg-git-nanoclaw/memory/MEMORY.md` to add (after the Greg line):

```
- [Jarvis Phase 1](project_jarvis_phase1.md) — gmail+gcal MCP, утренний бриф 09:00, Greg 08:00, iOS morning health auto-push. Completed 2026-06-XX.
```

Create `/Users/serg/.claude/projects/-Users-serg-git-nanoclaw/memory/project_jarvis_phase1.md` with a short summary.

---

## Risks recap (per spec, copy here for execution-time visibility)

- **OAuth redirect URI mismatch on tunnel** → re-check that `127.0.0.1:10254` is the registered URI; OneCLI logs should help.
- **`selective` secret mode by default** → Task 2 Step 4 covers it; if Tasks 3 or 4 add new secrets, re-run `set-secret-mode --mode all` or assign explicitly.
- **MCP server version drift** → use the exact pins from the skills; don't bump blindly.
- **Cron TZ mismatch** → Task 7 Step 2 verifies; if wrong, fix container `TIMEZONE` env via `ncl groups config update`.
- **Greg `cli_scope`** → must be `group` or `global` for Task 6 to work from inside his container; check with `ncl groups get --id $GREG_ID`.
- **iOS HealthKit auth** → `kickIfStale` calls `pushRecent`, which depends on `HealthManager` having been granted permission; on first install this can fail silently until user grants.
- **Work account OAuth blocked** → Plan B kicks in cleanly; document the limitation to operator.
