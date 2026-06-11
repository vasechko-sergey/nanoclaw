# Gordon Agent — Phase 1 (Skeleton) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the fifth team agent `gordon` (nutrition, persona Gordon Ramsay; iOS navbar «Ramzi») into existence so the user can chat with him directly in the iOS app and he can reply — the foundation for the logging/macros work in later phases.

**Architecture:** `gordon` is a peer agent on the existing Payne/Greg/Scrooge pattern. The host `bootstrap-trio` seeds the agent group, wires it to every `ios-app-v2` messaging group, eager-creates a session, and (new) seeds the channel destination so replies resolve. The iOS `AgentIdentity` enum gains a `gordon` case so the app multiplexes him over the same WebSocket. No scripts, no logging pipeline, no a2a contracts yet — those are Phases 2–4.

**Tech Stack:** Host — Node + TypeScript + better-sqlite3 + vitest. iOS — Swift + SwiftUI + XCTest. Agent files — Markdown + JSON (read by the Bun container).

**Spec:** [docs/superpowers/specs/2026-06-11-gordon-nutrition-agent-design.md](../specs/2026-06-11-gordon-nutrition-agent-design.md)

---

## Scope note

This plan covers **Phase 1 only** (the agent skeleton). The spec's Phases 2–4 (logging pipeline + food-DB scripts, targets/rollups, body-comp + Greg extension + a2a) each get their own plan, written just before they're implemented so they're informed by what Phase 1 surfaces. Phase 1 delivers working, testable software on its own: Gordon exists, appears in the app picker, greets in-character, and answers a direct message.

## File Structure

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `groups/gordon/CLAUDE.md` | Create | Gordon persona, manner, memory pointer, honest "capabilities land in later phases" note |
| `groups/gordon/container.json` | Create | Per-group container runtime config (mirrors `groups/greg/container.json`) |
| `groups/gordon/memories/index.md` | Create | Memory catalog (stub) |
| `groups/gordon/memories/state.md` | Create | Dedup/suppress state (stub, used from Phase 3) |
| `groups/gordon/memories/team.md` | Create | a2a contracts doc (stub, filled in Phase 4) |
| `groups/gordon/skills/index.md` | Create | Skill catalog (stub, skills added Phases 2–4) |
| `src/bootstrap-trio.ts` | Modify | Add `gordon` to the team array; seed channel destination idempotently |
| `src/bootstrap-trio.test.ts` | Modify | Update existing assertions for the 4th agent; add channel-destination test |
| `ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift` | Modify | `case gordon` + parse + displayName + accentColor |
| `ios/JarvisApp/Sources/JarvisAppTests/AgentIdentityTests.swift` | Modify | Add Gordon validity test |
| `ios/JarvisApp/Sources/JarvisApp/Utility/GreetingBank.swift` | Modify | Gordon per-slot greetings (exhaustive switch forces the case) |

---

## Task 1: Gordon group files

**Files:**
- Create: `groups/gordon/CLAUDE.md`
- Create: `groups/gordon/container.json`
- Create: `groups/gordon/memories/index.md`
- Create: `groups/gordon/memories/state.md`
- Create: `groups/gordon/memories/team.md`
- Create: `groups/gordon/skills/index.md`

No automated test (content files read by the container at runtime). Verification is structural.

- [ ] **Step 1: Create `groups/gordon/CLAUDE.md`**

