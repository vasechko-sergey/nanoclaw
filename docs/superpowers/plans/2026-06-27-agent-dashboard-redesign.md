# Agent Dashboard Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the health-rings home glance with a per-agent dashboard — each agent shows ≤3 metric chips plus one daily action — reachable from a slim "Сводка" home entry; cards ordered by the picker order.

**Architecture:** Two new optional frontmatter fields (`action`, `metrics`) flow agent → `public.md` → host `parseProfile` → `GET /ios/state` → iOS `StateBoardView` cards. The host parser and endpoint pass the fields through; the iOS board renders chips + action and builds each card header (icon/name/accent/profession) client-side from `AgentIdentity`. Home swaps the 4-ring strip for a tappable summary entry. All fields are optional end-to-end, so host/iOS/agent rollout order doesn't matter.

**Tech Stack:** Host — TypeScript, Node `http`, vitest. iOS — SwiftUI, GRDB, XCTest (`@testable import Jarvis`). Agents — markdown `SKILL.md` publish skills.

---

## File structure

**Host (TypeScript):**
- `src/channels/ios-app/v2/profiles.ts` — add `Metric`, parse `action` + `metrics` (modify)
- `src/channels/ios-app/v2/profiles.test.ts` — parser tests (modify)
- `src/channels/ios-app/v2/http-handler.ts` — pass through fields, reorder `AGENT_ORDER` (modify)
- `src/channels/ios-app/v2/http-routes.test.ts` — endpoint order + passthrough test (modify)

**iOS (Swift):**
- `ios/JarvisApp/Sources/JarvisApp/Models/StateModel.swift` — `Metric` + `metrics`/`action` (modify)
- `ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift` — `profession` + `dashIcon` (modify)
- `ios/JarvisApp/Sources/JarvisApp/Views/StateBoardView.swift` — pure helpers + card redesign (modify)
- `ios/JarvisApp/Sources/JarvisApp/Components/SummaryEntryView.swift` — home entry (create)
- `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` — swap strip → entry (modify, line ~114)
- `ios/JarvisApp/Sources/JarvisApp/Components/HealthStripView.swift` — delete
- `ios/JarvisApp/Sources/JarvisApp/Components/RingView.swift` — delete
- `ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift` — iOS unit tests (create)
- `ios/JarvisApp/project.yml` — version bump (modify)

**Agents (markdown):**
- `groups/{jarvis,payne,greg,scrooge,gordon}/skills/publish/SKILL.md` — emit `action`+`metrics` (modify)
- `groups/INSTRUCTIONS.md` — document the two fields (modify, §Public profiles ~line 52)

---

## Task 1: Host parser — `action` + `metrics`

**Files:**
- Modify: `src/channels/ios-app/v2/profiles.ts`
- Test: `src/channels/ios-app/v2/profiles.test.ts`

- [ ] **Step 1: Write the failing tests**

Replace the `greg` fixture and add cases in `src/channels/ios-app/v2/profiles.test.ts`. The `greg` const becomes:

```ts
const greg = `---
updated: 2026-06-12
summary: Сон 6.2ч, пульс покоя 66, вариабельность ровная. Флагов нет.
action: Лёгкий день — нагрузку не грузи
metrics: [{"v":"68","l":"готовность","t":"warn"},{"v":"↓","l":"восст."},{"v":"6.2ч","l":"сон"}]
levels: {energy: 72, stress: 34, recovery: 81, readiness: 68}
recovery7d: [74, 77, 72, 80, 79, 85, 81]
---
- Пульс покоя: 66 (норма)
- Вариабельность: 55 (выше базы)
`;
```

Add these cases inside `describe('parseProfile', ...)`:

