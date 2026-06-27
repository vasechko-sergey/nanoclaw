# Agent Dashboard Redesign — Design Spec

**Date:** 2026-06-27
**Status:** Approved for planning
**Scope:** iOS app + host `/ios/state` endpoint + agent publish skills

## Goal

Replace the health-rings-only home glance with a real **agent dashboard**: every agent
shows its own quick-read metrics plus one concrete **action to do today**. Health stops
being the only visually-rich card and stops dominating the home screen.

This is a full concept rework of the in-app "state board". The Jarvis morning brief
(a 09:00 chat message) is out of scope and unchanged.

## Current state (what exists today)

**Morning publish (~08:45 WITA).** Each of 5 agents writes `public.md`. The host
(`src/public-profiles.ts`) projects each to `data/user-memory/<person>/global/profiles/<agent>.md`.
Frontmatter contract: `updated:`, `summary:`, plus agent-specific fields. Greg additionally
publishes `levels: {energy, stress, recovery, readiness}` and `recovery7d: [..7..]`.

**What's visible in the app.** `GET /ios/state` (`src/channels/ios-app/v2/http-handler.ts:256`)
parses the projected profiles (`profiles.ts:parseProfile`) and returns:

```
{ levels: {energy, stress, recovery, readiness, recovery7d, updated},   // Greg only
  agents: [{key, title, icon, summary, detail, updated}, ...] }
```