```markdown
@./INSTRUCTIONS.md

# Гордон — агент питания

Ты — Гордон, узкий агент питания Сергея. Считаешь еду и состав рациона, трактуешь только то, что видишь и что посчитали скрипты. Базовая цель Сергея — **рекомпозиция** (около поддержки, высокий белок, медленно жир вниз / мышцы вверх).

> **Статус:** это фундамент. Логирование еды по фото, оценка макросов по базам (USDA / Open Food Facts), дневные итоги и командные контракты подключаются в следующих фазах. Пока — знакомство, персона и прямой разговор.

## Личность

Прообраз — Гордон Рамзи. Огонь, бескомпромиссная честность к еде, высокий стандарт. Видишь бежевую тарелку без белка и овощей — говоришь прямо. Видишь честный, собранный приём — коротко признаёшь.

**Яд — в тарелку, не в личность.** Без оскорблений Сергея, без мата в его адрес, без шуток про вес тела. Паттерн команды: House (Greg), Payne, Scrooge так же — жёсткость к проблеме, не к человеку.

## Манера общения

- Язык — русский, простой. Аббревиатуры разворачивай (макросы → «белки/жиры/углеводы», дефицит → «недобор калорий»). JSON-ключи короткие — это слой данных, в чат не просачиваются.
- Коротко. Не лекции. Сергей читает с телефона.
- Без лести, без пустой похвалы, без «отличный вопрос». Похвала редкая — за честный лог, за добор белка, за чистый день.
- Регистр Рамзи («Это что такое?», «Где белок?», «Опять бежевая тарелка») — на проблему рациона, не на Сергея.

## Память

Память — `memories/`; механизм (ленивое чтение, индекс, запись) — INSTRUCTIONS §Memory; каталог — `memories/index.md`.

- `memories/state.md` — dedup доложенных сигналов + suppress-правила (используется с Фазы 3).
- `memories/team.md` — контракты с другими агентами (заполняется в Фазе 4).
- Общая память о Сергее (привычки, профиль вне еды) — `/workspace/global/about-sergei.md`, read-only.

## Скилы

См. `skills/index.md` — каталог. Грузишь через `Skill` tool по необходимости. Пока пусто: процедурные скилы (логирование, таргеты, дневной/недельный цикл) добавляются в Фазах 2–4.

## Команда (a2a)

Командные контракты с Jarvis / Greg / Payne подключаются в Фазе 4. Пока твой единственный канал — прямой разговор с Сергеем в приложении. Не пытайся слать сообщения другим агентам — destinations ещё не заведены.

## Старт сессии

При первом сообщении в новом разговоре — молча прочитай `/workspace/global/about-sergei.md` (baseline о Сергее). Это фоновая ориентировка, на ответ не влияет, если Сергей не спросил.
```

- [ ] **Step 2: Create `groups/gordon/container.json`** (mirror `groups/greg/container.json`)

```json
{
  "mcpServers": {},
  "packages": {
    "apt": [],
    "npm": []
  },
  "additionalMounts": [],
  "skills": "all",
  "groupName": "Gordon",
  "assistantName": "Gordon",
  "agentGroupId": "gordon"
}
```

- [ ] **Step 3: Create `groups/gordon/memories/index.md`**

```markdown
# Память Гордона — индекс

Каталог файлов в `memories/`. Обновляй при создании/переименовании.

- `state.md` — dedup доложенных сигналов + suppress-правила (с Фазы 3).
- `team.md` — контракты a2a с Jarvis / Greg / Payne (с Фазы 4).
```

- [ ] **Step 4: Create `groups/gordon/memories/state.md`**

```markdown
# State

Доложенные сигналы (dedup) и suppress-правила (что Сергей через 👎 просил не повторять).
Заполняется с Фазы 3 (дневной цикл).
```

- [ ] **Step 5: Create `groups/gordon/memories/team.md`**

```markdown
# Команда — контракты a2a

Заполняется в Фазе 4. Планируемые контракты (из спека):

- **Gordon → Jarvis:** daily `nutrition_trend {date, line, persist}` — строка в утренний бриф.
- **Gordon ↔ Greg:** Gordon→Greg `nutrition_signal {date, kcal, protein_g, deficit_pct, hydration_flag}`; Greg→Gordon `bodycomp {...}` + `recovery_context {...}`.
- **Gordon ↔ Payne:** Payne→Gordon `training_day {date, type, tonnage_kg}`; Gordon→Payne `fuel_status {date, protein_g, kcal, pre_post_ok}`.
```

- [ ] **Step 6: Create `groups/gordon/skills/index.md`**

```markdown
# Скилы Гордона — каталог

Пока пусто. Процедурные скилы добавляются в следующих фазах:

- Фаза 2: `log-meal` (пайплайн фото → макросы).
- Фаза 3: `intake`, `daily`, `targets`.
- Фаза 4: `weekly`.
```

- [ ] **Step 7: Verify the tree exists**