```ts
  it('extracts action and metrics from frontmatter', () => {
    const p = parseProfile('greg', greg);
    expect(p.action).toBe('Лёгкий день — нагрузку не грузи');
    expect(p.metrics).toEqual([
      { v: '68', l: 'готовность', t: 'warn' },
      { v: '↓', l: 'восст.' },
      { v: '6.2ч', l: 'сон' },
    ]);
  });

  it('returns null metrics on malformed JSON, without throwing', () => {
    const text = `---\nsummary: x\nmetrics: [not json\n---\nbody`;
    const p = parseProfile('x', text);
    expect(p.metrics).toBeNull();
    expect(p.action).toBeNull();
  });

  it('clamps metrics to at most 3 and drops malformed entries', () => {
    const text = `---\nmetrics: [{"v":"1","l":"a"},{"v":"2","l":"b"},{"v":"3","l":"c"},{"v":"4","l":"d"},{"l":"no-v"}]\n---\nb`;
    const p = parseProfile('x', text);
    expect(p.metrics).toEqual([
      { v: '1', l: 'a' },
      { v: '2', l: 'b' },
      { v: '3', l: 'c' },
    ]);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm exec vitest run src/channels/ios-app/v2/profiles.test.ts`
Expected: FAIL — `p.action`/`p.metrics` are `undefined` (property doesn't exist yet).

- [ ] **Step 3: Implement parser changes**

In `src/channels/ios-app/v2/profiles.ts`, add the `Metric` interface and a parse helper, extend `ParsedProfile`, and handle the two keys.

Add after the `Levels` interface:

```ts
export interface Metric {
  v: string;
  l: string;
  t?: string;
}
```

Extend `ParsedProfile` to include the two fields:

```ts
export interface ParsedProfile {
  key: string;
  updated: string | null;
  summary: string | null;
  action: string | null;
  metrics: Metric[] | null;
  detail: string;
  levels: Levels | null;
  recovery7d: number[] | null;
}
```

Add this helper above `parseProfile`:

```ts
function parseMetrics(raw: string): Metric[] | null {
  try {
    const arr = JSON.parse(raw.trim());
    if (!Array.isArray(arr)) return null;
    const out: Metric[] = [];
    for (const item of arr) {
      if (out.length >= 3) break;
      if (item && typeof item.v === 'string' && typeof item.l === 'string') {
        const m: Metric = { v: item.v, l: item.l };
        if (typeof item.t === 'string') m.t = item.t;
        out.push(m);
      }
    }
    return out.length ? out : null;
  } catch {
    return null;
  }
}
```

In `parseProfile`, add two locals and two loop branches and return them. Change the declarations block to:

```ts
  let updated: string | null = null;
  let summary: string | null = null;
  let action: string | null = null;
  let metrics: Metric[] | null = null;
  let levels: Levels | null = null;
  let recovery7d: number[] | null = null;
  let detail = text;
```

Add inside the `for (const line of head.split('\n'))` branch chain, after the `summary` branch:

```ts
      else if (k === 'action') action = v.trim();
      else if (k === 'metrics') metrics = parseMetrics(v);
```

Change the return to:

```ts
  return { key, updated, summary, action, metrics, detail, levels, recovery7d };
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm exec vitest run src/channels/ios-app/v2/profiles.test.ts`
Expected: PASS (all cases, including the pre-existing two).

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/profiles.ts src/channels/ios-app/v2/profiles.test.ts
git commit -m "feat(ios-state): parse action + metrics from agent profiles"
```

---

## Task 2: Host endpoint — passthrough + picker order

**Files:**
- Modify: `src/channels/ios-app/v2/http-handler.ts` (lines ~78, ~289–299)
- Test: `src/channels/ios-app/v2/http-routes.test.ts`

- [ ] **Step 1: Write the failing test**

Add this case inside `describe('GET /ios/state', ...)` in `http-routes.test.ts`:

```ts
  it('orders agents by picker order and passes through metrics + action', async () => {
    const profilesDir = join(userGlobalRoot(PERSON), 'profiles');
    mkdirSync(profilesDir, { recursive: true });
    writeFileSync(
      join(profilesDir, 'greg.md'),
      `---\nupdated: 2026-06-13\nsummary: ok\naction: Лёгкий день\nmetrics: [{"v":"68","l":"готовность","t":"warn"},{"v":"6.2ч","l":"сон"}]\n---\nbody`,
    );
    writeFileSync(
      join(profilesDir, 'jarvis.md'),
      `---\nupdated: 2026-06-13\nsummary: focus\naction: 10:00 встреча\nmetrics: [{"v":"2","l":"события"}]\n---\nbody`,
    );

    const r = await fetchJson(`${h.url}/ios/state`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    const body = r.json() as {
      agents: Array<{ key: string; action?: string; metrics?: Array<{ v: string; l: string; t?: string }> }>;
    };
    // Picker order — jarvis is first, ahead of greg.
    expect(body.agents[0].key).toBe('jarvis');
    const greg = body.agents.find((a) => a.key === 'greg')!;
    expect(greg.action).toBe('Лёгкий день');
    expect(greg.metrics).toEqual([
      { v: '68', l: 'готовность', t: 'warn' },
      { v: '6.2ч', l: 'сон' },
    ]);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts -t "orders agents by picker order"`
Expected: FAIL — `body.agents[0].key` is `'greg'` (old order) and `greg.metrics` is `undefined`.

- [ ] **Step 3: Implement the endpoint change**

In `src/channels/ios-app/v2/http-handler.ts`, change `AGENT_ORDER` (line ~78):

```ts
  const AGENT_ORDER = ['jarvis', 'payne', 'greg', 'scrooge', 'gordon'];
```

In the `/ios/state` agents map (lines ~289–299), add `metrics` and `action` to the returned row:

```ts
      const agents = AGENT_ORDER.filter((k) => parsed.has(k)).map((k) => {
        const p = parsed.get(k)!;
        return {
          key: k,
          title: AGENT_META[k].title,
          icon: AGENT_META[k].icon,
          summary: p.summary,
          detail: p.detail,
          updated: p.updated,
          metrics: p.metrics,
          action: p.action,
        };
      });
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts`
Expected: PASS (new case + all pre-existing `/ios/state` and other route cases).

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/http-handler.ts src/channels/ios-app/v2/http-routes.test.ts
git commit -m "feat(ios-state): expose metrics+action, order agents by picker"
```

---

## Task 3: iOS model — `Metric` + `metrics`/`action`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/StateModel.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class AgentDashboardTests: XCTestCase {
    func testAgentRowDecodesMetricsAndAction() throws {
        let json = """
        {"key":"greg","title":"t","icon":"x","summary":"s","detail":"d","updated":"2026-06-13",
         "action":"Лёгкий день","metrics":[{"v":"68","l":"готовность","t":"warn"},{"v":"6.2ч","l":"сон"}]}
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(StateModel.AgentRow.self, from: json)
        XCTAssertEqual(row.action, "Лёгкий день")
        XCTAssertEqual(row.metrics?.count, 2)
        XCTAssertEqual(row.metrics?.first?.v, "68")
        XCTAssertEqual(row.metrics?.first?.t, "warn")
        XCTAssertNil(row.metrics?.last?.t)
    }

    func testAgentRowDecodesWithoutNewFields() throws {
        let json = #"{"key":"x","title":"t","icon":"i","summary":"s","detail":"d","updated":null}"#.data(using: .utf8)!
        let row = try JSONDecoder().decode(StateModel.AgentRow.self, from: json)
        XCTAssertNil(row.metrics)
        XCTAssertNil(row.action)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd ios/JarvisApp && xcodegen generate
xcodebuild test -project JarvisApp.xcodeproj -scheme Jarvis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisAppTests/AgentDashboardTests 2>&1 | tail -25
```
Expected: COMPILE FAILURE — `value of type 'StateModel.AgentRow' has no member 'metrics'`.
(If `iPhone 16` isn't installed, pick one from `xcrun simctl list devices available`.)

- [ ] **Step 3: Implement the model change**

In `ios/JarvisApp/Sources/JarvisApp/Models/StateModel.swift`, add a `Metric` struct and two fields to `AgentRow`:

```swift
import Foundation

struct StateModel: Codable, Equatable {
    struct Levels: Codable, Equatable {
        var energy: Int?; var stress: Int?; var recovery: Int?; var readiness: Int?
        var recovery7d: [Int]?; var updated: String?
    }
    struct Metric: Codable, Equatable {
        var v: String
        var l: String
        var t: String?
    }
    struct AgentRow: Codable, Equatable, Identifiable {
        var key: String; var title: String; var icon: String
        var summary: String?; var detail: String?; var updated: String?
        var metrics: [Metric]?; var action: String?
        var id: String { key }
    }
    var levels: Levels
    var agents: [AgentRow]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme Jarvis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisAppTests/AgentDashboardTests 2>&1 | tail -25
```
Expected: PASS (`** TEST SUCCEEDED **`).

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/StateModel.swift \
  ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): StateModel carries metrics + action"
```

---

## Task 4: iOS identity — `profession` + `dashIcon`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `AgentDashboardTests`:

```swift
    func testProfessions() {
        XCTAssertEqual(AgentIdentity.jarvis.profession, "дворецкий")
        XCTAssertEqual(AgentIdentity.payne.profession, "тренер")
        XCTAssertEqual(AgentIdentity.greg.profession, "врач-диагност")
        XCTAssertEqual(AgentIdentity.scrooge.profession, "казначей")
        XCTAssertEqual(AgentIdentity.gordon.profession, "повар")
    }

    func testPickerOrderIsCanonical() {
        XCTAssertEqual(AgentIdentity.allCases.map(\.rawValue),
                       ["jarvis", "payne", "greg", "scrooge", "gordon"])
    }

    func testDashIconsNonEmpty() {
        for a in AgentIdentity.allCases { XCTAssertFalse(a.dashIcon.isEmpty) }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme Jarvis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisAppTests/AgentDashboardTests/testProfessions 2>&1 | tail -25
```
Expected: COMPILE FAILURE — `value of type 'AgentIdentity' has no member 'profession'`.

- [ ] **Step 3: Implement the identity additions**

In `ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift`, add two computed properties after `accentColor` (before `suggestions`):

```swift
    /// Profession label shown as the dashboard card subtitle (the persona's
    /// trade, not the domain): "Dr House · врач-диагност".
    var profession: String {
        switch self {
        case .jarvis:  return "дворецкий"
        case .payne:   return "тренер"
        case .greg:    return "врач-диагност"
        case .scrooge: return "казначей"
        case .gordon:  return "повар"
        }
    }

    /// SF Symbol for the dashboard card header. All are available on iOS 16.0.
    var dashIcon: String {
        switch self {
        case .jarvis:  return "bell.fill"
        case .payne:   return "figure.strengthtraining.traditional"
        case .greg:    return "stethoscope"
        case .scrooge: return "banknote.fill"
        case .gordon:  return "fork.knife"
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme Jarvis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisAppTests/AgentDashboardTests 2>&1 | tail -25
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift \
  ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift
git commit -m "feat(ios): AgentIdentity profession + dashboard icon"
```

---

## Task 5: iOS dashboard — pure helpers (TDD)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/StateBoardView.swift` (add static helpers only; body unchanged this task)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `AgentDashboardTests`:

```swift
    private func row(action: String?) -> StateModel.AgentRow {
        StateModel.AgentRow(key: "k", title: "t", icon: "i",
                            summary: nil, detail: nil, updated: nil,
                            metrics: nil, action: action)
    }

    func testShowsAction() {
        XCTAssertTrue(StateBoardView.showsAction("Лёгкий день"))
        XCTAssertFalse(StateBoardView.showsAction("—"))
        XCTAssertFalse(StateBoardView.showsAction(nil))
        XCTAssertFalse(StateBoardView.showsAction("   "))
    }

    func testActionableCount() {
        let rows = [row(action: "a"), row(action: "—"), row(action: nil), row(action: "b")]
        XCTAssertEqual(StateBoardView.actionableCount(rows), 2)
    }

    func testMetricToneParse() {
        XCTAssertEqual(StateBoardView.MetricTone.parse("ok"), .ok)
        XCTAssertEqual(StateBoardView.MetricTone.parse("warn"), .warn)
        XCTAssertEqual(StateBoardView.MetricTone.parse("bad"), .bad)
        XCTAssertEqual(StateBoardView.MetricTone.parse(nil), .neutral)
        XCTAssertEqual(StateBoardView.MetricTone.parse("nonsense"), .neutral)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme Jarvis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisAppTests/AgentDashboardTests/testShowsAction 2>&1 | tail -25
```
Expected: COMPILE FAILURE — `type 'StateBoardView' has no member 'showsAction'`.

- [ ] **Step 3: Add the helpers (body still references rings — that's fine for this task)**

In `ios/JarvisApp/Sources/JarvisApp/Views/StateBoardView.swift`, add inside `struct StateBoardView`, right after the existing `freshness(...)`/`todayKey()` helpers:

```swift
    /// Chip tone parsed from the optional `t` field on a Metric.
    enum MetricTone: Equatable {
        case ok, warn, bad, neutral
        static func parse(_ t: String?) -> MetricTone {
            switch t {
            case "ok":   return .ok
            case "warn": return .warn
            case "bad":  return .bad
            default:     return .neutral
            }
        }
    }

    /// An action line is shown only when present and not the "—" placeholder.
    static func showsAction(_ action: String?) -> Bool {
        guard let a = action?.trimmingCharacters(in: .whitespaces), !a.isEmpty, a != "—" else { return false }
        return true
    }

    /// Count of agents with a real action today — drives the home "Сводка · N" entry.
    static func actionableCount(_ agents: [StateModel.AgentRow]) -> Int {
        agents.filter { showsAction($0.action) }.count
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme Jarvis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisAppTests/AgentDashboardTests 2>&1 | tail -25
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/StateBoardView.swift \
  ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift
git commit -m "feat(ios): dashboard pure helpers (tone, showsAction, actionableCount)"
```

---

## Task 6: iOS dashboard — card redesign (remove rings)

**Files:**
- Modify (full rewrite): `ios/JarvisApp/Sources/JarvisApp/Views/StateBoardView.swift`

This task replaces the rings + accordion body with the variant-A card (header → chips → action → tap-to-expand detail). The pure helpers from Task 5 are preserved. `Sparkline` is preserved (Greg's expand sparkline).

- [ ] **Step 1: Rewrite the file**

Write `ios/JarvisApp/Sources/JarvisApp/Views/StateBoardView.swift` with exactly:

```swift
import SwiftUI

/// The agent dashboard — one card per agent (picker order), each with metric
/// chips and one daily action; tap a card to expand its detail text. Replaces
/// the old 4-ring health glance.
struct StateBoardView: View {
    @ObservedObject var service: StateService
    @State private var expanded: Set<String> = []

    enum Freshness { case today, stale, unknown }
    static func freshness(updated: String?, today: String) -> Freshness {
        guard let u = updated else { return .unknown }
        return u == today ? .today : .stale
    }
    private static func todayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    enum MetricTone: Equatable {
        case ok, warn, bad, neutral
        static func parse(_ t: String?) -> MetricTone {
            switch t {
            case "ok":   return .ok
            case "warn": return .warn
            case "bad":  return .bad
            default:     return .neutral
            }
        }
    }

    static func showsAction(_ action: String?) -> Bool {
        guard let a = action?.trimmingCharacters(in: .whitespaces), !a.isEmpty, a != "—" else { return false }
        return true
    }

    static func actionableCount(_ agents: [StateModel.AgentRow]) -> Int {
        agents.filter { showsAction($0.action) }.count
    }

    private func identity(_ key: String) -> AgentIdentity? { AgentIdentity(rawValue: key) }
    private func accent(_ key: String) -> Color { identity(key)?.accentColor ?? Theme.accent }

    private func toneColor(_ tone: MetricTone) -> Color {
        switch tone {
        case .ok:      return AgentIdentity.greg.accentColor      // sage
        case .warn:    return AgentIdentity.scrooge.accentColor   // gold
        case .bad:     return AgentIdentity.gordon.accentColor    // tomato
        case .neutral: return Theme.textPrimary
        }
    }

    private func headerTitle(_ a: StateModel.AgentRow) -> String {
        if let id = identity(a.key) { return "\(id.displayName) · \(id.profession)" }
        return a.title
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.scaled(10)) {
                ForEach(service.state?.agents ?? []) { a in
                    cardView(a)
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, Theme.scaled(12))
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Сводка")
        .onAppear { service.refresh() }
    }

    @ViewBuilder
    private func cardView(_ a: StateModel.AgentRow) -> some View {
        let isOpen = expanded.contains(a.key)
        let ac = accent(a.key)
        let stale = Self.freshness(updated: a.updated, today: Self.todayKey()) == .stale

        VStack(alignment: .leading, spacing: Theme.scaled(9)) {
            HStack(spacing: 8) {
                Image(systemName: identity(a.key)?.dashIcon ?? "circle")
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundColor(ac)
                Text(headerTitle(a))
                    .font(.system(size: Theme.fontSubhead, weight: .semibold))
                    .foregroundColor(ac)
                Spacer()
                Circle().fill(stale ? Theme.textSecondary : Theme.online)
                    .frame(width: 6, height: 6)
                if let u = a.updated {
                    Text(u).font(.system(size: Theme.fontCaption)).foregroundColor(Theme.textSecondary)
                }
            }

            if let metrics = a.metrics, !metrics.isEmpty {
                HStack(spacing: 7) {
                    ForEach(Array(metrics.enumerated()), id: \.offset) { _, m in chip(m) }
                }
            }

            if Self.showsAction(a.action), let action = a.action {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right").font(.system(size: Theme.fontCaption))
                    Text(action).font(.system(size: Theme.fontCaption))
                    Spacer(minLength: 0)
                }
                .foregroundColor(ac)
            }

            if isOpen {
                if let d = a.detail, !d.isEmpty {
                    Text(d).font(.system(size: Theme.fontCaption))
                        .foregroundColor(Theme.textSecondary).padding(.top, 2)
                }
                if a.key == "greg", let series = service.state?.levels.recovery7d, series.count > 1 {
                    Sparkline(values: series)
                        .stroke(AgentIdentity.greg.accentColor, lineWidth: 2)
                        .frame(height: 26).padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, Theme.scaled(13))
        .padding(.vertical, Theme.scaled(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.surfaceBorder, lineWidth: 0.5)
        )
        .opacity(stale ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if isOpen { expanded.remove(a.key) } else { expanded.insert(a.key) } }
    }

    @ViewBuilder
    private func chip(_ m: StateModel.Metric) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(m.v)
                .font(.system(size: Theme.fontSubhead, weight: .semibold))
                .foregroundColor(toneColor(MetricTone.parse(m.t)))
            Text(m.l)
                .font(.system(size: Theme.fontCaption))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Normalized 0-100 series → path in unit rect. Used for Greg's recovery7d.
struct Sparkline: Shape {
    let values: [Int]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let maxV = max(values.max() ?? 100, 1)
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: rect.minX + CGFloat(i) * step,
                             y: rect.maxY - (CGFloat(v) / CGFloat(maxV)) * rect.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
```

- [ ] **Step 2: Build + run the dashboard tests**

Run:
```bash
cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme Jarvis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisAppTests 2>&1 | tail -30
```
Expected: BUILD SUCCEEDS and PASS. (`RingView` no longer referenced by `StateBoardView`; it is still referenced by `HealthStripView` until Task 8, so the project still compiles.)

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/StateBoardView.swift
git commit -m "feat(ios): dashboard cards with metric chips + action, drop rings"
```

---

## Task 7: iOS home — "Сводка" entry replaces ring strip

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Components/SummaryEntryView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` (line ~114)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift`

- [ ] **Step 1: Write the failing test (Russian plural)**

Add to `AgentDashboardTests`:

```swift
    func testSummaryPlural() {
        XCTAssertEqual(SummaryEntryView.plural(1), "дело")
        XCTAssertEqual(SummaryEntryView.plural(2), "дела")
        XCTAssertEqual(SummaryEntryView.plural(4), "дела")
        XCTAssertEqual(SummaryEntryView.plural(5), "дел")
        XCTAssertEqual(SummaryEntryView.plural(11), "дел")
        XCTAssertEqual(SummaryEntryView.plural(21), "дело")
        XCTAssertEqual(SummaryEntryView.plural(0), "дел")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme Jarvis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisAppTests/AgentDashboardTests/testSummaryPlural 2>&1 | tail -25
```
Expected: COMPILE FAILURE — `cannot find 'SummaryEntryView' in scope`.

- [ ] **Step 3: Create the entry view**

Create `ios/JarvisApp/Sources/JarvisApp/Components/SummaryEntryView.swift`:

```swift
import SwiftUI

/// Slim home-screen entry that replaces the 4-ring health strip. Shows the
/// count of agents with a daily action and opens the full dashboard on tap.
struct SummaryEntryView: View {
    let agents: [StateModel.AgentRow]

    private var count: Int { StateBoardView.actionableCount(agents) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: Theme.fontSubhead))
                .foregroundColor(Theme.accent)
            Text(count > 0 ? "Сводка · \(count) \(Self.plural(count))" : "Сводка")
                .font(.system(size: Theme.fontSubhead))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: Theme.fontCaption))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.scaled(16))
        .padding(.vertical, Theme.scaled(11))
        .background(Theme.surface, in: Capsule())
        .accessibilityIdentifier("home-summary-entry")
    }

    /// Russian plural for "дело" (1 дело / 2 дела / 5 дел).
    static func plural(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "дело" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "дела" }
        return "дел"
    }
}
```

- [ ] **Step 4: Swap the strip in OrbHomeView**

In `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`, replace the block at lines ~114–116:

```swift
                    HealthStripView(levels: stateService.state?.levels)
                        .onTapGesture { showStateBoard = true }
                        .padding(.bottom, Theme.scaled(8))
```

with:

```swift
                    SummaryEntryView(agents: stateService.state?.agents ?? [])
                        .onTapGesture { showStateBoard = true }
                        .padding(.horizontal, Theme.hPadding)
                        .padding(.bottom, Theme.scaled(8))
```

(The `.sheet(isPresented: $showStateBoard) { NavigationView { StateBoardView(service: stateService) } }` at lines ~222–224 stays as-is.)

- [ ] **Step 5: Regenerate, build, test**

Run:
```bash
cd ios/JarvisApp && xcodegen generate
xcodebuild test -project JarvisApp.xcodeproj -scheme Jarvis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisAppTests 2>&1 | tail -30
```
Expected: BUILD SUCCEEDS and PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/SummaryEntryView.swift \
  ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift \
  ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): home Сводка entry replaces health ring strip"
```

---

## Task 8: iOS cleanup — delete unused ring views

**Files:**
- Delete: `ios/JarvisApp/Sources/JarvisApp/Components/HealthStripView.swift`
- Delete: `ios/JarvisApp/Sources/JarvisApp/Components/RingView.swift`
- Modify: `ios/JarvisApp/JarvisApp.xcodeproj` (via xcodegen)

- [ ] **Step 1: Confirm both are now unreferenced**

Run:
```bash
grep -rnE 'RingView|HealthStripView' ios/JarvisApp/Sources --include='*.swift'
```
Expected: only the two definition files match (no usage sites). If any usage remains, stop and resolve it before deleting.

- [ ] **Step 2: Delete the files and regenerate the project**

```bash
git rm ios/JarvisApp/Sources/JarvisApp/Components/HealthStripView.swift \
  ios/JarvisApp/Sources/JarvisApp/Components/RingView.swift
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 3: Build + full test run**

Run:
```bash
cd ios/JarvisApp && xcodebuild test -project JarvisApp.xcodeproj -scheme Jarvis \
  -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests 2>&1 | tail -30
```
Expected: BUILD SUCCEEDS and PASS (nothing references the deleted views).

- [ ] **Step 4: Commit**

```bash
git add -A ios/JarvisApp
git commit -m "chore(ios): delete unused RingView + HealthStripView"
```

---

## Task 9: iOS version bump

**Files:**
- Modify: `ios/JarvisApp/project.yml`
- Modify: `ios/JarvisApp/JarvisApp.xcodeproj` (via xcodegen)

- [ ] **Step 1: Read the current versions**

Run:
```bash
grep -nE 'CURRENT_PROJECT_VERSION|MARKETING_VERSION' ios/JarvisApp/project.yml
```

- [ ] **Step 2: Bump**

Edit `ios/JarvisApp/project.yml`: increment `CURRENT_PROJECT_VERSION` by 1 (e.g. `60` → `61`) and bump `MARKETING_VERSION` minor by 1 for the feature (e.g. `1.x` → `1.(x+1)`). Then:

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "chore(ios): bump build for dashboard redesign"
```

---

## Task 10: Greg publish skill — metrics + action

**Files:**
- Modify: `groups/greg/skills/publish/SKILL.md`

- [ ] **Step 1: Edit the frontmatter template**

In the fenced template block, replace:

```
   ---
   updated: <generated_at, YYYY-MM-DD>
   summary: <latest_line дословно>
   levels: {energy: <levels.energy>, stress: <levels.stress>, recovery: <levels.recovery>, readiness: <levels.readiness>}
   recovery7d: <recovery7d как JSON-массив, напр. [74,77,72,80,79,85,81]>
   ---
```

with:

```
   ---
   updated: <generated_at, YYYY-MM-DD>
   summary: <latest_line дословно>
   action: <совет дня: при просевшем восстановлении — «Лёгкий день — нагрузку не грузи»; при хорошем — «Можно грузить»; иначе «—»>
   metrics: [{"v":"<score>","l":"готовность","t":"<ok если score≥70 / warn если 50-69 / bad если <50>"},{"v":"<↑ если recovery вырос / ↓ если просел / ровно>","l":"восст.","t":"<ok если ↑ или ровно / warn если ↓>"},{"v":"<sleepHours>ч","l":"сон"}]
   levels: {energy: <levels.energy>, stress: <levels.stress>, recovery: <levels.recovery>, readiness: <levels.readiness>}
   recovery7d: <recovery7d как JSON-массив, напр. [74,77,72,80,79,85,81]>
   ---
```

- [ ] **Step 2: Keep energy/stress in the body (they leave the rings, land in expand-detail)**

In the same template's body, replace:

```
   восстановление: <↑ хорошее | ↓ просело | ровно>
   тренд: <latest_line дословно>
```

with:

```
   восстановление: <↑ хорошее | ↓ просело | ровно>
   энергия/стресс: <levels.energy>/<levels.stress> (справочно)
   тренд: <latest_line дословно>
```

- [ ] **Step 3: Add a build note under Дисциплина**

Append to the `## Дисциплина` list:

```
- `metrics` — ровно 3 чипа, значения короткие (число / стрелка / «6.2ч»). `action` — одно дело или «—». Оба — одной строкой (как `recovery7d`).
```

- [ ] **Step 4: Commit**

```bash
git add groups/greg/skills/publish/SKILL.md
git commit -m "feat(greg): publish dashboard metrics + action"
```

---

## Task 11: Payne publish skill — metrics + action

**Files:**
- Modify: `groups/payne/skills/publish/SKILL.md`

- [ ] **Step 1: Edit the frontmatter template**

Replace:

```
   ---
   updated: <сегодня, YYYY-MM-DD>
   summary: <name>, нед. <current_week>/<total_weeks> (<intensity label>); следующая — <тип следующего дня>.
   ---
```

with:

```
   ---
   updated: <сегодня, YYYY-MM-DD>
   summary: <name>, нед. <current_week>/<total_weeks> (<intensity label>); следующая — <тип следующего дня>.
   action: <если трен-день сегодня: «Тренировка <тип дня> · <оценка длительности> мин»; иначе «Отдых, растяжка»>
   metrics: [{"v":"<current_week>/<total_weeks>","l":"неделя"},{"v":"<тип след. дня, или 'отдых' если сегодня не трен-день>","l":"сегодня"},{"v":"<intensity label кратко>","l":"интенс."}]
   ---
```

- [ ] **Step 2: Commit**

```bash
git add groups/payne/skills/publish/SKILL.md
git commit -m "feat(payne): publish dashboard metrics + action"
```

---

## Task 12: Scrooge publish skill — metrics + action (bands only)

**Files:**
- Modify: `groups/scrooge/skills/publish/SKILL.md`

- [ ] **Step 1: Edit the frontmatter template**

Replace:

```
   ---
   updated: <asof, YYYY-MM-DD>
   summary: Запас <полоса>; траты <направление>; доход покрывает: <да | нет>.
   ---
```

with:

```
   ---
   updated: <asof, YYYY-MM-DD>
   summary: Запас <полоса>; траты <направление>; доход покрывает: <да | нет>.
   action: <если траты заметно растут — «Проверь подписки/категории»; иначе «—»>
   metrics: [{"v":"<полоса запаса кратко: '<3м' / '3–6м' / '6–12м' / '>год'>","l":"запас"},{"v":"<±<pct>% или 'ровно'>","l":"траты","t":"<bad если растут / ok если падают / нет t если ровно>"},{"v":"<✓ если доход покрывает, иначе ✗>","l":"доход","t":"<ok если ✓ / bad если ✗>"}]
   ---
```

- [ ] **Step 2: Reinforce the no-sums guardrail**

Append to the `## Дисциплина` list:

```
- `metrics` тоже ТОЛЬКО полосы/проценты/✓✗ — никаких сумм в чипах. Точные `*_usd` под запретом и здесь.
```

- [ ] **Step 3: Commit**

```bash
git add groups/scrooge/skills/publish/SKILL.md
git commit -m "feat(scrooge): publish dashboard metrics + action (bands only)"
```

---

## Task 13: Gordon publish skill — metrics + action

**Files:**
- Modify: `groups/gordon/skills/publish/SKILL.md`

- [ ] **Step 1: Edit the frontmatter template**

Replace:

```
   ---
   updated: <date из rollup>
   summary: Рекомп: белок <«добор» если protein_hit, иначе «недобор»>, калории <kcal_pct>% цели.
   ---
```

with:

```
   ---
   updated: <date из rollup>
   summary: Рекомп: белок <«добор» если protein_hit, иначе «недобор»>, калории <kcal_pct>% цели.
   action: <если белок недобор — «Добери <дефицит белка>г белка к ужину»; иначе «—»>
   metrics: [{"v":"<kcal_pct>%","l":"ккал"},{"v":"<+N или −N г к таргету белка>","l":"белок","t":"<ok если protein_hit / warn если недобор>"}]
   ---
```

- [ ] **Step 2: Commit**

```bash
git add groups/gordon/skills/publish/SKILL.md
git commit -m "feat(gordon): publish dashboard metrics + action"
```

---

## Task 14: Jarvis publish skill + shared contract doc

**Files:**
- Modify: `groups/jarvis/skills/publish/SKILL.md`
- Modify: `groups/INSTRUCTIONS.md` (§Public profiles, ~line 52)

- [ ] **Step 1: Edit the Jarvis frontmatter template**

Replace:

```
   ---
   updated: <сегодня YYYY-MM-DD>
   summary: <фокус одной фразой или «—»>; <локация>; <1 ближайшее событие или «—»>.
   ---
```

with:

```
   ---
   updated: <сегодня YYYY-MM-DD>
   summary: <фокус одной фразой или «—»>; <локация>; <1 ближайшее событие или «—»>.
   action: <ближайшее событие как дело: «10:00 встреча — выйти в 9:40»; если событий нет — «—»>
   metrics: [{"v":"<N событий сегодня>","l":"события"},{"v":"<город/место кратко>","l":"место"}]
   ---
```

- [ ] **Step 2: Document the contract in INSTRUCTIONS.md**

In `groups/INSTRUCTIONS.md`, in the `## Public profiles` section, insert a new paragraph immediately after the line that begins `Publish: keep your own summary current in ...` (~line 52):

```
Dashboard fields (optional). Two single-line frontmatter fields feed the iOS dashboard: `action:` — the one thing the owner should do today, one line, or `—`; and `metrics:` — a JSON array of up to 3 chips `{ "v": <short value>, "l": <short label>, "t"?: "ok" | "warn" | "bad" }` (`t` tints the value: ok=sage, warn=gold, bad=tomato). Both are single-line like `recovery7d`. Omit them and your card still renders summary + detail.
```

- [ ] **Step 3: Commit**

```bash
git add groups/jarvis/skills/publish/SKILL.md groups/INSTRUCTIONS.md
git commit -m "feat(jarvis): publish dashboard metrics + action; document contract"
```

---

## Task 15: Deploy + verify (ops — run when ready)

Host code is host-mounted server TypeScript: it needs a rebuild + restart. Agent `groups/` are gitignored and live-deployed by scp + rebirth. iOS is built on-device by the owner.

- [ ] **Step 1: Host — build, push, deploy on VDS**

```bash
pnpm run build && git push
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw"'
```

- [ ] **Step 2: Agents — scp the 5 publish skills + INSTRUCTIONS to VDS, then rebirth**

scp each modified `groups/<agent>/skills/publish/SKILL.md` and `groups/INSTRUCTIONS.md` to the VDS install, then force live sessions to reload the skill (kill containers + DELETE the `continuation` rows for each agent's sessions). Trigger a one-off publish task (or wait for the 08:45 cron) so `profiles/*.md` gain the new fields. (Use the established rebirth procedure — `find`, not glob, over session DBs.)

- [ ] **Step 3: Verify the endpoint shows the new fields**

```bash
ssh root@148.253.211.164 "curl -s -H 'Authorization: Bearer <token>' http://127.0.0.1:3001/ios/state | head -c 1200"
```
Expected: `agents[0].key == "jarvis"`, and at least one agent row carries `metrics` + `action` once that agent has republished.

- [ ] **Step 4: iOS — owner builds + installs**

The owner (Сергей) builds the bumped version in Xcode and installs on device. Verify: home shows the "Сводка · N дел" entry (no rings); tapping opens the dashboard with cards in order jarvis → payne → greg → scrooge → gordon; each card shows chips + an action; tapping a card expands detail; Greg's card shows the recovery sparkline on expand; stale agents dim.

---

## Notes for the implementer

- **iOS simulator name:** examples use `iPhone 16`. If unavailable, run `xcrun simctl list devices available` and substitute an installed simulator.
- **Test module name is `Jarvis`** (the product name), not `JarvisApp` — `@testable import Jarvis`. A wrong name yields a misleading "unable to resolve module dependency" error.
- **`xcodegen generate`** must run after adding/removing any `.swift` file before building, or the new/removed file won't be in the project.
- **SF Symbols** in `dashIcon` are all iOS-16-available; if a device shows a blank glyph, swap for a known-present fallback (e.g. `dollarsign.circle.fill` for scrooge, `dumbbell.fill` for payne on iOS 16.1+).
- **Backward compatibility:** every iOS change treats `metrics`/`action` as optional, so the app renders correctly against profiles that haven't republished yet (cards show name + summary/detail; `Сводка` count = 0).