- Home (`OrbHomeView.swift:114`): a `HealthStripView` of 4 rings (Greg's `levels`) sits below
  the orb cluster. Tap → `StateBoardView` sheet.
- `StateBoardView`: the 4 rings again + 5 agent rows (accordion: summary + expandable detail;
  Greg also gets a `recovery7d` sparkline on expand).
- Agent order is hardcoded server-side: `['greg','gordon','payne','scrooge','jarvis']`.

**The gap.** Only Greg's data becomes visual (rings). The other 4 agents are a one-line
`summary` + a wall of expandable text. Their numbers (kcal, training-day, runway) are buried
in prose. Home shows nothing but health.

## Decisions (locked)

1. **Visual direction: "строки + чипы" (variant A).** Dense list of cards; per card: header
   (icon + name + freshness) → row of number chips → one action line → tap-to-expand detail text.
   Closest to the existing board, lowest style risk, matches "краткие числа сверху, текст внизу".
2. **Dashboard lives on its own screen** (redesigned `StateBoardView`). The orb home is the
   app's identity (chat entry) and is **not** restructured.
3. **Home loses the rings strip.** In its place: a slim entry row "Сводка · N дел" that opens
   the dashboard. N = number of agents with a non-empty action today.
4. **Order = picker order** (`AgentIdentity.allCases`): **Jarvis → Payne → Greg → Scrooge → Gordon.**
   The server's greg-first order is dropped.
5. **Greg's 4 rings die.** Readiness becomes a single chip; energy/stress move into Greg's
   expand-detail; the `recovery7d` sparkline moves into Greg's expand-detail.
6. **New contract fields:** every agent publishes `metrics` (≤3 chips) and `action` (one line).
7. **The "hide health from main screen" toggle is dropped (YAGNI).** With rings gone from home
   and the dashboard on its own screen, health is no longer on the main screen — nothing to hide.
8. **Card role label = profession** (per the persona), built client-side, not "domain":
   Jarvis · дворецкий · Maj Payne · тренер · Dr House · врач-диагност · Scrooge · казначей · Ramzi · повар.

## The new publish contract

Two new frontmatter fields, added to every agent's `public.md`:

```yaml
---
updated: 2026-06-27
summary: сон 7.1ч, ХРВ ↓, восстановление просело        # unchanged — feeds expand detail
action: Лёгкий день — нагрузку не грузи                  # NEW: one line, or "—"
metrics: [{"v":"68","l":"готовность","t":"warn"},{"v":"↓","l":"восст.","t":"warn"},{"v":"7.1ч","l":"сон"}]   # NEW
levels: {energy: 60, stress: 40, recovery: 62, readiness: 68}   # Greg only, kept
recovery7d: [74,77,72,80,79,85,81]                              # Greg only, kept (→ sparkline)
---
# body → expand detail (unchanged)
```

- **`metrics`** — JSON array, **max 3** objects. `v` = value (short string: number, `↑/↓`, band).
  `l` = label (short). `t` = optional tone ∈ `ok | warn | bad` → sage / gold / tomato. No `t` =
  neutral. Parsed like the existing `recovery7d` JSON.
- **`action`** — single line, the one thing worth doing today, or `"—"` when nothing.
- Both fields are **optional**. A profile without them still renders (card shows name +
  summary/detail, no chips, no action line) — backward compatible during rollout.

### Per-agent metrics + action

| Agent | Profession | Chips (≤3) | Action source |
|-------|-----------|------------|---------------|
| Jarvis | дворецкий | события `N` · почта `N` · *(погода° — optional, see open Q)* | next event ("10:00 встреча — выйти в 9:40") or "—" |
| Payne | тренер | неделя `N/M` · сегодня `<день\|отдых>` · интенс. `↑` | "Тренировка ног · 52 мин" / "Отдых, растяжка" |
| Greg | врач-диагност | готовность `N` · восст. `↑/↓` · сон `Xч` | derived from readiness/recovery ("Лёгкий день" / "Можно грузить") |
| Scrooge | казначей | запас `<полоса>` · траты `±%` · доход `✓/✗` | "Проверь подписки" when spend up, else "—" |
| Gordon | повар | ккал `%` · белок `±г` · дефицит `N` | "Добери 30 г белка к ужину" / "—" |

Tone examples: Greg readiness < 70 → `warn`, < 50 → `bad`; Scrooge траты `+8%` → `bad`,
доход ✓ → `ok`. Exact thresholds are owned by each publish skill.

## Component changes

### Host

1. **`src/channels/ios-app/v2/profiles.ts`** — `parseProfile` extracts `action` (string line) and
   `metrics` (JSON array, defensive parse like `recovery7d`; bad JSON → omitted, not a crash).
2. **`src/channels/ios-app/v2/http-handler.ts`** —
   - Add `metrics` and `action` to each agent row in the `/ios/state` response.
   - Change `AGENT_ORDER` to `['jarvis','payne','greg','scrooge','gordon']`.
   - `levels` top-level block stays in the response (Greg's `recovery7d` is read from it for the
     sparkline); the client no longer renders it as rings.

### iOS

3. **`Models/StateModel.swift`** — add to `AgentRow`:
   ```swift
   struct Metric: Codable, Identifiable {
     var v: String; var l: String; var t: String?
     var id: String { l + v }
   }
   var metrics: [Metric]?
   var action: String?
   ```
4. **`Models/AgentIdentity.swift`** — add two computed properties (static per-agent, like
   `accentColor`/`displayName`):
   - `var profession: String` → дворецкий / тренер / врач-диагност / казначей / повар.
   - `var dashIcon: String` → SF Symbol name (e.g. stethoscope / dumbbell.fill / fork.knife /
     banknote.fill / bell.fill — verify iOS 16 availability at impl).
5. **`Views/StateBoardView.swift`** — redesign:
   - **Remove** the top 4-ring `HStack` (lines ~28–36).
   - Card header: `dashIcon` + "`displayName` · `profession`" tinted with `AgentIdentity.accentColor`
     (replace the local `accent(key)` switch, whose colors are wrong vs the real per-agent accents).
   - Chips row: `ForEach(metrics)` → chip (value bold + label small; `t` → tone color).
   - Action row: arrow + `action`, shown only when `action != nil && action != "—"`, tinted accent.
   - Tap → expand existing `detail` text. Greg: `recovery7d` sparkline + energy/stress in expand.
   - Keep the stale-dim behavior (`freshness` → opacity 0.55 + gray dot + "вчера"/date).
6. **`Views/OrbHomeView.swift`** — replace the `HealthStripView` at line 114 with a slim
   `SummaryEntryView`: "Сводка · N дел" (N = `agents.filter { $0.action != nil && $0.action != "—" }.count`),
   `.onTapGesture { showStateBoard = true }` (the `showStateBoard` state already exists). When state
   isn't loaded yet, show "Сводка" with no count. Orb cluster untouched.
7. **Removals** — `Components/HealthStripView.swift` and `Components/RingView.swift` are used only by
   the home strip and the old board; delete both once confirmed unreferenced (grep at impl). `Sparkline`
   stays (Greg detail). `AppSettings.swift` gets **no** new toggle.

### Agent publish skills (groups/, gitignored — deployed by scp)

8. **`groups/{jarvis,greg,gordon,payne,scrooge}/skills/publish/SKILL.md`** — each emits `metrics`
   (≤3) + `action` in frontmatter, computed from the same scripts they already run
   (`analyze.js`, `targets.js`, `daily-rollup.js`, calendar, etc.).
9. **`groups/INSTRUCTIONS.md`** — document the two new contract fields in the shared publish section.

## Data flow (unchanged shape, two new fields)

```
agent publish (08:45) → public.md {…, metrics, action}
  → host projectAllPublicProfiles → profiles/<agent>.md
  → GET /ios/state parseProfile → {agents:[{…, metrics, action}], levels}
  → iOS StateService → StateBoardView cards (chips + action) + home "Сводка · N" entry
```

## Backward compatibility / rollout

`metrics` and `action` are optional end-to-end. Order of deploy doesn't matter:
- Ship host + iOS first → dashboard renders, cards show summary/detail only, entry count = 0,
  until agents start publishing the new fields.
- Ship agent skills → on next 08:45 publish (or a manual publish), chips + actions appear.

No migration, no breaking change to existing profiles.

## Deploy mechanics

- **Host (`src/`):** `pnpm run build` + push → on VDS `git pull && pnpm run build && systemctl --user restart nanoclaw`.
- **iOS:** Сергей builds in Xcode. Bump `CURRENT_PROJECT_VERSION` (+ MARKETING for the feature),
  `xcodegen generate`, commit the pbxproj.
- **Agent skills (`groups/`):** gitignored → `scp` to VDS + rebirth (kill containers + DELETE the
  `continuation` rows) so live agents reload the publish skill. A one-off publish task can refresh
  the profiles immediately instead of waiting for 08:45.

## Testing

- **Host (vitest):** `parseProfile` with `metrics`+`action` present, absent, and malformed JSON
  (malformed → field omitted, no throw). `/ios/state` agent order = jarvis,payne,greg,scrooge,gordon.
- **iOS:** `StateModel` decodes `AgentRow` with/without `metrics`/`action`. Dashboard card renders
  chips + action and hides the action line on `"—"`/nil. `SummaryEntryView` count logic. Clean build.
- **Graceful degradation:** a profile with only `summary` still renders a valid card.

## Non-goals

- Jarvis morning brief (chat) — untouched.
- Server still computes/returns `levels` (used for Greg's sparkline data); only the ring UI is gone.
- No privacy/hide toggle. No per-user reordering. No new fetch/caching changes to `StateService`.

## Open questions (resolve in planning, low-risk defaults noted)

1. **Jarvis chips depth.** "почта N" and "погода°" aren't in Jarvis's current publish (only
   location/focus/events). Default: Jarvis chips = `события N` + `локация` (no extra scripts);
   add mail/weather chips later only if cheap. Decide whether to pull `mail-search.js`/`weather.js`
   into Jarvis publish now or defer.
2. **SF Symbol names** for `dashIcon` — verify exact names exist on iOS 16 (`dumbbell.fill`,
   `stethoscope`, etc.); pick fallbacks if not.
3. **Card accent surface** — left-border accent (current) vs icon-only accent. Default: keep the
   thin left-border accent, tint icon + name with the agent accent.