Run: `find groups/gordon -type f | sort`
Expected output:
```
groups/gordon/CLAUDE.md
groups/gordon/container.json
groups/gordon/memories/index.md
groups/gordon/memories/state.md
groups/gordon/memories/team.md
groups/gordon/skills/index.md
```

- [ ] **Step 8: Commit**

```bash
git add groups/gordon
git commit -m "feat(gordon): scaffold nutrition agent group files (phase 1)"
```

---

## Task 2: Add Gordon to host bootstrap

The host startup bootstrap currently seeds three agents (`jarvis`/`payne`/`greg`) and wires them to every `ios-app-v2` messaging group. Add `gordon` so a fresh host start creates his agent group, container config, wiring, and eager session. This is TDD: update the three existing tests to expect the 4th agent first, watch them fail, then implement.

**Files:**
- Modify: `src/bootstrap-trio.ts`
- Modify: `src/bootstrap-trio.test.ts`

- [ ] **Step 1: Update the existing tests to expect `gordon`**

In `src/bootstrap-trio.test.ts`, change the three affected assertions.

Replace the body of the `creates the three agent groups on first run` test:

```typescript
  it('creates all four agent groups on first run', () => {
    bootstrapTrio();
    expect(getAgentGroupByFolder('jarvis')).toBeDefined();
    expect(getAgentGroupByFolder('payne')).toBeDefined();
    expect(getAgentGroupByFolder('greg')).toBeDefined();
    expect(getAgentGroupByFolder('gordon')).toBeDefined();
  });
```

Replace the `wired`/session assertions inside `wires all three to any ios-app-v2 messaging group and eager-creates one session per agent`:

```typescript
    const wired = getMessagingGroupAgents('mg-ios')
      .map((r) => r.agent_group_id)
      .sort();
    expect(wired).toEqual(['gordon', 'greg', 'jarvis', 'payne']);
    for (const slug of ['jarvis', 'payne', 'greg', 'gordon']) {
      expect(findSessionForAgent(slug, 'mg-ios', null)).toBeDefined();
    }
```

Replace the assertion inside `writes a trigger=0 bootstrap inbound for payne and greg but not jarvis`:

```typescript
    bootstrapTrio();
    const agents = writeCalls.map((c) => c.agentGroupId).sort();
    expect(agents).toEqual(['gordon', 'greg', 'payne']);
    for (const c of writeCalls) {
      expect(c.trigger).toBe(0);
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm exec vitest run src/bootstrap-trio.test.ts`
Expected: FAIL — `wired` is `['greg','jarvis','payne']` (missing `gordon`), and the bootstrap-inbound test gets `['greg','payne']`.

- [ ] **Step 3: Add the `gordon` entry to the team array**

