# Scrooge Finance Agent — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working Scrooge finance agent — reachable in the iOS app, with a USD-normalized SQLite ledger fed by manual NL entry + Bybit, subscription detection, Greg-pattern analyze + proactive pings, on-demand reports, canvas charts, and a hybrid Scrooge McDuck/Ebenezer persona.

**Architecture:** Per-agent-group container (Bun) like Greg/Payne. Heavy lifting in exported Bun script functions (TDD'd with `bun:test`); the agent invokes their CLI entrypoints by absolute path and reads small JSON outputs — the ledger and raw statements never enter LLM context. Credentials for Bybit live in `groups/scrooge/scripts/.env` (the native credential proxy is Anthropic-only). iOS reaches Scrooge via the existing multi-agent `ios-app-v2` channel (agent_id tag → per-agent session).

**Tech Stack:** Bun, `bun:sqlite`, `bun:test`, `node:crypto` (HMAC), `@napi-rs/canvas` (charts, already in image via surf-forecast), SwiftUI + XcodeBuildMCP, nanoclaw `ncl` + `tsx` for DB scaffolding.

**Spec:** `docs/superpowers/specs/2026-06-09-scrooge-finance-agent-design.md`

---

## Execution environment

NanoClaw runs on the VDS (`root@148.253.211.164`, service account `nanoclaw`, `~/nanoclaw`). Workflow ([[feedback_workflow]]): **edit files locally → commit → push → `git pull` + `pnpm run build` on VDS**. Never SSH-edit files.

- **Local (committed, pushed):** everything under `groups/scrooge/`, iOS Swift, this plan.
- **VDS (DB mutations over SSH):** create agent group, container_config, wiring, a2a destinations, schedule, secret mode.
- **`bun test`** runs wherever Bun is installed (locally if present, else on VDS). All logic tests are network-free (HTTP isolated behind injected fns).

SSH form (from [[reference_vds_workflow]]): `ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && <cmd>"'`. The in-tree query wrapper is `pnpm exec tsx scripts/q.ts <db> "<sql>"`.

---

## File Structure

**Created (local, committed):**
- `groups/scrooge/CLAUDE.md` — persona, workflow, token-economy rules, guardrails, failure modes.
- `groups/scrooge/INDEX.md` — context warm-up, rewritten each scan.
- `groups/scrooge/.gitignore` — ignore `finance/` and `scripts/.env`.
- `groups/scrooge/scripts/_env.js` — copied verbatim from `groups/jarvis/scripts/_env.js`.
- `groups/scrooge/scripts/ledger.js` + `ledger.test.js` — schema, id-hash, upsert/dedup.
- `groups/scrooge/scripts/fx.js` + `fx.test.js` — USD conversion + cached rate fetch.
- `groups/scrooge/scripts/normalize.js` + `normalize.test.js` — fill `amount_usd` on a raw tx.
- `groups/scrooge/scripts/add-transaction.js` + `add-transaction.test.js` — manual-entry CLI.
- `groups/scrooge/scripts/sync-bybit.js` + `sync-bybit.test.js` — Bybit v5 pull (map + sign).
- `groups/scrooge/scripts/detect-subscriptions.js` + `detect-subscriptions.test.js` — recurring detection.
- `groups/scrooge/scripts/analyze.js` + `analyze.test.js` — findings (categories, anomalies, cuttable).
- `groups/scrooge/scripts/report.js` + `report.test.js` — on-demand query/format.
- `groups/scrooge/scripts/render-chart.cjs` — canvas chart → jpg (node).
- `groups/scrooge/memories/state.md` — pings suppress/watermark (seed empty).

**Modified (local, committed):**
- `ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift` — add `.scrooge`.
- `ios/JarvisApp/Sources/JarvisApp/Utility/GreetingBank.swift` — add `.scrooge` phrases.
- `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` — move greeting to bottom.
- `ios/JarvisApp/Sources/JarvisAppTests/` — small unit tests for the two iOS models.

**DB mutations (VDS, not files):** agent_groups, container_configs, messaging_group_agents (wiring), agent_destinations.

**Module contract (all scripts):** export pure functions; gate side-effecting CLI behind `if (import.meta.main) { … }`. SQLite access via `bun:sqlite`; functions take a `Database` handle (dependency injection) so tests use `new Database(":memory:")`. `bun:sqlite` named params require the `$` prefix in **both** SQL and the JS keys.

---

## Part A — Scaffold + wiring (VDS)

### Task A1: Create the `scrooge` agent group + container_config

**Files:** none committed — one-off tsx run on VDS (mirrors [[reference_create_agent]]; `ncl groups create` ignores `--id` and skips `container_configs`).

- [ ] **Step 1: Write the bootstrap script to a temp file on VDS**

Run:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw tee /tmp/mk-scrooge.ts > /dev/null' <<'EOF'
import { initDb } from "/home/nanoclaw/nanoclaw/src/db/connection.js";
import { createAgentGroup, getAgentGroup } from "/home/nanoclaw/nanoclaw/src/db/agent-groups.js";
import { ensureContainerConfig } from "/home/nanoclaw/nanoclaw/src/db/container-configs.js";
initDb("/home/nanoclaw/nanoclaw/data/v2.db");
if (!getAgentGroup("scrooge")) {
  createAgentGroup({ id: "scrooge", name: "Scrooge", folder: "scrooge", agent_provider: null, created_at: new Date().toISOString() });
}
ensureContainerConfig("scrooge");
console.log("scrooge:", JSON.stringify(getAgentGroup("scrooge")));
EOF
```

- [ ] **Step 2: Run it**

Run:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && pnpm -s exec tsx /tmp/mk-scrooge.ts && rm /tmp/mk-scrooge.ts"'
```
Expected: prints `scrooge: {"id":"scrooge","name":"Scrooge","folder":"scrooge",...}`.

- [ ] **Step 3: Verify the rows exist**

Run:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && ./bin/ncl groups get scrooge"'
```
Expected: group row prints with `id=scrooge`. No "Container config not found" later at spawn.

### Task A2: Group folder scaffold + `_env.js` + ignores

**Files:**
- Create: `groups/scrooge/{CLAUDE.md (stub), INDEX.md (stub), .gitignore, memories/state.md}`
- Create: `groups/scrooge/scripts/_env.js` (copy)
- Create dirs: `groups/scrooge/finance/`, `groups/scrooge/scripts/`

- [ ] **Step 1: Create dirs and copy `_env.js`**

Run:
```bash
mkdir -p groups/scrooge/scripts groups/scrooge/finance groups/scrooge/memories
cp groups/jarvis/scripts/_env.js groups/scrooge/scripts/_env.js
```

- [ ] **Step 2: Write `.gitignore`**

`groups/scrooge/.gitignore`:
```gitignore
# Runtime data + secrets — never commit
finance/
scripts/.env
```

- [ ] **Step 3: Seed stubs**

`groups/scrooge/memories/state.md`:
```markdown
# Scrooge state

## Watermarks
- bybit_last_sync: (none)

## Suppressed pings
(none)
```

`groups/scrooge/INDEX.md`:
```markdown
# Scrooge INDEX

> Перепиши целиком после каждого scan.

## Баланс (USD, по источникам)
- (нет данных)

## Топ категорий за 30 дней
- (нет данных)

## Активные подписки
- (нет данных)

## Последний пинг
- (none)
```

`groups/scrooge/CLAUDE.md` — single-line stub for now (filled in Task D1):
```markdown
# Scrooge — Finance Agent (stub, see Task D1)
```

- [ ] **Step 4: Commit**

```bash
git add groups/scrooge/.gitignore groups/scrooge/INDEX.md groups/scrooge/memories/state.md groups/scrooge/scripts/_env.js groups/scrooge/CLAUDE.md
git commit -m "feat(scrooge): scaffold group folder + _env.js"
```

### Task A3: Wire iOS channel + a2a destinations (VDS)

**Files:** none — `ncl` mutations on VDS. The iOS messaging_group id is install-specific; copy Payne's wiring settings.

- [ ] **Step 1: Find the iOS messaging group + Payne's wiring**

Run:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && ./bin/ncl wirings list && echo --- && ./bin/ncl messaging-groups list"'
```
Expected: note the `messaging_group_id` whose `channel_type` is `ios-app-v2` and that Payne/Greg are wired to. Note Payne's wiring `session_mode` + `trigger_rules`.

- [ ] **Step 2: Create the Scrooge wiring (mirror Payne)**

Run (substitute `<IOS_MG_ID>` and Payne's `session_mode`):
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && ./bin/ncl wirings create --messaging-group-id <IOS_MG_ID> --agent-group-id scrooge --session-mode <SAME_AS_PAYNE>"'
```
Expected: prints the new wiring row.

- [ ] **Step 3: Create a2a destinations both directions**

Run:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && ./bin/ncl destinations add --agent-group-id jarvis --local-name scrooge --target-type agent --target-id scrooge && ./bin/ncl destinations add --agent-group-id scrooge --local-name jarvis --target-type agent --target-id jarvis"'
```
Expected: two destination rows printed.

- [ ] **Step 4: If Jarvis container is live, re-project its destinations**

(Grabля 6: a live agent holds the old destination projection.) Run:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && ./bin/ncl sessions list | grep jarvis"'
```
If a live jarvis session exists, write a `/tmp/reproj.ts` calling `writeDestinations("jarvis", "<jarvis-session-id>")` (import from `src/modules/agent-to-agent/write-destinations.js`) and run via tsx, same pattern as A1. Otherwise skip — next jarvis spawn projects fresh.

### Task A4: Bybit credentials placeholder (VDS)

**Files:** `groups/scrooge/scripts/.env` (VDS only, gitignored).

- [ ] **Step 1: Create the `.env` on VDS with placeholder values**

Run:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw tee /home/nanoclaw/nanoclaw/groups/scrooge/scripts/.env > /dev/null' <<'EOF'
# Bybit read-only API key (NO withdrawal permission). Replace placeholders.
BYBIT_API_KEY=REPLACE_ME
BYBIT_API_SECRET=REPLACE_ME
EOF
```

- [ ] **Step 2: Flag for the user**

Tell Sergei: create a **read-only** API key at Bybit (no withdraw/trade scope), then replace the two placeholder values in `groups/scrooge/scripts/.env` on the VDS. Until then `sync-bybit` returns "no creds" (handled in Task B5). Do **not** collect the key in chat.

---

## Part B — Finance core (local files, `bun test`)

### Task B0: Lock the FX source (spike)

**Files:** none — investigation. Output: a confirmed `fetchRateFromApi` shape used in Task B2.

- [ ] **Step 1: Probe candidate endpoints for KZT→USD historical**

Run (try each; first that returns a clean rate without an API key wins):
```bash
curl -s 'https://api.frankfurter.app/2026-06-01?from=USD&to=KZT' ; echo
curl -s 'https://open.er-api.com/v6/latest/USD' | head -c 400 ; echo
curl -s 'https://api.exchangerate.host/convert?from=KZT&to=USD&date=2026-06-01' | head -c 400 ; echo
```
Expected: identify a source covering **KZT, RUB, GEL, USD** with a historical (by-date) endpoint and no required key. Record: base direction (is the rate `1 CUR = x USD` or `1 USD = x CUR`?), the JSON path to the number, and whether a key is needed.

- [ ] **Step 2: Record the decision inline in `fx.js` (done in B2)**

Note the chosen URL template + JSON path as a comment at the top of `fetchRateFromApi`. If only a keyed source covers all four currencies, add `FX_API_KEY` to `groups/scrooge/scripts/.env` (Task A4) and read it via `_env.js`.

### Task B1: Ledger — schema, id-hash, upsert/dedup

**Files:**
- Create: `groups/scrooge/scripts/ledger.js`
- Test: `groups/scrooge/scripts/ledger.test.js`

- [ ] **Step 1: Write the failing test**

`groups/scrooge/scripts/ledger.test.js`:
```js
// Run: bun test groups/scrooge/scripts/ledger.test.js
import { describe, it, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { initSchema, txId, upsertTransaction } from "./ledger.js";

function freshDb() {
  const db = new Database(":memory:");
  initSchema(db);
  return db;
}
const sample = {
  ts: "2026-06-01T10:00:00Z", source: "manual", account: "cash",
  direction: "out", amount: 3000, currency: "KZT", raw_desc: "еда",
};

describe("ledger", () => {
  it("txId is deterministic for the same logical tx", () => {
    expect(txId(sample)).toBe(txId({ ...sample }));
  });
  it("upsert inserts a row", () => {
    const db = freshDb();
    upsertTransaction(db, sample);
    const rows = db.query("SELECT * FROM transactions").all();
    expect(rows.length).toBe(1);
    expect(rows[0].currency).toBe("KZT");
  });
  it("re-upserting the same logical tx does not duplicate", () => {
    const db = freshDb();
    upsertTransaction(db, sample);
    upsertTransaction(db, { ...sample });
    expect(db.query("SELECT COUNT(*) c FROM transactions").get().c).toBe(1);
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bun test groups/scrooge/scripts/ledger.test.js`
Expected: FAIL — `Cannot find module "./ledger.js"`.

- [ ] **Step 3: Implement `ledger.js`**

```js
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";

export function openLedger(path) {
  const db = new Database(path);
  db.exec("PRAGMA journal_mode = WAL;"); // container-only file → no cross-mount concern
  initSchema(db);
  return db;
}

export function initSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS transactions (
      id TEXT PRIMARY KEY, ts TEXT NOT NULL, source TEXT NOT NULL, account TEXT,
      direction TEXT NOT NULL, amount REAL NOT NULL, currency TEXT NOT NULL,
      amount_usd REAL, fx_rate REAL, fx_date TEXT, category TEXT, merchant TEXT,
      raw_desc TEXT, is_recurring INTEGER DEFAULT 0, recurring_group TEXT,
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS fx_rates (currency TEXT, date TEXT, rate REAL, PRIMARY KEY(currency, date));
    CREATE TABLE IF NOT EXISTS subscriptions (group_id TEXT PRIMARY KEY, merchant TEXT, amount_usd REAL, period TEXT, last_seen TEXT, status TEXT);
    CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT);
    CREATE INDEX IF NOT EXISTS idx_tx_ts ON transactions(ts);
    CREATE INDEX IF NOT EXISTS idx_tx_cat ON transactions(category);
    CREATE INDEX IF NOT EXISTS idx_tx_merchant ON transactions(merchant);
  `);
}