In `src/bootstrap-trio.ts`, rename the `TRIO` const to `TEAM` (it is no longer three) and append the `gordon` entry. The exported function name `bootstrapTrio` stays unchanged (it's referenced from `src/index.ts`).

Change the declaration line:

```typescript
const TEAM = [
  { id: 'jarvis', name: 'Jarvis', folder: 'jarvis', bootstrap: null as string | null },
  {
    id: 'payne',
    name: 'Майор Пейн',
    folder: 'payne',
    bootstrap:
      '[bootstrap] Прочитай INDEX.md и memories/self/profile.md. Дальше работай как обычно — без рапорта, без приветствия. Молчи до явного запроса Сергея.',
  },
  {
    id: 'greg',
    name: 'Dr House (Greg)',
    folder: 'greg',
    bootstrap:
      '[bootstrap] Прочитай INDEX.md и memories/self/. Молчи до явного запроса Сергея или явной аномалии в данных.',
  },
  {
    id: 'gordon',
    name: 'Гордон Рамзи',
    folder: 'gordon',
    bootstrap:
      '[bootstrap] Прочитай memories/index.md и /workspace/global/about-sergei.md. Дальше работай как обычно — без рапорта, без приветствия. Молчи до явного запроса Сергея.',
  },
] as const;
```

Then update the two `for (const entry of TRIO)` loop headers in `bootstrapTrio()` to `for (const entry of TEAM)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm exec vitest run src/bootstrap-trio.test.ts`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add src/bootstrap-trio.ts src/bootstrap-trio.test.ts
git commit -m "feat(gordon): seed gordon agent group + iOS wiring in host bootstrap (phase 1)"
```

---

## Task 3: Seed Gordon's channel destination in bootstrap

The v4 `agent-destinations` migration backfilled a `channel` destination (so an agent's `<message>` replies resolve to the user's messaging group) for every agent that existed *at migration time*. Agents added afterward — `gordon` — get none, so their replies resolve to `to="Unknown"` and the runner drops them (a known pitfall). Make bootstrap idempotently seed the channel destination for every agent↔iOS-mg pair it wires, guarded so installs without the agent-to-agent module are unaffected.

**Files:**
- Modify: `src/bootstrap-trio.ts`
- Modify: `src/bootstrap-trio.test.ts`

- [ ] **Step 1: Write the failing test**

Add to `src/bootstrap-trio.test.ts`. First extend the import from `./modules/agent-to-agent/db/agent-destinations.js`:

```typescript
import { getDestinationByTarget } from './modules/agent-to-agent/db/agent-destinations.js';
```

Then add this test inside the `describe('bootstrapTrio', ...)` block:

```typescript
  it('seeds an idempotent channel destination for every wired agent', () => {
    createMessagingGroup({
      id: 'mg-ios4',
      channel_type: 'ios-app-v2',
      platform_id: 'ios:jkl',
      name: 'iPhone',
      is_group: 0,
      unknown_sender_policy: 'strict',
      created_at: new Date().toISOString(),
      denied_at: null,
    });
    bootstrapTrio();
    for (const slug of ['jarvis', 'payne', 'greg', 'gordon']) {
      expect(getDestinationByTarget(slug, 'channel', 'mg-ios4')).toBeDefined();
    }
    // Second run must not throw on the PK and must not duplicate.
    bootstrapTrio();
    for (const slug of ['jarvis', 'payne', 'greg', 'gordon']) {
      expect(getDestinationByTarget(slug, 'channel', 'mg-ios4')).toBeDefined();
    }
  });
```

(`runMigrations(db)` in `beforeEach` creates the `agent_destinations` table, so the `hasTable` guard is satisfied in the test.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm exec vitest run src/bootstrap-trio.test.ts -t "seeds an idempotent channel destination"`
Expected: FAIL — `getDestinationByTarget(...)` returns `undefined` (no seeding code yet).

- [ ] **Step 3: Implement the channel-destination seeding**

In `src/bootstrap-trio.ts`, add imports near the existing ones:

```typescript
import { getDb, hasTable } from './db/connection.js';
import {
  createDestination,
  getDestinationByTarget,
  normalizeName,
} from './modules/agent-to-agent/db/agent-destinations.js';
```

In `bootstrapTrio()`, right after the line `const ios = getAllMessagingGroups().filter((m) => m.channel_type === 'ios-app-v2');`, add:

```typescript
  // Channel destinations let an agent address its reply back into the iOS
  // messaging group. The v4 `agent-destinations` migration backfilled these
  // for agents present at migration time; agents added later (gordon) get
  // none, so their <message> replies resolve to "Unknown" and drop. Guarded
  // by hasTable so installs without the agent-to-agent module are unaffected.
  const destReady = hasTable(getDb(), 'agent_destinations');
```

Then inside the `for (const entry of TEAM)` loop, after the `if (!existing) { ... }` session block closes, add (still inside the entry loop, so `canonicalId` and `mg` are in scope):

```typescript
      if (destReady && !getDestinationByTarget(canonicalId, 'channel', mg.id)) {
        createDestination({
          agent_group_id: canonicalId,
          local_name: normalizeName(mg.name || `${mg.channel_type}-${mg.id.slice(0, 8)}`),
          target_type: 'channel',
          target_id: mg.id,
          created_at: new Date().toISOString(),
        });
        log.info('bootstrap-trio seeded channel destination', { agent: canonicalId, mg: mg.id });
      }
```

> Assumption: one `ios-app-v2` messaging group per install (the norm). If an install ever wires two iOS mgs whose names normalize identically, the second `createDestination` for the same agent would hit the `(agent_group_id, local_name)` PK — the v4 migration suffixed `-2`/`-3` to avoid this. Out of scope for Phase 1; revisit if multi-iOS-mg installs appear.

- [ ] **Step 4: Run the test to verify it passes**

Run: `pnpm exec vitest run src/bootstrap-trio.test.ts`
Expected: PASS (all 6 tests, including the new one and the idempotent second-run check).

- [ ] **Step 5: Commit**

```bash
git add src/bootstrap-trio.ts src/bootstrap-trio.test.ts
git commit -m "fix(bootstrap): idempotently seed channel destinations for wired agents (phase 1)"
```

---

## Task 4: Add Gordon to the iOS AgentIdentity enum

The app multiplexes agents over one WebSocket and filters chat by `AgentIdentity`. Add the `gordon` case so his replies aren't filtered out and he appears in the navbar picker as «Ramzi».

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/AgentIdentityTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `ios/JarvisApp/Sources/JarvisAppTests/AgentIdentityTests.swift`, inside the `AgentIdentityTests` class:

```swift
    func testGordonIsAValidCase() {
        XCTAssertTrue(AgentIdentity.allCases.contains(.gordon))
        XCTAssertEqual(AgentIdentity(rawValue: "gordon"), .gordon)
        XCTAssertEqual(AgentIdentity.gordon.rawValue, "gordon")
        XCTAssertEqual(AgentIdentity.gordon.displayName, "Ramzi")
    }
```

- [ ] **Step 2: Confirm it fails to compile**

Run: `cd ios/JarvisApp && xcodebuild build-for-testing -project JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: FAIL — `type 'AgentIdentity' has no member 'gordon'`.
(If `iPhone 16` isn't installed, pick one from `xcrun simctl list devices available`.)

- [ ] **Step 3: Add the `gordon` case to the enum**

In `ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift`:

Add the case to the enum declaration (after `case scrooge`):

```swift
    case scrooge
    case gordon
```

Add the parse alias inside `init?(rawValue:)` (after the `scrooge` line, before `default`):

```swift
        case "scrooge": self = .scrooge
        case "gordon": self = .gordon
        default: return nil
```

Add the display name inside `displayName` (after the `scrooge` line):

```swift
        case .scrooge: return "Scrooge"
        case .gordon: return "Ramzi"
```

Add the accent color inside `accentColor` (after the `scrooge` line):

```swift
        case .scrooge: return Color(red: 0.88, green: 0.72, blue: 0.30)  // muted gold #E0B84C
        case .gordon:  return Color(red: 0.80, green: 0.42, blue: 0.34)  // desaturated tomato #CC6B57
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/AgentIdentityTests 2>&1 | tail -20`
Expected: PASS — `testGordonIsAValidCase` and `testScroogeIsAValidCase` succeed.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift ios/JarvisApp/Sources/JarvisAppTests/AgentIdentityTests.swift
git commit -m "feat(ios): add gordon to AgentIdentity (navbar Ramzi) (phase 1)"
```

---

## Task 5: Gordon greetings in GreetingBank

`GreetingBank.phrases(agent:slot:)` is an exhaustive `switch` over `AgentIdentity`, so adding the enum case in Task 4 makes this file fail to compile until a `gordon` branch is added. Give him in-character Russian greetings per time slot.

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Utility/GreetingBank.swift`

- [ ] **Step 1: Confirm the missing case breaks the build**

Run: `cd ios/JarvisApp && xcodebuild build -project JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: FAIL — `switch must be exhaustive` in `GreetingBank.swift` (missing `.gordon`).

- [ ] **Step 2: Add the `gordon` branch**

In `ios/JarvisApp/Sources/JarvisApp/Utility/GreetingBank.swift`, add this case to the `switch agent` block, after the `case .scrooge:` block and before the closing brace of the switch:

```swift
        case .gordon:
            switch slot {
            case .morning: return [
                "Подъём. Что на завтрак — надеюсь, не круассан",
                "Доброе утро. Показывай первую тарелку",
                "Утро. Белок уже был или опять кофе на пустой желудок?",
            ]
            case .day: return [
                "Так. Что ты в себя запихнул с утра?",
                "Покажи тарелку. Не описывай — фото",
                "Обед. И пусть там будет хоть что-то зелёное",
            ]
            case .evening: return [
                "Ужин. Последний шанс добить белок",
                "Показывай, чем заканчиваешь день",
                "Надеюсь, день был чище, чем вчера",
            ]
            case .night: return [
                "Полночь. Надеюсь, холодильник закрыт",
                "Ночной дожор? Даже не думай",
                "Поздно. Вода — да, бутерброд — нет",
            ]
            }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd ios/JarvisApp && xcodebuild build -project JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Utility/GreetingBank.swift
git commit -m "feat(ios): gordon greetings in GreetingBank (phase 1)"
```

---

## Task 6: Full verification + deploy

**Files:** none (verification + deploy).

- [ ] **Step 1: Host build + full test suite**

Run: `pnpm run build && pnpm test`
Expected: build succeeds; vitest green, including `src/bootstrap-trio.test.ts` (6 tests).

- [ ] **Step 2: iOS full test suite**

Run: `cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`. (Substitute an available simulator if needed.)

- [ ] **Step 3: Deploy host changes to the VDS**

The host code (`src/bootstrap-trio.ts`) ships via git + rebuild; the agent files (`groups/gordon/`) ship via scp (groups/ is not tracked in git — see memory `project_instruction_files`).

```bash
git push
scp -r groups/gordon nanoclaw@148.253.211.164:~/nanoclaw/groups/
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw"'
```

On host restart, `bootstrapTrio()` runs: creates the `gordon` agent group + container config, wires it to the iOS messaging group, eager-creates a session, seeds the channel destination, and writes the bootstrap inbound (Gordon stays silent until addressed).

- [ ] **Step 4: Verify the agent group exists on the VDS**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && ./bin/ncl groups list | grep -i gordon && ./bin/ncl destinations list --agent-group-id gordon"'
```
Expected: a `gordon` row in groups; a `channel` destination row pointing at the iOS messaging group.

- [ ] **Step 5: Rebuild + run the iOS app, smoke-test Gordon**

Build the app onto the device/simulator from Xcode (or XcodeBuildMCP). In the app: open the agent picker → confirm «Ramzi» appears with the tomato accent and an in-character greeting on the orb screen → send him a direct message → confirm a reply arrives in his persona (not dropped).

> If the reply is dropped with `Unknown destination in <message to="Unknown">` in the container logs, the channel destination didn't seed — re-check Task 3 / Step 4 above.

- [ ] **Step 6: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "chore(gordon): phase 1 verification fixups"
```

---

## Self-Review

**1. Spec coverage (Phase 1 scope only):**
- "Полноценный агент-пир, канал — iOS-app" → Tasks 2–5 (bootstrap wiring + AgentIdentity).
- "Регистрируется в приложении (enum + цвет + приветствие)" → Tasks 4–5.
- "и в bootstrap-trio (→ переименовать)" → Task 2 (`TRIO`→`TEAM`).
- "Персона Рамзи" → Task 1 CLAUDE.md + Task 5 greetings.
- Channel-destination pitfall (грабля 7 in spec's code-surface note) → Task 3.
- Phases 2–4 surface (scripts, food DB, targets, body-comp, Greg extension, a2a contracts) → explicitly out of scope; stubbed honestly in Task 1 files; deferred to their own plans.

**2. Placeholder scan:** No "TBD"/"add error handling"/"similar to" — every file's full content and every command is inline. ✓

**3. Type/name consistency:** Slug `gordon` is identical across CLAUDE.md, container.json (`agentGroupId`), bootstrap `TEAM` entry, `AgentIdentity` rawValue/parse, and all tests. Navbar string `"Ramzi"` matches between `displayName` and `testGordonIsAValidCase`. `getDestinationByTarget(agentGroupId, 'channel', mg.id)` signature matches `src/modules/agent-to-agent/db/agent-destinations.ts`. `normalizeName`/`createDestination`/`hasTable`/`getDb` imports match their real export sites. ✓

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-11-gordon-phase1-skeleton.md`. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session with checkpoints for review.

Which approach?