export function txId(tx) {
  return createHash("sha256")
    .update([tx.source, tx.account ?? "", tx.ts, tx.amount, tx.raw_desc ?? ""].join("|"))
    .digest("hex").slice(0, 16);
}

export function upsertTransaction(db, tx) {
  const id = tx.id ?? txId(tx);
  db.query(`
    INSERT OR IGNORE INTO transactions
      (id, ts, source, account, direction, amount, currency, amount_usd, fx_rate, fx_date,
       category, merchant, raw_desc, is_recurring, recurring_group, created_at)
    VALUES ($id,$ts,$source,$account,$direction,$amount,$currency,$amount_usd,$fx_rate,$fx_date,
       $category,$merchant,$raw_desc,$is_recurring,$recurring_group,$created_at)
  `).run({
    $id: id, $ts: tx.ts, $source: tx.source, $account: tx.account ?? null,
    $direction: tx.direction, $amount: tx.amount, $currency: tx.currency,
    $amount_usd: tx.amount_usd ?? null, $fx_rate: tx.fx_rate ?? null, $fx_date: tx.fx_date ?? null,
    $category: tx.category ?? null, $merchant: tx.merchant ?? null, $raw_desc: tx.raw_desc ?? null,
    $is_recurring: tx.is_recurring ?? 0, $recurring_group: tx.recurring_group ?? null,
    $created_at: tx.created_at ?? new Date().toISOString(),
  });
  return id;
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `bun test groups/scrooge/scripts/ledger.test.js`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add groups/scrooge/scripts/ledger.js groups/scrooge/scripts/ledger.test.js
git commit -m "feat(scrooge): ledger schema + dedup upsert"
```

### Task B2: FX — `toUsd` + cached `getRate`

**Files:**
- Create: `groups/scrooge/scripts/fx.js`
- Test: `groups/scrooge/scripts/fx.test.js`

- [ ] **Step 1: Write the failing test**

`groups/scrooge/scripts/fx.test.js`:
```js
// Run: bun test groups/scrooge/scripts/fx.test.js
import { describe, it, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { initSchema } from "./ledger.js";
import { toUsd, getRate } from "./fx.js";

function freshDb() { const db = new Database(":memory:"); initSchema(db); return db; }

describe("fx", () => {
  it("toUsd multiplies and rounds to cents", () => {
    expect(toUsd(3000, 0.00208)).toBeCloseTo(6.24, 2);
  });
  it("USD and USDT short-circuit to rate 1 without fetching", async () => {
    const db = freshDb();
    let called = 0;
    const r = await getRate(db, "USD", "2026-06-01", async () => { called++; return 99; });
    expect(r).toBe(1);
    expect(called).toBe(0);
  });
  it("cache miss calls fetch then caches; second call hits cache", async () => {
    const db = freshDb();
    let called = 0;
    const fetchImpl = async () => { called++; return 0.00208; };
    const a = await getRate(db, "KZT", "2026-06-01", fetchImpl);
    const b = await getRate(db, "KZT", "2026-06-01", fetchImpl);
    expect(a).toBe(0.00208);
    expect(b).toBe(0.00208);
    expect(called).toBe(1);
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bun test groups/scrooge/scripts/fx.test.js`
Expected: FAIL — `Cannot find module "./fx.js"`.

- [ ] **Step 3: Implement `fx.js`**

```js
import "./_env.js"; // loads scripts/.env (FX_API_KEY if needed) regardless of cwd

// rate semantics: 1 unit of `currency` == `rate` USD.
export function toUsd(amount, rate) {
  return Math.round(amount * rate * 100) / 100;
}

export async function getRate(db, currency, date, fetchImpl = fetchRateFromApi) {
  if (currency === "USD" || currency === "USDT") return 1;
  const cached = db.query("SELECT rate FROM fx_rates WHERE currency=$c AND date=$d")
    .get({ $c: currency, $d: date });
  if (cached) return cached.rate;
  const rate = await fetchImpl(currency, date);
  db.query("INSERT OR REPLACE INTO fx_rates (currency, date, rate) VALUES ($c,$d,$r)")
    .run({ $c: currency, $d: date, $r: rate });
  return rate;
}

// SPIKE (Task B0): set URL + JSON path to the locked source. Below assumes a
// source returning `1 USD = N CUR` for a given date, so we invert to USD-per-unit.
async function fetchRateFromApi(currency, date) {
  const url = `https://api.frankfurter.app/${date}?from=USD&to=${currency}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`fx fetch ${res.status} for ${currency} ${date}`);
  const json = await res.json();
  const perUsd = json?.rates?.[currency];
  if (!perUsd) throw new Error(`fx: no rate for ${currency} in ${JSON.stringify(json).slice(0, 200)}`);
  return 1 / perUsd; // USD per 1 unit of currency
}
```
> If B0 picked a keyed/different source, replace `fetchRateFromApi`'s body to match the recorded URL + JSON path; the exported `toUsd`/`getRate` contract stays identical so tests pass unchanged.

- [ ] **Step 4: Run it, verify it passes**

Run: `bun test groups/scrooge/scripts/fx.test.js`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add groups/scrooge/scripts/fx.js groups/scrooge/scripts/fx.test.js
git commit -m "feat(scrooge): FX conversion + cached rate lookup"
```

### Task B3: Normalize — fill `amount_usd` on a raw tx

**Files:**
- Create: `groups/scrooge/scripts/normalize.js`
- Test: `groups/scrooge/scripts/normalize.test.js`

- [ ] **Step 1: Write the failing test**

`groups/scrooge/scripts/normalize.test.js`:
```js
// Run: bun test groups/scrooge/scripts/normalize.test.js
import { describe, it, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { initSchema } from "./ledger.js";
import { normalize } from "./normalize.js";

describe("normalize", () => {
  it("fills amount_usd, fx_rate, fx_date from the tx date", async () => {
    const db = new Database(":memory:"); initSchema(db);
    const tx = { ts: "2026-06-01T10:00:00Z", source: "manual", direction: "out", amount: 3000, currency: "KZT", raw_desc: "еда" };
    const out = await normalize(db, tx, async () => 0.00208); // injected getRate
    expect(out.fx_date).toBe("2026-06-01");
    expect(out.fx_rate).toBe(0.00208);
    expect(out.amount_usd).toBeCloseTo(6.24, 2);
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bun test groups/scrooge/scripts/normalize.test.js`
Expected: FAIL — `Cannot find module "./normalize.js"`.

- [ ] **Step 3: Implement `normalize.js`**

```js
import { toUsd, getRate } from "./fx.js";

// getRateImpl signature: (db, currency, date) => Promise<number>
export async function normalize(db, tx, getRateImpl = (d, c, dt) => getRate(d, c, dt)) {
  const date = tx.ts.slice(0, 10);
  const rate = await getRateImpl(db, tx.currency, date);
  return { ...tx, amount_usd: toUsd(tx.amount, rate), fx_rate: rate, fx_date: date };
}
```
> Test injects a 1-arg-ignoring fn `async () => 0.00208`; production passes the real 3-arg `getRate`. Both satisfy the call `getRateImpl(db, currency, date)`.

- [ ] **Step 4: Run it, verify it passes**

Run: `bun test groups/scrooge/scripts/normalize.test.js`
Expected: PASS — 1 test.

- [ ] **Step 5: Commit**

```bash
git add groups/scrooge/scripts/normalize.js groups/scrooge/scripts/normalize.test.js
git commit -m "feat(scrooge): normalize tx to USD"
```

### Task B4: Manual entry CLI — `add-transaction.js`

**Files:**
- Create: `groups/scrooge/scripts/add-transaction.js`
- Test: `groups/scrooge/scripts/add-transaction.test.js`

The agent parses NL ("потратил 3000 тенге на еду") itself, then calls this CLI with structured flags. The CLI normalizes + upserts + prints the stored row as JSON.

- [ ] **Step 1: Write the failing test**

`groups/scrooge/scripts/add-transaction.test.js`:
```js
// Run: bun test groups/scrooge/scripts/add-transaction.test.js
import { describe, it, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { initSchema } from "./ledger.js";
import { addTransaction } from "./add-transaction.js";

describe("addTransaction", () => {
  it("normalizes + stores a manual tx, returns id + amount_usd", async () => {
    const db = new Database(":memory:"); initSchema(db);
    const res = await addTransaction(db, {
      amount: 3000, currency: "KZT", direction: "out", category: "food",
      ts: "2026-06-01T10:00:00Z", desc: "еда", source: "manual",
    }, async () => 0.00208);
    expect(res.amount_usd).toBeCloseTo(6.24, 2);
    expect(db.query("SELECT COUNT(*) c FROM transactions").get().c).toBe(1);
    expect(res.id).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bun test groups/scrooge/scripts/add-transaction.test.js`
Expected: FAIL — `Cannot find module "./add-transaction.js"`.

- [ ] **Step 3: Implement `add-transaction.js`**

```js
import { openLedger, upsertTransaction } from "./ledger.js";
import { normalize } from "./normalize.js";

const LEDGER = "/workspace/agent/finance/ledger.db";

export async function addTransaction(db, input, getRateImpl) {
  const raw = {
    ts: input.ts, source: input.source ?? "manual", account: input.account ?? null,
    direction: input.direction, amount: Number(input.amount), currency: input.currency,
    category: input.category ?? null, merchant: input.merchant ?? null, raw_desc: input.desc ?? null,
  };
  const norm = await normalize(db, raw, getRateImpl);
  const id = upsertTransaction(db, norm);
  return { id, amount_usd: norm.amount_usd, currency: norm.currency, amount: norm.amount };
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) out[argv[i].replace(/^--/, "")] = argv[i + 1];
  return out;
}

if (import.meta.main) {
  const a = parseArgs(Bun.argv.slice(2));
  const db = openLedger(LEDGER);
  const res = await addTransaction(db, a);
  console.log(JSON.stringify(res));
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `bun test groups/scrooge/scripts/add-transaction.test.js`
Expected: PASS — 1 test.

- [ ] **Step 5: Commit**

```bash
git add groups/scrooge/scripts/add-transaction.js groups/scrooge/scripts/add-transaction.test.js
git commit -m "feat(scrooge): manual-entry CLI"
```

### Task B5: Bybit connector — `sync-bybit.js`

**Files:**
- Create: `groups/scrooge/scripts/sync-bybit.js`
- Test: `groups/scrooge/scripts/sync-bybit.test.js`

Test covers the two pure pieces: HMAC signature (deterministic) and Bybit-row → normalized-tx mapping. The live fetch is isolated and not unit-tested.

- [ ] **Step 1: Write the failing test**

`groups/scrooge/scripts/sync-bybit.test.js`:
```js
// Run: bun test groups/scrooge/scripts/sync-bybit.test.js
import { describe, it, expect } from "bun:test";
import { signV5, mapBybitTxn } from "./sync-bybit.js";

describe("sync-bybit", () => {
  it("signV5 is a deterministic 64-char hex HMAC", () => {
    const sig = signV5("secret", "1717238400000", "key", "5000", "accountType=UNIFIED");
    expect(sig).toMatch(/^[0-9a-f]{64}$/);
    expect(sig).toBe(signV5("secret", "1717238400000", "key", "5000", "accountType=UNIFIED"));
  });
  it("mapBybitTxn maps a transaction-log row to a normalized tx in USD", () => {
    const row = { transactionTime: "1717238400000", type: "TRADE", currency: "USDT", change: "-12.5", cashFlow: "-12.5" };
    const tx = mapBybitTxn(row, "unified");
    expect(tx.source).toBe("bybit");
    expect(tx.currency).toBe("USDT");
    expect(tx.direction).toBe("out");
    expect(tx.amount).toBe(12.5);
    expect(tx.amount_usd).toBeCloseTo(12.5, 2); // USDT ≈ USD
    expect(tx.ts).toBe("2024-06-01T10:40:00.000Z");
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bun test groups/scrooge/scripts/sync-bybit.test.js`
Expected: FAIL — `Cannot find module "./sync-bybit.js"`.

- [ ] **Step 3: Implement `sync-bybit.js`**

```js
import "./_env.js";
import { createHmac } from "node:crypto";
import { openLedger, upsertTransaction } from "./ledger.js";

const LEDGER = "/workspace/agent/finance/ledger.db";
const BASE = "https://api.bybit.com";

// Bybit v5 signature: HMAC_SHA256(timestamp + apiKey + recvWindow + queryString)
export function signV5(secret, timestamp, apiKey, recvWindow, queryString) {
  return createHmac("sha256", secret)
    .update(timestamp + apiKey + recvWindow + queryString)
    .digest("hex");
}

// Map one /v5/account/transaction-log row → normalized tx (USDT/USDC ≈ USD).
export function mapBybitTxn(row, account = "unified") {
  const amount = Math.abs(Number(row.change ?? row.cashFlow ?? 0));
  const direction = Number(row.change ?? row.cashFlow ?? 0) < 0 ? "out" : "in";
  const currency = row.currency;
  const isUsdLike = currency === "USDT" || currency === "USDC" || currency === "USD";
  return {
    ts: new Date(Number(row.transactionTime)).toISOString(),
    source: "bybit", account, direction, amount, currency,
    amount_usd: isUsdLike ? amount : null, // non-USD coins normalized later via fx/price
    fx_rate: isUsdLike ? 1 : null, fx_date: isUsdLike ? new Date(Number(row.transactionTime)).toISOString().slice(0, 10) : null,
    category: (row.type || "trade").toLowerCase(), merchant: "Bybit", raw_desc: JSON.stringify(row).slice(0, 300),
  };
}

// SPIKE: confirm endpoint + params for full personal history.
async function fetchTransactionLog(apiKey, apiSecret) {
  const ts = String(Date.now());
  const recvWindow = "5000";
  const qs = "accountType=UNIFIED&limit=50";
  const sig = signV5(apiSecret, ts, apiKey, recvWindow, qs);
  const res = await fetch(`${BASE}/v5/account/transaction-log?${qs}`, {
    headers: {
      "X-BAPI-API-KEY": apiKey, "X-BAPI-TIMESTAMP": ts,
      "X-BAPI-RECV-WINDOW": recvWindow, "X-BAPI-SIGN": sig,
    },
  });
  const json = await res.json();
  if (json.retCode !== 0) throw new Error(`bybit ${json.retCode}: ${json.retMsg}`);
  return json.result?.list ?? [];
}

if (import.meta.main) {
  const key = process.env.BYBIT_API_KEY, secret = process.env.BYBIT_API_SECRET;
  if (!key || !secret || key === "REPLACE_ME") { console.log(JSON.stringify({ error: "no creds" })); process.exit(0); }
  const db = openLedger(LEDGER);
  let n = 0;
  for (const row of await fetchTransactionLog(key, secret)) { upsertTransaction(db, mapBybitTxn(row)); n++; }
  db.query("INSERT OR REPLACE INTO state (key, value) VALUES ('bybit_last_sync', $v)").run({ $v: new Date().toISOString() });
  console.log(JSON.stringify({ synced: n }));
}
```
> Bybit spike: before relying on this in production, run a single signed `curl` (or this script) against the live API to confirm `transaction-log` is the right endpoint for the user's account and that the row fields (`change`, `transactionTime`, `currency`, `type`) match. Adjust `mapBybitTxn` field names if the live shape differs — the test's `row` literal documents the assumed shape.

- [ ] **Step 4: Run it, verify it passes**

Run: `bun test groups/scrooge/scripts/sync-bybit.test.js`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add groups/scrooge/scripts/sync-bybit.js groups/scrooge/scripts/sync-bybit.test.js
git commit -m "feat(scrooge): Bybit v5 sync (sign + map)"
```

### Task B6: Subscription detection — `detect-subscriptions.js`

**Files:**
- Create: `groups/scrooge/scripts/detect-subscriptions.js`
- Test: `groups/scrooge/scripts/detect-subscriptions.test.js`

- [ ] **Step 1: Write the failing test**

`groups/scrooge/scripts/detect-subscriptions.test.js`:
```js
// Run: bun test groups/scrooge/scripts/detect-subscriptions.test.js
import { describe, it, expect } from "bun:test";
import { detectSubscriptions } from "./detect-subscriptions.js";

function monthly(merchant, amount, months) {
  return months.map((m) => ({
    ts: `2026-${String(m).padStart(2, "0")}-05T00:00:00Z`,
    merchant, amount_usd: amount, direction: "out",
  }));
}

describe("detectSubscriptions", () => {
  it("flags a 3+ month recurring charge of ~equal amount", () => {
    const txns = [...monthly("Netflix", 12, [1, 2, 3, 4]), { ts: "2026-02-10T00:00:00Z", merchant: "Cafe", amount_usd: 5, direction: "out" }];
    const subs = detectSubscriptions(txns);
    const netflix = subs.find((s) => s.merchant === "Netflix");
    expect(netflix).toBeTruthy();
    expect(netflix.period).toBe("monthly");
    expect(netflix.occurrences).toBe(4);
  });
  it("does not flag a one-off purchase", () => {
    const subs = detectSubscriptions([{ ts: "2026-03-01T00:00:00Z", merchant: "Cafe", amount_usd: 5, direction: "out" }]);
    expect(subs.length).toBe(0);
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bun test groups/scrooge/scripts/detect-subscriptions.test.js`
Expected: FAIL — `Cannot find module "./detect-subscriptions.js"`.

- [ ] **Step 3: Implement `detect-subscriptions.js`**

```js
import { openLedger } from "./ledger.js";
const LEDGER = "/workspace/agent/finance/ledger.db";

const DAY = 86400000;
function daysBetween(a, b) { return Math.abs(new Date(a) - new Date(b)) / DAY; }
function median(xs) { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; }

// Group outflows by merchant + similar amount; flag series with >= minOccurrences
// at a regular cadence (weekly ~7d / monthly ~30d / yearly ~365d).
export function detectSubscriptions(txns, { minOccurrences = 3, tolAmountPct = 0.15 } = {}) {
  const out = txns.filter((t) => t.direction === "out" && t.merchant && t.amount_usd != null);
  const byMerchant = {};
  for (const t of out) (byMerchant[t.merchant] ??= []).push(t);

  const subs = [];
  for (const [merchant, rows] of Object.entries(byMerchant)) {
    rows.sort((a, b) => new Date(a.ts) - new Date(b.ts));
    const med = median(rows.map((r) => r.amount_usd));
    const similar = rows.filter((r) => Math.abs(r.amount_usd - med) <= med * tolAmountPct);
    if (similar.length < minOccurrences) continue;
    const gaps = [];
    for (let i = 1; i < similar.length; i++) gaps.push(daysBetween(similar[i].ts, similar[i - 1].ts));
    const g = median(gaps);
    let period = null;
    if (g >= 5 && g <= 9) period = "weekly";
    else if (g >= 25 && g <= 35) period = "monthly";
    else if (g >= 350 && g <= 380) period = "yearly";
    if (!period) continue;
    subs.push({
      merchant, period, amount_usd: Math.round(med * 100) / 100,
      occurrences: similar.length, last_seen: similar[similar.length - 1].ts,
    });
  }
  return subs;
}

if (import.meta.main) {
  const db = openLedger(LEDGER);
  const txns = db.query("SELECT ts, merchant, amount_usd, direction FROM transactions").all();
  console.log(JSON.stringify({ subscriptions: detectSubscriptions(txns) }, null, 2));
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `bun test groups/scrooge/scripts/detect-subscriptions.test.js`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add groups/scrooge/scripts/detect-subscriptions.js groups/scrooge/scripts/detect-subscriptions.test.js
git commit -m "feat(scrooge): subscription detection"
```

### Task B7: Analyze — findings (categories, anomalies, cuttable)

**Files:**
- Create: `groups/scrooge/scripts/analyze.js`
- Test: `groups/scrooge/scripts/analyze.test.js`

- [ ] **Step 1: Write the failing test**

`groups/scrooge/scripts/analyze.test.js`:
```js
// Run: bun test groups/scrooge/scripts/analyze.test.js
import { describe, it, expect } from "bun:test";
import { spendByCategory, findCuttable } from "./analyze.js";

const txns = [
  { ts: "2026-06-01T00:00:00Z", category: "food", amount_usd: 10, direction: "out" },
  { ts: "2026-06-02T00:00:00Z", category: "food", amount_usd: 20, direction: "out" },
  { ts: "2026-06-03T00:00:00Z", category: "transport", amount_usd: 5, direction: "out" },
  { ts: "2026-06-04T00:00:00Z", category: "salary", amount_usd: 1000, direction: "in" },
];

describe("analyze", () => {
  it("spendByCategory sums outflows per category, ignoring income", () => {
    const s = spendByCategory(txns);
    expect(s.food).toBe(30);
    expect(s.transport).toBe(5);
    expect(s.salary).toBeUndefined();
  });
  it("findCuttable surfaces subscriptions not seen in the recent window", () => {
    const subs = [{ merchant: "Netflix", period: "monthly", amount_usd: 12, last_seen: "2026-01-01T00:00:00Z" }];
    const cuttable = findCuttable(subs, "2026-06-01T00:00:00Z");
    expect(cuttable.find((c) => c.merchant === "Netflix")).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bun test groups/scrooge/scripts/analyze.test.js`
Expected: FAIL — `Cannot find module "./analyze.js"`.

- [ ] **Step 3: Implement `analyze.js`**

```js
import { openLedger } from "./ledger.js";
import { detectSubscriptions } from "./detect-subscriptions.js";
const LEDGER = "/workspace/agent/finance/ledger.db";
const DAY = 86400000;

export function spendByCategory(txns) {
  const out = {};
  for (const t of txns) {
    if (t.direction !== "out" || t.amount_usd == null) continue;
    out[t.category ?? "uncategorized"] = (out[t.category ?? "uncategorized"] ?? 0) + t.amount_usd;
  }
  for (const k of Object.keys(out)) out[k] = Math.round(out[k] * 100) / 100;
  return out;
}

// A subscription is "cuttable" if its expected next charge is overdue by > one
// period AND it is still in the active set — i.e. it may be forgotten/unused.
export function findCuttable(subs, now) {
  const periodDays = { weekly: 7, monthly: 30, yearly: 365 };
  return subs.filter((s) => {
    const since = (new Date(now) - new Date(s.last_seen)) / DAY;
    return since > (periodDays[s.period] ?? 30) * 1.5;
  }).map((s) => ({ merchant: s.merchant, amount_usd: s.amount_usd, period: s.period, reason: "stale_subscription" }));
}

export function analyze(db, now) {
  const txns = db.query("SELECT ts, category, merchant, amount_usd, direction FROM transactions").all();
  const subs = detectSubscriptions(txns);
  return {
    spend_by_category: spendByCategory(txns),
    subscriptions_monthly_usd: Math.round(subs.filter((s) => s.period === "monthly").reduce((a, s) => a + s.amount_usd, 0) * 100) / 100,
    cuttable: findCuttable(subs, now),
    generated_at: now,
  };
}

if (import.meta.main) {
  const outIdx = Bun.argv.indexOf("--out");
  const outPath = outIdx >= 0 ? Bun.argv[outIdx + 1] : "/tmp/findings.json";
  const db = openLedger(LEDGER);
  const findings = analyze(db, new Date().toISOString());
  await Bun.write(outPath, JSON.stringify(findings, null, 2));
  console.log(JSON.stringify({ wrote: outPath, cuttable: findings.cuttable.length }));
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `bun test groups/scrooge/scripts/analyze.test.js`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add groups/scrooge/scripts/analyze.js groups/scrooge/scripts/analyze.test.js
git commit -m "feat(scrooge): analyze findings (spend, subs, cuttable)"
```

### Task B8: On-demand reports — `report.js`

**Files:**
- Create: `groups/scrooge/scripts/report.js`
- Test: `groups/scrooge/scripts/report.test.js`

- [ ] **Step 1: Write the failing test**

`groups/scrooge/scripts/report.test.js`:
```js
// Run: bun test groups/scrooge/scripts/report.test.js
import { describe, it, expect } from "bun:test";
import { monthlyReport } from "./report.js";

const txns = [
  { ts: "2026-06-01T00:00:00Z", category: "food", amount_usd: 10, direction: "out" },
  { ts: "2026-06-02T00:00:00Z", category: "food", amount_usd: 20, direction: "out" },
  { ts: "2026-06-03T00:00:00Z", category: "salary", amount_usd: 1000, direction: "in" },
  { ts: "2026-05-15T00:00:00Z", category: "food", amount_usd: 99, direction: "out" }, // other month
];

describe("report", () => {
  it("monthlyReport totals income/expense + top categories for the given month", () => {
    const r = monthlyReport(txns, "2026-06");
    expect(r.expense_usd).toBe(30);
    expect(r.income_usd).toBe(1000);
    expect(r.net_usd).toBe(970);
    expect(r.top_categories[0]).toEqual({ category: "food", usd: 30 });
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bun test groups/scrooge/scripts/report.test.js`
Expected: FAIL — `Cannot find module "./report.js"`.

- [ ] **Step 3: Implement `report.js`**

```js
import { openLedger } from "./ledger.js";
const LEDGER = "/workspace/agent/finance/ledger.db";

export function monthlyReport(txns, month /* "YYYY-MM" */) {
  const m = txns.filter((t) => t.ts.slice(0, 7) === month && t.amount_usd != null);
  const expense = m.filter((t) => t.direction === "out").reduce((a, t) => a + t.amount_usd, 0);
  const income = m.filter((t) => t.direction === "in").reduce((a, t) => a + t.amount_usd, 0);
  const byCat = {};
  for (const t of m) if (t.direction === "out") byCat[t.category ?? "uncategorized"] = (byCat[t.category ?? "uncategorized"] ?? 0) + t.amount_usd;
  const top = Object.entries(byCat).map(([category, usd]) => ({ category, usd: Math.round(usd * 100) / 100 }))
    .sort((a, b) => b.usd - a.usd);
  return {
    month, expense_usd: Math.round(expense * 100) / 100, income_usd: Math.round(income * 100) / 100,
    net_usd: Math.round((income - expense) * 100) / 100, top_categories: top,
  };
}

if (import.meta.main) {
  const monthIdx = Bun.argv.indexOf("--month");
  const month = monthIdx >= 0 ? Bun.argv[monthIdx + 1] : new Date().toISOString().slice(0, 7);
  const db = openLedger(LEDGER);
  const txns = db.query("SELECT ts, category, amount_usd, direction FROM transactions").all();
  console.log(JSON.stringify(monthlyReport(txns, month), null, 2));
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `bun test groups/scrooge/scripts/report.test.js`
Expected: PASS — 1 test.

- [ ] **Step 5: Commit**

```bash
git add groups/scrooge/scripts/report.js groups/scrooge/scripts/report.test.js
git commit -m "feat(scrooge): on-demand monthly report"
```

### Task B9: Chart renderer — `render-chart.cjs`

**Files:**
- Create: `groups/scrooge/scripts/render-chart.cjs`
- Test: `groups/scrooge/scripts/render-chart.test.js`

Pixel output can't be meaningfully unit-tested; the test is a smoke test that a valid JPEG is produced. Runs with node (like surf-forecast). `@napi-rs/canvas` is in the image.

- [ ] **Step 1: Write the failing smoke test**

`groups/scrooge/scripts/render-chart.test.js`:
```js
// Run: bun test groups/scrooge/scripts/render-chart.test.js
// Note: requires @napi-rs/canvas (present in the agent image; locally may be absent).
import { describe, it, expect } from "bun:test";
import { renderCategoryChart } from "./render-chart.cjs";
import { readFileSync, existsSync, rmSync } from "node:fs";

describe("render-chart", () => {
  it("writes a non-empty JPEG with the SOI marker", () => {
    const out = "/tmp/scrooge-chart-test.jpg";
    if (existsSync(out)) rmSync(out);
    renderCategoryChart({ title: "Test", data: [{ label: "food", value: 30 }, { label: "transport", value: 5 }] }, out);
    const buf = readFileSync(out);
    expect(buf.length).toBeGreaterThan(1000);
    expect(buf[0]).toBe(0xff); // JPEG SOI
    expect(buf[1]).toBe(0xd8);
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bun test groups/scrooge/scripts/render-chart.test.js`
Expected: FAIL — `Cannot find module "./render-chart.cjs"`.

- [ ] **Step 3: Implement `render-chart.cjs`**

```js
#!/usr/bin/env node
// Minimal finance chart renderer. Pattern mirrors container/skills/surf-forecast/render.cjs.
const { createCanvas } = require("@napi-rs/canvas");
const fs = require("fs");

const BG = "#0a1628", CARD = "#0f2044", GOLD = "#e0b84c", TEXT = "#e8f4ff", MUTED = "#7a9fc0";

function renderCategoryChart({ title, data }, outPath) {
  const W = 900, H = 600, PAD = 48, barH = 36, gap = 18;
  const canvas = createCanvas(W, H);
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = BG; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = TEXT; ctx.font = "bold 28px sans-serif"; ctx.fillText(title, PAD, PAD + 8);

  const max = Math.max(1, ...data.map((d) => d.value));
  const x0 = PAD + 140, barMax = W - x0 - PAD;
  data.forEach((d, i) => {
    const y = PAD + 50 + i * (barH + gap);
    ctx.fillStyle = MUTED; ctx.font = "16px sans-serif"; ctx.fillText(d.label, PAD, y + barH / 2 + 5);
    ctx.fillStyle = CARD; ctx.fillRect(x0, y, barMax, barH);
    ctx.fillStyle = GOLD; ctx.fillRect(x0, y, barMax * (d.value / max), barH);
    ctx.fillStyle = TEXT; ctx.fillText(`$${d.value}`, x0 + barMax * (d.value / max) + 8, y + barH / 2 + 5);
  });

  fs.writeFileSync(outPath, canvas.toBuffer("image/jpeg", 0.9));
  return outPath;
}

module.exports = { renderCategoryChart };

if (require.main === module) {
  const [inPath, outPath] = process.argv.slice(2);
  const spec = JSON.parse(fs.readFileSync(inPath, "utf8"));
  renderCategoryChart(spec, outPath);
  console.log(JSON.stringify({ wrote: outPath }));
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `bun test groups/scrooge/scripts/render-chart.test.js`
Expected: PASS — 1 test. (If `@napi-rs/canvas` is absent locally, run this test on the VDS/agent image instead; note the skip in the commit message.)

- [ ] **Step 5: Commit**

```bash
git add groups/scrooge/scripts/render-chart.cjs groups/scrooge/scripts/render-chart.test.js
git commit -m "feat(scrooge): canvas chart renderer"
```

---

## Part C — iOS integration

Verify the active simulator/scheme first per the XcodeBuildMCP flow (`session_show_defaults`); the project is `ios/JarvisApp` (xcodegen — never edit `.xcodeproj` by hand).

### Task C1: `AgentIdentity` — add `.scrooge`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/AgentIdentityTests.swift` (create)

- [ ] **Step 1: Write the failing test**

`ios/JarvisApp/Sources/JarvisAppTests/AgentIdentityTests.swift`:
```swift
import XCTest
@testable import JarvisApp

final class AgentIdentityTests: XCTestCase {
    func testScroogeIsAValidCase() {
        XCTAssertTrue(AgentIdentity.allCases.contains(.scrooge))
        XCTAssertEqual(AgentIdentity(rawValue: "scrooge"), .scrooge)
        XCTAssertEqual(AgentIdentity.scrooge.rawValue, "scrooge")
        XCTAssertFalse(AgentIdentity.scrooge.displayName.isEmpty)
    }
}
```

- [ ] **Step 2: Add `.scrooge` to the enum**

In `AgentIdentity.swift`:
- Add `case scrooge` after `case greg` (line ~10).
- In `init?(rawValue:)` add `case "scrooge": self = .scrooge` before `default:`.
- In `displayName` add `case .scrooge: return "Scrooge"`.
- In `accentColor` add `case .scrooge: return Color(red: 0.88, green: 0.72, blue: 0.30)  // muted gold #E0B84C`.

- [ ] **Step 3: Build the test target**

Run via XcodeBuildMCP `test_sim` (scheme `JarvisApp`, filtering `AgentIdentityTests`), or `build_sim` then run tests.
Expected: `testScroogeIsAValidCase` PASS; project compiles (the `switch`es over `AgentIdentity` remain exhaustive).

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift ios/JarvisApp/Sources/JarvisAppTests/AgentIdentityTests.swift
git commit -m "feat(ios): add Scrooge agent identity"
```

### Task C2: `GreetingBank` — add `.scrooge` phrases

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Utility/GreetingBank.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/GreetingBankTests.swift` (create)

- [ ] **Step 1: Write the failing test**

`ios/JarvisApp/Sources/JarvisAppTests/GreetingBankTests.swift`:
```swift
import XCTest
@testable import JarvisApp

final class GreetingBankTests: XCTestCase {
    func testScroogeHasGreetingsForEverySlot() {
        for slot in [TimeSlot.morning, .day, .evening, .night] {
            XCTAssertFalse(GreetingBank.pick(agent: .scrooge, slot: slot).isEmpty)
        }
    }
}
```

- [ ] **Step 2: Add the `.scrooge` branch**

In `GreetingBank.swift`, inside `phrases(agent:slot:)`, add after the `.greg` block:
```swift
        case .scrooge:
            switch slot {
            case .morning: return [
                "Доброе утро! Деньги не спят — и мы не спим",
                "Подъём! Каждая монета сама себя не сосчитает",
                "Утро. Курсы открылись. Что в закромах?",
                "Bah! Опять тратить собрался?",
            ]
            case .day: return [
                "Так, показывай, куда утекло",
                "Деньги любят счёт. Считаем?",
                "День в разгаре — траты под контролем?",
            ]
            case .evening: return [
                "Сколько спустил сегодня? Признавайся",
                "Вечерний баланс сам себя не сведёт",
                "Bah! Надеюсь, без глупых покупок",
            ]
            case .night: return [
                "Подписки тоже не спят — каждую ночь списывают",
                "Полночь. Самое время урезать расходы",
                "Считаешь овец? Лучше посчитай расходы",
            ]
            }
```

- [ ] **Step 3: Build + run the test**

Run via XcodeBuildMCP `test_sim` filtering `GreetingBankTests`.
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Utility/GreetingBank.swift ios/JarvisApp/Sources/JarvisAppTests/GreetingBankTests.swift
git commit -m "feat(ios): Scrooge home-screen greetings"
```

### Task C3: `OrbHomeView` — move greeting to the bottom

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`

- [ ] **Step 1: Extract the greeting into a computed view**

Add this property to `OrbHomeView` (near `greeting`, ~line 40):
```swift
    private var greetingLabel: some View {
        Text(greeting)
            .font(.system(size: Theme.scaled(11), weight: .light))
            .tracking(2)
            .foregroundStyle(Theme.accentMedium.opacity(0.7))
            .opacity(showSatellites ? 0.3 : 1)
            .animation(.easeOut(duration: 0.2), value: showSatellites)
            .padding(.bottom, Theme.scaled(12))
            .accessibilityIdentifier("home-greeting")
    }
```

- [ ] **Step 2: Remove the greeting from the orb cluster**

In `orbCluster`, delete the `Text(greeting)` block (currently lines ~318–323):
```swift
                Text(greeting)
                    .font(.system(size: Theme.scaled(11), weight: .light))
                    .tracking(2)
                    .foregroundStyle(Theme.accentMedium.opacity(0.7))
                    .opacity(showSatellites ? 0.3 : 1)
                    .animation(.easeOut(duration: 0.2), value: showSatellites)
```
The enclosing `VStack(spacing: Theme.scaled(8))` now wraps only the orb `ZStack` — leave the VStack as-is (harmless single child).

- [ ] **Step 3: Pin the greeting to the bottom via safeAreaInset**

On the inner `VStack(spacing: 0)` that holds `header` + content (starts ~line 85), add the modifier right after the closing brace of that VStack and before `.background { … }`:
```swift
            .safeAreaInset(edge: .bottom) { greetingLabel }
```
This places the greeting at the screen bottom, above the home indicator, clear of the satellite orbit (radius 130–150 around the centered cluster).

- [ ] **Step 4: Build + visually verify**

Run via XcodeBuildMCP `build_run_sim`, then `screenshot`.
Expected: home screen shows the orb + satellites; greeting text sits at the very bottom, not overlapped by the lowest satellite. Long-press the orb → satellites expand, greeting dims to 0.3 opacity.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift
git commit -m "feat(ios): move home greeting to bottom, clear of orbs"
```

---

## Part D — Persona, CLAUDE.md, deploy, end-to-end

### Task D1: Write `groups/scrooge/CLAUDE.md`

**Files:**
- Modify: `groups/scrooge/CLAUDE.md` (replace the stub)

- [ ] **Step 1: Write the full persona + operating doc**

Replace `groups/scrooge/CLAUDE.md` with (adapt section anchors to match Greg/Payne fragment conventions if those `@./` includes exist for this install):

```markdown
# Scrooge — Финансовый агент

Ты — Скрудж, узкий финансовый агент Сергея. Считаешь деньги скриптами, трактуешь только то, что они флагнули. Базовая валюта — **USD**.

## Личность — гибрид
- База: **Дядюшка Скрудж (McDuck)** — азартный шотландец, обожает растущую гору монет, экономия = охота за сокровищами, радуешься каждому сэкономленному доллару.
- Прикус: **Эбенизер (Dickens)** на утечках — «Bah! Humbug!», презрение к бессмысленным тратам, режешь беспощадно.
- Яд — в трату, не в личность. Числа первыми, всегда USD + оригинал. Простой русский (аббревиатуры разворачивай; JSON-ключи короткие).

## Guardrails (жёстко)
- **Не двигаешь деньги, не торгуешь, не выводишь средства, не инициируешь переводы.** Только читаешь/анализируешь/советуешь.
- Не гарантируешь инвестдоход — флагуешь/предлагаешь, решает человек.
- Деструктив в реестре — один confirm.

## Token economy (КРИТИЧНО)
**Никогда** не читай `finance/ledger.db` или сырые выписки в контекст (`cat`/Read запрещены). Только скрипты их трогают → отдают маленький JSON. Нарушение раздувает контекст в разы.

## Данные
`/workspace/agent/finance/ledger.db` — нормализованный реестр (USD). Пишут/читают только скрипты. Креды Bybit — в `/workspace/agent/scripts/.env` (НЕ в каком-либо вольте; нативный прокси — только Anthropic).

## Рабочие команды (вызывай по абсолютному пути, читай только их JSON-выхлоп)
- Ручная трата: `bun /workspace/agent/scripts/add-transaction.js --amount <n> --currency <CUR> --direction out --category <cat> --ts <ISO> --desc "<text>" --source manual`
- Синк Bybit: `bun /workspace/agent/scripts/sync-bybit.js`
- Подписки: `bun /workspace/agent/scripts/detect-subscriptions.js`
- Анализ: `bun /workspace/agent/scripts/analyze.js --out /tmp/findings.json` → читай `/tmp/findings.json`
- Отчёт: `bun /workspace/agent/scripts/report.js --month YYYY-MM`
- График: `bun /workspace/agent/scripts/render-chart.cjs <spec.json> /tmp/chart.jpg` → приложи jpg

## Ручной ввод
Сообщение «потратил 3000 тенге на еду» → распарси сам (сумма, валюта, категория, направление), вызови `add-transaction.js`, подтверди коротко в характере: сумму в оригинале + USD.

## Рабочий цикл скана (по расписанию + на новых данных)
1. `sync-bybit.js` (если есть свежие данные).
2. `analyze.js --out /tmp/findings.json`, прочти **только** findings.
3. Прочти `memories/state.md` — что уже доложено (dedup) + suppress.
4. Для каждого нового cuttable/аномалии не под suppress → один проактивный пинг в характере. Обнови `state.md`.
5. Если нового нет — **молчи** (token economy). Перепиши `INDEX.md` целиком.
6. Заверши `/clear` (stateless; память — в `state.md`/`INDEX.md`).

## Проактивные пинги
Канал: свой (Сергею) + опц. a2a Jarvis (`send_message(to="jarvis", "<кратко>")`). Anti-spam: suppress в `state.md`, уважай 👎. Голос: «Bah! Подписка X — $12/мес, не трогал 3 месяца. $144/год в трубу. Режь.»

## Расписание
На первом прогоне заведи recurring `schedule_task` — раз в день/неделю (guardrail по стоимости). Не чаще.

## Failure modes
- `sync-bybit` → `{"error":"no creds"}`: `.env` без ключа. Скажи Сергею: нужен read-only Bybit API key в `scripts/.env`. Не предлагай «вольт» — его нет.
- Bybit 401: ключ неверный/просрочен/нет прав на чтение. Конкретику Сергею.
- FX-fetch упал: последний кэш + флаг staleness в ответе.
- Скрипт упал: стдерр в логи, Сергею — суть + предложение.

## INDEX.md
Рядом — выжимка для прогрева. При старте прочитай. После каждого скана перепиши целиком.
```

- [ ] **Step 2: Commit**

```bash
git add groups/scrooge/CLAUDE.md
git commit -m "feat(scrooge): persona + operating CLAUDE.md"
```

### Task D2: Deploy to VDS + smoke the scripts in-container

- [ ] **Step 1: Push + pull + build on VDS**

Run:
```bash
git push
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build"'
```
Expected: clean pull + build. (No host TS changed, but build is the standard deploy step.)

- [ ] **Step 2: Run the Bun test suite where Bun lives**

Run (locally if Bun present, else on VDS):
```bash
bun test groups/scrooge/scripts/
```
Expected: all script tests PASS (render-chart may be skipped locally if `@napi-rs/canvas` is absent — must pass on the image).

### Task D3: Wake Scrooge + end-to-end smoke (iOS)

- [ ] **Step 1: Open the iOS app, pick Scrooge in the agent picker**

Expected: picker shows **Scrooge** (gold accent); home greeting (Scrooge voice) sits at the bottom of the screen.

- [ ] **Step 2: Record a manual expense**

Send: `потратил 3000 тенге на еду`.
Expected: Scrooge confirms in-character with the amount in KZT **and** USD (≈$6 at current rate). This exercises NL-parse → `add-transaction.js` → normalize → ledger.

- [ ] **Step 3: Ask for a report**

Send: `отчёт за этот месяц`.
Expected: Scrooge runs `report.js`, replies with expense/income/net + top categories; optionally a chart image attachment.

- [ ] **Step 4: Verify the ledger + first schedule exist (VDS)**

Run:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && pnpm exec tsx scripts/q.ts data/v2-sessions/scrooge/*/outbound.db \"SELECT COUNT(*) FROM messages_out\"; ls -la groups/scrooge/finance/"'
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && ./bin/ncl sessions list | grep scrooge"'
```
Expected: `finance/ledger.db` exists with the manual tx; a Scrooge session is active. Confirm the agent created a recurring scan task (ask Scrooge, or check the scheduling table).

- [ ] **Step 5: (Optional) Provide a real Bybit read-only key**

Once Sergei sets `BYBIT_API_KEY`/`BYBIT_API_SECRET` in `groups/scrooge/scripts/.env` on the VDS, send Scrooge `синкани bybit` and confirm balances/transactions land in the ledger. If `no creds` / 401 — see CLAUDE.md failure modes.

---

## Out of Phase 1 (see spec §16/§18)

- **Phase 2:** statement parsers per bank (Kaspi → Tinkoff → BoG → Home Credit) against real samples; confirm inbound-attachment byte-persistence + `localPath`.
- **Later:** Telegram Wallet; goals/budgets/scheduled-reports; aggregators; custom iOS finance UI.
- **Separate cleanup (verify first):** drop the `"health-analyzer"` alias in `AgentIdentity.init?(rawValue:)` only after confirming VDS `agent_groups.folder='greg'`.

---

## Self-Review

- **Spec coverage:** identity/wiring (A1–A3, spec §2) · ledger SQLite (B1, §4) · manual NL (B4, §5.1) · Bybit (B5, §5.3) · USD/FX (B0–B3, §6) · subscriptions (B6, §7) · analyze Greg-pattern (B7, §8) · proactive pings (D1 workflow + state.md, §9) · on-demand reports (B8, §10) · charts (B9, §11) · persona (D1, §12) · guardrails (D1, §13) · errors (D1 failure modes, §14) · tests (every B/C task, §15) · iOS integration (C1–C3, §16) · phasing respected (statements deferred). No uncovered Phase-1 requirement.
- **Placeholders:** none — every code step has complete, runnable code; FX/Bybit live calls are isolated behind documented spike points with concrete fallbacks, not TODOs.
- **Type consistency:** `txId`/`upsertTransaction`/`initSchema`/`openLedger` (ledger.js) used identically across B3–B8; `getRate(db,currency,date)`/`toUsd(amount,rate)` consistent B2→B3; `detectSubscriptions(txns,opts)` shape consistent B6→B7; `AgentIdentity.scrooge` / `GreetingBank.pick(agent:slot:)` consistent C1→C2→C3.
```
