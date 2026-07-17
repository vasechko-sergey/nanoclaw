# Typed Agent Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Довести «декларация == enforcement» с уровня имени контракта до его содержимого — в обоих каналах (push a2a и pull-фрагменты) — и закрыть измеренные дыры: 11 фантомных kind'ов, меш 10/20, остров-Гордон, нетипизированное тело фрагмента, стухшую доктрину.

**Architecture:** `agents/<folder>/agent.json` остаётся единственным артефактом. `a2a_in.<kind>` из строки становится `KindContract {desc, from[], fields{}, reply?}`; добавляется `publishes {desc, fields{}, optional[]}` для тела публичного фрагмента. Реестр рендерит оба. Гейт **не трогается**: `getLegalKinds` = `Object.keys(a2a_in)`. Проверку дают три разные точки — линт на билде (`ncl groups lint`), warn на проекции фрагмента (`public-profiles.ts`), и существующий рантайм-гейт a2a.

**Tech Stack:** Node + TypeScript (хост), vitest, better-sqlite3, `ncl` CLI поверх Unix-сокета.

**Спека:** [`docs/superpowers/specs/2026-07-17-typed-agent-contracts-design.md`](../specs/2026-07-17-typed-agent-contracts-design.md) (main `d3f44854` + `e73c7fe3`)

---

## Инварианты — нарушить = провалить задачу

1. **`getLegalKinds` возвращает `string[] | null` и не меняет сигнатуру.** Её потребители — `write-destinations.ts:55` и `agent-route.ts:259` — не трогаются вообще. Меняется тип **значения** `a2a_in`, а `Object.keys()` про значения не знает.
2. **Деградация по полям, не по файлу.** Плохой `publishes` НЕ должен разоружать a2a-гейт. См. Task 1.
3. **`groups/` gitignored.** Дескрипторы/скилы/INSTRUCTIONS едут на VDS **только scp**, никогда git.
4. **Репа не знает про моих пятерых.** Тесты — на фикстурах в tmp-директориях. Утверждения про живых агентов делает только `ncl groups lint` на установке.
5. **Параллельные сессии на main.** Коммиты append-only: без rebase/amend/force, `git fetch` перед push, никогда `git add -A`.

## File Structure

| Файл | Ответственность |
|---|---|
| `src/agent-registry.ts` (modify) | `KindContract`, `PublishContract`, деградация по полям, рендер полей + фрагмента |
| `src/agent-registry.test.ts` (modify) | Форма контрактов, деградация по полям, рендер |
| `src/modules/agent-to-agent/a2a-lint.ts` (create) | Чистая функция линта. Без IO. |
| `src/modules/agent-to-agent/a2a-lint.test.ts` (create) | Фикстуры на каждый код находки |
| `src/modules/agent-to-agent/lint-scan.ts` (create) | IO: скан `groups/` на `<message to= kind=>` и `profiles/<X>.md`; сбор дескрипторов и рёбер |
| `src/cli/resources/groups.ts` (modify) | Verb `lint` |
| `src/public-profiles.ts` (modify) | Warn на проекции при пропаже объявленного не-optional поля |
| `src/public-profiles.test.ts` (modify) | Новая сигнатура + случаи warn |
| `src/host-sweep.ts` (modify) | Прокинуть `AGENTS_DIR` в проекцию |
| `CLAUDE.md`, `docs/db-central.md` (modify) | Починка стухшей доктрины |
| `groups/*/agent.json` × 5 (scp) | Типизированные контракты |
| `groups/INSTRUCTIONS.md` (scp) | Доктрина pull-first |
| `groups/{payne,jarvis,gordon}/skills/**` (scp) | 3 воскрешённых отправителя + чтение объявленной подписи |

---

### Task 1: Типы контрактов + деградация по полям

**Files:**
- Modify: `src/agent-registry.ts:30-95`
- Test: `src/agent-registry.test.ts`

**Контекст.** Сегодня `readAgentDescriptor` при любой негодной части возвращает `null` — весь дескриптор. Это было верно, пока заботы были одной семьи (role + a2a_in, обе для реестра). `publishes` — независимая забота, и опечатка в подписи строки тела **разоружила бы транспортный гейт** через `getLegalKinds`. Недопустимо. Меняем на спасение по полям: файл отсутствует/не парсится → `null` (как было); распарсился → негодные поля выбрасываются по одному, остальное живёт.

- [ ] **Step 1: Написать падающие тесты**

В `src/agent-registry.test.ts` добавить:

```ts
describe('readAgentDescriptor field-level degradation', () => {
  it('drops a malformed publishes but keeps a2a_in armed', () => {
    const dir = mkTmp();
    fs.mkdirSync(path.join(dir, 'greg'), { recursive: true });
    fs.writeFileSync(
      path.join(dir, 'greg', 'agent.json'),
      JSON.stringify({
        role: 'Аналитик',
        a2a_in: { finding: { desc: 'd', from: ['jarvis'], fields: { severity: 'string' } } },
        publishes: 'не объект',
      }),
    );
    const d = readAgentDescriptor(dir, 'greg');
    expect(d?.publishes).toBeUndefined();
    expect(Object.keys(d!.a2a_in!)).toEqual(['finding']);
    // The gate must stay armed — this is the whole point of field-level degradation.
    expect(getLegalKinds(dir, 'greg')).toEqual(['finding']);
  });

  it('drops a malformed a2a_in (disarming) but keeps publishes and role', () => {
    const dir = mkTmp();
    fs.mkdirSync(path.join(dir, 'greg'), { recursive: true });
    fs.writeFileSync(
      path.join(dir, 'greg', 'agent.json'),
      JSON.stringify({
        role: 'Аналитик',
        a2a_in: { finding: 'старая строковая форма' },
        publishes: { desc: 'сводка', fields: { 'Готовность': 'N/100' } },
      }),
    );
    const d = readAgentDescriptor(dir, 'greg');
    expect(d?.a2a_in).toBeUndefined();
    expect(getLegalKinds(dir, 'greg')).toBeNull(); // disarmed, fail-open
    expect(d?.role).toBe('Аналитик');
    expect(d?.publishes?.fields).toEqual({ 'Готовность': 'N/100' });
  });

  it('accepts a full typed contract', () => {
    const dir = mkTmp();
    fs.mkdirSync(path.join(dir, 'payne'), { recursive: true });
    fs.writeFileSync(
      path.join(dir, 'payne', 'agent.json'),
      JSON.stringify({
        role: 'Тренер',
        aka: ['Пейн'],
        a2a_in: {
          health_signal: {
            desc: 'Готовность на сегодня',
            from: ['greg'],
            fields: { date: 'string (ISO)', level: 'green|yellow|red' },
            reply: 'health_signal_ack',
          },
        },
        publishes: { desc: 'Трен-статус', fields: { 'Программа': 'текст' }, optional: [] },
      }),
    );
    const d = readAgentDescriptor(dir, 'payne');
    expect(d!.a2a_in!.health_signal.from).toEqual(['greg']);
    expect(d!.a2a_in!.health_signal.reply).toBe('health_signal_ack');
    expect(getLegalKinds(dir, 'payne')).toEqual(['health_signal']);
  });

  it('optional naming a field outside fields is dropped, not fatal', () => {
    const dir = mkTmp();
    fs.mkdirSync(path.join(dir, 'greg'), { recursive: true });
    fs.writeFileSync(
      path.join(dir, 'greg', 'agent.json'),
      JSON.stringify({ publishes: { desc: 'd', fields: { A: 'x' }, optional: ['B'] } }),
    );
    // Shape is valid — `optional` referencing an unknown field is the LINT's job
    // (optional_not_in_fields), not the reader's. The reader only rejects shapes.
    expect(readAgentDescriptor(dir, 'greg')?.publishes?.optional).toEqual(['B']);
  });
});
```

Добавить в начало файла хелпер, если его нет:

```ts
function mkTmp(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'agent-registry-'));
}
```

- [ ] **Step 2: Прогнать — должно падать**

```bash
pnpm exec vitest run src/agent-registry.test.ts
```
Ожидаемо: FAIL — `readAgentDescriptor` возвращает `null` для всех четырёх (нестроковые значения `a2a_in`).

- [ ] **Step 3: Реализовать**

В `src/agent-registry.ts` заменить интерфейсы и тело `readAgentDescriptor`:

```ts
/**
 * Contract for one a2a kind. Published to the registry; NOT validated on the
 * wire — the owner ruled that out: an LLM forced to hit a schema exactly would
 * stall live traffic on a stray field. The gate checks the kind NAME only.
 */
export interface KindContract {
  /** One-line description of what the RECEIVER does with it. */
  desc: string;
  /** Agent folders allowed to send this kind. Lint-checked, not wire-checked. */
  from: string[];
  /** Field name → type description. Published to the registry only. */
  fields: Record<string, string>;
  /** Kind the receiver replies with. Absent = terminal. */
  reply?: string;
}

/** What this agent's public fragment (`profiles/<folder>.md`) carries FOR PEERS. */
export interface PublishContract {
  /** What the fragment is for — one line. */
  desc: string;
  /**
   * Body label → what it carries. Only the BODY: the frontmatter is already
   * typed by the parser in `channels/ios-app/v2/profiles.ts`, so declaration
   * already equals enforcement there. The body is the half with no type at all.
   */
  fields: Record<string, string>;
  /** Labels legitimately absent sometimes (no source data yet). No warn when missing. */
  optional?: string[];
}

export interface AgentDescriptor {
  role?: string;
  a2a_in?: Record<string, KindContract>;
  aka?: string[];
  publishes?: PublishContract;
}

function isStringRecord(v: unknown): v is Record<string, string> {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return false;
  return Object.values(v as Record<string, unknown>).every((x) => typeof x === 'string');
}

function isStringArray(v: unknown): v is string[] {
  return Array.isArray(v) && v.every((x) => typeof x === 'string');
}

function isKindContract(v: unknown): v is KindContract {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return false;
  const c = v as Record<string, unknown>;
  if (typeof c.desc !== 'string') return false;
  if (!isStringArray(c.from)) return false;
  if (!isStringRecord(c.fields)) return false;
  if (c.reply !== undefined && typeof c.reply !== 'string') return false;
  return true;
}

function isPublishContract(v: unknown): v is PublishContract {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return false;
  const p = v as Record<string, unknown>;
  if (typeof p.desc !== 'string') return false;
  if (!isStringRecord(p.fields)) return false;
  if (p.optional !== undefined && !isStringArray(p.optional)) return false;
  return true;
}
```

Заменить тело `readAgentDescriptor` (сохранив JSDoc сверху, дополнив его абзацем ниже):

```ts
/**
 * Read `<agentsDir>/<folder>/agent.json`. Returns null when absent (not yet
 * authored) or unparseable. A bad descriptor must never take the registry down —
 * the agent still appears, name-only.
 *
 * Degradation is PER FIELD, not per file. The descriptor now carries two
 * independent concerns: the a2a contract (which arms the transport gate through
 * getLegalKinds) and the fragment contract (which only warns at projection). A
 * typo in a body label must not disarm the wire. So each field is salvaged or
 * dropped on its own; only unreadable/unparseable JSON kills the whole thing.
 */
export function readAgentDescriptor(agentsDir: string, folder: string): AgentDescriptor | null {
  let raw: string;
  try {
    raw = fs.readFileSync(path.join(agentsDir, folder, 'agent.json'), 'utf8');
  } catch {
    return null; // no descriptor yet
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    log.warn('agent-registry: malformed agent.json, ignored', { folder, err });
    return null;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    log.warn('agent-registry: agent.json is not an object, ignored', { folder });
    return null;
  }
  const d = parsed as Record<string, unknown>;
  const out: AgentDescriptor = {};

  if (d.role !== undefined) {
    if (typeof d.role === 'string') out.role = d.role;
    else log.warn('agent-registry: agent.json `role` is not a string, dropped', { folder });
  }

  if (d.aka !== undefined) {
    if (isStringArray(d.aka)) out.aka = d.aka;
    else log.warn('agent-registry: agent.json `aka` is not a string array, dropped', { folder });
  }

  // Dropping a2a_in leaves it undefined → getLegalKinds returns null → the gate
  // DISARMS for this agent. That is the deliberate fail-open: a typo bouncing
  // every message an agent receives is far worse than the drift the gate stops.
  if (d.a2a_in !== undefined) {
    const a = d.a2a_in;
    if (a === null || typeof a !== 'object' || Array.isArray(a)) {
      log.warn('agent-registry: agent.json `a2a_in` is not an object, dropped (gate disarmed)', { folder });
    } else if (!Object.values(a as Record<string, unknown>).every(isKindContract)) {
      log.warn('agent-registry: agent.json `a2a_in` has a malformed contract, dropped (gate disarmed)', { folder });
    } else {
      out.a2a_in = a as Record<string, KindContract>;
    }
  }

  if (d.publishes !== undefined) {
    if (isPublishContract(d.publishes)) out.publishes = d.publishes;
    else log.warn('agent-registry: agent.json `publishes` is malformed, dropped', { folder });
  }

  return out;
}
```

В `buildRegistry` добавить `publishes` в собираемую запись и в `RegistryEntry`:

```ts
export interface RegistryEntry {
  id: string;
  name: string;
  role: string;
  a2a_in: Record<string, KindContract>;
  aka: string[];
  publishes: PublishContract | null;
}
```

```ts
export function buildRegistry(agentsDir: string): RegistryEntry[] {
  return getAllAgentGroups().map((g) => {
    const d = readAgentDescriptor(agentsDir, g.folder);
    return {
      id: g.folder,
      name: g.name,
      role: d?.role ?? '',
      a2a_in: d?.a2a_in ?? {},
      aka: d?.aka ?? [],
      publishes: d?.publishes ?? null,
    };
  });
}
```

`getLegalKinds` — **не трогать**. Её JSDoc уже описывает три случая и остаётся верным.

- [ ] **Step 4: Прогнать — должно проходить**

```bash
pnpm exec vitest run src/agent-registry.test.ts
```
Ожидаемо: PASS. Затем весь хост, чтобы поймать сломанные соседние тесты:
```bash
pnpm test
```

- [ ] **Step 5: Коммит**

```bash
git add src/agent-registry.ts src/agent-registry.test.ts
git commit -m "feat(a2a): typed kind contracts + fragment contract, field-level degradation

a2a_in values go from prose strings to KindContract {desc, from, fields,
reply?} and the descriptor gains `publishes` for the fragment body. The
prose obligations ('Ответ — health_signal_ack Грегу') become fields a lint
can check.

getLegalKinds still returns Object.keys(a2a_in), so write-destinations and
agent-route are untouched and the gate does not move.

readAgentDescriptor now degrades per field, not per file. The descriptor
carries two independent concerns — the a2a contract arms the transport
gate, the fragment contract only warns at projection. Whole-file null was
right when both fields served the registry; with publishes added it would
mean a typo in a body label disarms the wire.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Реестр рендерит поля и фрагмент

**Files:**
- Modify: `src/agent-registry.ts` (`renderRegistryMarkdown`, `ident` JSDoc)
- Test: `src/agent-registry.test.ts`

**Контекст.** Реестр — единственный документ, который агенты читают как истину о пирах. Теперь он должен нести типы. Таблица «Принимает a2a» не меняется (имена kind'ов).

**Мина.** Комментарий над `ident()` обещает «Real folders and kind names are `[A-Za-z0-9_-]`, so this is a no-op on every legitimate value». Подписи полей тела — русские с пробелами (`Состав тела`), для них это уже неправда. Функция всё ещё делает верное (режет `` ` ``/`|`/`\`/CR/LF), но обещание надо поправить, иначе следующий читатель решит, что проверка сломана.

- [ ] **Step 1: Написать падающий тест**

```ts
describe('renderRegistryMarkdown typed contracts', () => {
  it('renders fields, from, reply and the fragment', () => {
    const md = renderRegistryMarkdown([
      {
        id: 'greg',
        name: 'Greg',
        role: 'Аналитик здоровья',
        aka: ['Грег'],
        a2a_in: {
          workout_summary: {
            desc: 'Пейн — итог тренировки',
            from: ['payne'],
            fields: { date: 'string (ISO)', tonnage_kg: 'number' },
          },
          differential: {
            desc: 'Джарвис просит разбор жалобы',
            from: ['jarvis'],
            fields: { complaint: 'string' },
            reply: 'finding',
          },
        },
        publishes: {
          desc: 'Дневная сводка здоровья',
          fields: { 'Готовность': 'N/100', 'Состав тела': 'вес кг · жир кг' },
          optional: ['Состав тела'],
        },
      },
    ]);
    expect(md).toContain('| `greg` | Greg | Аналитик здоровья | `workout_summary`, `differential` |');
    expect(md).toContain('- `workout_summary` — Пейн — итог тренировки');
    expect(md).toContain('От: `payne`.');
    expect(md).toContain('Ответ: `finding`.');
    expect(md).toContain('`date` string (ISO)');
    expect(md).toContain('### Публикует: `profiles/greg.md`');
    expect(md).toContain('- `Готовность` — N/100');
    expect(md).toContain('_(может отсутствовать)_');
  });

  it('renders a publishes-only agent (no a2a kinds)', () => {
    const md = renderRegistryMarkdown([
      {
        id: 'gordon', name: 'Гордон Рамзи', role: 'Нутрициолог', aka: [],
        a2a_in: {},
        publishes: { desc: 'Сводка питания', fields: { 'Цель': 'текст' } },
      },
    ]);
    expect(md).toContain('### Публикует: `profiles/gordon.md`');
    expect(md).toContain('| `gordon` | Гордон Рамзи | Нутрициолог | — |');
  });
});
```

- [ ] **Step 2: Прогнать — должно падать**

```bash
pnpm exec vitest run src/agent-registry.test.ts -t 'typed contracts'
```
Ожидаемо: FAIL — рендер не знает про `from`/`reply`/`fields`/`publishes`.

- [ ] **Step 3: Реализовать**

Поправить JSDoc `ident()`:

```ts
/**
 * Identifier destined for a `code span` (ids, kind names, fragment body labels).
 * Backslash escapes do not apply inside code spans, so escaping can't save us —
 * strip the characters that would break the span or the row instead.
 *
 * Folders and kind names are `[A-Za-z0-9_-]`, so this is a no-op on them. Body
 * labels are human prose ("Состав тела") and legitimately carry spaces and
 * Cyrillic — those pass through untouched; only the span/row breakers go.
 */
```

Заменить второй цикл в `renderRegistryMarkdown`:

```ts
  for (const e of entries) {
    const kinds = Object.entries(e.a2a_in);
    // Gate on anything worth showing — NOT on kinds alone. `aka` and `publishes`
    // are rendered only here, so a receive-only or publish-only agent would
    // otherwise never appear.
    if (kinds.length === 0 && !e.role && e.aka.length === 0 && !e.publishes) continue;
    lines.push('', `## ${oneLine(e.name)} (\`${ident(e.id)}\`)`);
    if (e.role) lines.push(`Роль: ${oneLine(e.role)}`);
    if (e.aka.length > 0) lines.push(`Также зовут: ${e.aka.map(oneLine).join(', ')}`);
    if (kinds.length > 0) lines.push('');
    for (const [kind, c] of kinds) {
      lines.push(`- \`${ident(kind)}\` — ${oneLine(c.desc)}`);
      const meta: string[] = [];
      if (c.from.length > 0) meta.push(`От: ${c.from.map((f) => `\`${ident(f)}\``).join(', ')}.`);
      if (c.reply) meta.push(`Ответ: \`${ident(c.reply)}\`.`);
      if (meta.length > 0) lines.push(`  ${meta.join(' ')}`);
      const fields = Object.entries(c.fields);
      if (fields.length > 0) {
        lines.push(`  Поля: ${fields.map(([k, t]) => `\`${ident(k)}\` ${oneLine(t)}`).join(' · ')}`);
      }
    }
    if (e.publishes) {
      const opt = new Set(e.publishes.optional ?? []);
      lines.push('', `### Публикует: \`profiles/${ident(e.id)}.md\``, oneLine(e.publishes.desc), '');
      for (const [label, type] of Object.entries(e.publishes.fields)) {
        const mark = opt.has(label) ? ' _(может отсутствовать)_' : '';
        lines.push(`- \`${ident(label)}\` — ${oneLine(type)}${mark}`);
      }
    }
  }
```

Поправить шапку — она должна объяснять новую половину:

```ts
  const lines = [
    '# Реестр агентов',
    '',
    'Кто есть кто в команде. **Генерируется хостом — не редактировать вручную.**',
    'Имя — канон из `agent_groups.name`. `a2a_in` — какие kind агент принимает.',
    '«Публикует» — что лежит в его фрагменте `/workspace/global/profiles/<id>.md`,',
    'который ты можешь читать бесплатно (pull), не будя его контейнер.',
    '',
    '| id | Имя | Роль | Принимает a2a |',
    '|---|---|---|---|',
  ];
```

- [ ] **Step 4: Прогнать**

```bash
pnpm exec vitest run src/agent-registry.test.ts && pnpm test
```
Ожидаемо: PASS.

- [ ] **Step 5: Коммит**

```bash
git add src/agent-registry.ts src/agent-registry.test.ts
git commit -m "feat(a2a): registry renders typed fields, from/reply, and the fragment contract

The registry is the one document agents read as peer ground truth, so it is
where the types belong — not the prompt. Rendering fields per turn would
cost ~1.5k tokens per agent for something the gate never reads; the agent
opens agents.md when it actually needs the shape.

Also fixes the ident() JSDoc: it promised a no-op on every legitimate value
because folders and kind names are [A-Za-z0-9_-]. Body labels are prose
('Состав тела') and carry spaces and Cyrillic. The function still does the
right thing; the promise was what went stale.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Чистая функция линта

**Files:**
- Create: `src/modules/agent-to-agent/a2a-lint.ts`
- Test: `src/modules/agent-to-agent/a2a-lint.test.ts`

**Контекст.** Линт — третья точка проверки (билд), рядом с рантайм-гейтом и warn'ом проекции. Чистая функция: никакого IO, всё на вход. IO — в Task 4.

- [ ] **Step 1: Написать падающие тесты**

`src/modules/agent-to-agent/a2a-lint.test.ts`:

```ts
import { describe, expect, it } from 'vitest';

import { lintA2a, type LintInput } from './a2a-lint.js';

const base: LintInput = {
  descriptors: {
    greg: {
      role: 'Аналитик',
      a2a_in: {
        workout_summary: { desc: 'итог', from: ['payne'], fields: { date: 'string' } },
      },
      publishes: { desc: 'сводка', fields: { 'Готовность': 'N/100' } },
    },
    payne: {
      role: 'Тренер',
      a2a_in: {},
      publishes: { desc: 'трен', fields: { 'Программа': 'текст' } },
    },
  },
  sends: [{ from: 'payne', to: 'greg', kind: 'workout_summary', where: 'payne/skills/chat-log' }],
  edges: [{ from: 'payne', to: 'greg' }],
  fragmentRefs: [],
};

const codes = (i: LintInput) => lintA2a(i).map((f) => f.code).sort();

describe('lintA2a', () => {
  it('is clean on a consistent set', () => {
    expect(lintA2a(base)).toEqual([]);
  });

  it('unknown_kind: skill sends a kind the receiver does not declare', () => {
    expect(codes({ ...base, sends: [{ from: 'payne', to: 'greg', kind: 'health_trend', where: 'x' }] }))
      .toContain('unknown_kind');
  });

  it('phantom_kind: declared kind nobody sends', () => {
    expect(codes({ ...base, sends: [] })).toContain('phantom_kind');
  });

  it('undeclared_sender: sender not in from[]', () => {
    expect(codes({
      ...base,
      sends: [{ from: 'jarvis', to: 'greg', kind: 'workout_summary', where: 'x' }],
      edges: [{ from: 'jarvis', to: 'greg' }],
      descriptors: { ...base.descriptors, jarvis: { role: 'Хаб' } },
    })).toContain('undeclared_sender');
  });

  it('missing_edge: from[] names an agent with no destination edge', () => {
    expect(codes({ ...base, edges: [] })).toContain('missing_edge');
  });

  it('dangling_reply: reply kind absent from the sender descriptor', () => {
    expect(codes({
      ...base,
      descriptors: {
        ...base.descriptors,
        greg: {
          ...base.descriptors.greg!,
          a2a_in: {
            workout_summary: { desc: 'итог', from: ['payne'], fields: {}, reply: 'nope' },
          },
        },
      },
    })).toContain('dangling_reply');
  });

  it('reply_not_sent: reply declared but no skill sends it back', () => {
    const found = lintA2a({
      ...base,
      descriptors: {
        ...base.descriptors,
        greg: {
          ...base.descriptors.greg!,
          a2a_in: { workout_summary: { desc: 'и', from: ['payne'], fields: {}, reply: 'ack' } },
        },
        payne: { ...base.descriptors.payne!, a2a_in: { ack: { desc: 'a', from: ['greg'], fields: {} } } },
      },
      edges: [{ from: 'payne', to: 'greg' }, { from: 'greg', to: 'payne' }],
    });
    const f = found.find((x) => x.code === 'reply_not_sent');
    expect(f?.severity).toBe('warn');
  });

  it('no_publishes / no_role are warns, not errors', () => {
    const found = lintA2a({
      ...base,
      descriptors: { ...base.descriptors, jarvis: {} },
      sends: base.sends,
    });
    expect(found.find((f) => f.code === 'no_publishes')?.severity).toBe('warn');
    expect(found.find((f) => f.code === 'no_role')?.severity).toBe('warn');
  });

  it('optional_not_in_fields: optional names an unknown label', () => {
    expect(codes({
      ...base,
      descriptors: {
        ...base.descriptors,
        greg: { ...base.descriptors.greg!, publishes: { desc: 'd', fields: { A: 'x' }, optional: ['B'] } },
      },
    })).toContain('optional_not_in_fields');
  });

  it('unknown_fragment_ref: skill reads a fragment of a non-agent', () => {
    expect(codes({ ...base, fragmentRefs: [{ from: 'payne', target: 'ghost', where: 'x' }] }))
      .toContain('unknown_fragment_ref');
  });

  it('a null descriptor produces no findings of its own — absent is not broken', () => {
    const found = lintA2a({ ...base, descriptors: { ...base.descriptors, scrooge: null } });
    // scrooge has no descriptor yet: name-only registry entry, gate disarmed.
    // That is a valid state, not drift — nothing about it may be reported.
    expect(found.filter((f) => f.msg.includes('scrooge'))).toEqual([]);
  });

  it('sending to a disarmed target is never an error — it fails open by design', () => {
    expect(codes({
      ...base,
      descriptors: { ...base.descriptors, scrooge: { role: 'Финансист' } },
      sends: [...base.sends, { from: 'payne', to: 'scrooge', kind: 'anything_at_all', where: 'x' }],
      edges: [...base.edges, { from: 'payne', to: 'scrooge' }],
    })).not.toContain('unknown_kind');
  });
});
```

- [ ] **Step 2: Прогнать — должно падать**

```bash
pnpm exec vitest run src/modules/agent-to-agent/a2a-lint.test.ts
```
Ожидаемо: FAIL — `Cannot find module './a2a-lint.js'`.

- [ ] **Step 3: Реализовать**

`src/modules/agent-to-agent/a2a-lint.ts`:

```ts
/**
 * Build-time consistency check for the agent contract layer.
 *
 * Three things check the protocol, at three different moments: this lint (build),
 * `public-profiles.ts` (fragment projection), and the runtime a2a gate
 * (`agent-route.ts`). The gate catches "a skill sends what the receiver does not
 * accept" and bounces. It cannot catch the reverse — "the receiver declares what
 * nobody sends" — because nothing ever arrives to judge. That reverse drift is
 * what let 11 of 15 declared kinds rot into fossils. This is where it dies.
 *
 * Pure: no filesystem, no DB. Callers gather the input (see `lint-scan.ts`) so
 * the rules stay testable on fixtures, which matters because `groups/` is
 * gitignored and installation-specific — the repo cannot assert on real agents.
 */
import type { AgentDescriptor } from '../../agent-registry.js';

/** One `<message to="X" kind="Y">` found in a skill or CLAUDE.md. */
export interface A2aSend {
  from: string;
  to: string;
  kind: string;
  /** Where it was found, for the message. e.g. `payne/skills/chat-log`. */
  where: string;
}

/** One `profiles/<target>.md` reference found in a skill or CLAUDE.md. */
export interface FragmentRef {
  from: string;
  target: string;
  where: string;
}

export interface LintInput {
  /** folder → descriptor, null when absent or unparseable. */
  descriptors: Record<string, AgentDescriptor | null>;
  sends: A2aSend[];
  /** agent_destinations rows with target_type='agent', resolved to folders. */
  edges: Array<{ from: string; to: string }>;
  fragmentRefs: FragmentRef[];
}

export interface LintFinding {
  severity: 'error' | 'warn';
  code: string;
  msg: string;
}

export function lintA2a(input: LintInput): LintFinding[] {
  const out: LintFinding[] = [];
  const folders = new Set(Object.keys(input.descriptors));
  const hasEdge = new Set(input.edges.map((e) => `${e.from}→${e.to}`));
  const sent = new Set(input.sends.map((s) => `${s.to}:${s.kind}`));
  const sentBy = new Set(input.sends.map((s) => `${s.from}→${s.to}:${s.kind}`));

  const kindsOf = (folder: string): Record<string, import('../../agent-registry.js').KindContract> =>
    input.descriptors[folder]?.a2a_in ?? {};

  for (const s of input.sends) {
    if (!folders.has(s.to)) {
      out.push({ severity: 'error', code: 'unknown_target', msg: `${s.where}: шлёт «${s.to}» — такого агента нет.` });
      continue;
    }
    const d = input.descriptors[s.to];
    // A null/absent a2a_in means the target DISARMED its gate (fail-open). It
    // accepts anything, so a send to it cannot be wrong — do not invent errors.
    if (!d?.a2a_in) continue;
    const c = d.a2a_in[s.kind];
    if (!c) {
      out.push({
        severity: 'error',
        code: 'unknown_kind',
        msg: `${s.where}: шлёт kind="${s.kind}" к «${s.to}», который его не принимает — отскочит в рантайме. Легальные: ${Object.keys(d.a2a_in).join(', ') || '(нет)'}.`,
      });
      continue;
    }
    if (!c.from.includes(s.from)) {
      out.push({
        severity: 'error',
        code: 'undeclared_sender',
        msg: `${s.where}: «${s.from}» шлёт kind="${s.kind}" к «${s.to}», но не назван в его from: [${c.from.join(', ')}].`,
      });
    }
  }

  for (const [folder, d] of Object.entries(input.descriptors)) {
    if (!d) continue;
    if (!d.role) out.push({ severity: 'warn', code: 'no_role', msg: `${folder}: нет role — в реестре пустая роль.` });
    if (!d.publishes) {
      out.push({ severity: 'warn', code: 'no_publishes', msg: `${folder}: нет publishes — его фрагмент читают вслепую.` });
    } else {
      const labels = new Set(Object.keys(d.publishes.fields));
      for (const o of d.publishes.optional ?? []) {
        if (!labels.has(o)) {
          out.push({
            severity: 'error',
            code: 'optional_not_in_fields',
            msg: `${folder}: publishes.optional называет «${o}», которого нет в fields.`,
          });
        }
      }
    }

    for (const [kind, c] of Object.entries(kindsOf(folder))) {
      if (!sent.has(`${folder}:${kind}`)) {
        out.push({
          severity: 'error',
          code: 'phantom_kind',
          msg: `${folder}: объявил kind="${kind}", но его никто не шлёт — мёртвый контракт.`,
        });
      }
      for (const f of c.from) {
        if (!folders.has(f)) {
          out.push({ severity: 'error', code: 'unknown_sender', msg: `${folder}.${kind}: from называет «${f}» — такого агента нет.` });
          continue;
        }
        if (!hasEdge.has(`${f}→${folder}`)) {
          out.push({
            severity: 'error',
            code: 'missing_edge',
            msg: `${folder}.${kind}: from называет «${f}», но ребра ${f}→${folder} в agent_destinations нет — он физически не сможет.`,
          });
        }
      }
      if (c.reply) {
        for (const f of c.from) {
          const senderKinds = kindsOf(f);
          // The sender may have disarmed (no a2a_in at all) — then it accepts
          // everything and a reply cannot dangle.
          if (!input.descriptors[f]?.a2a_in) continue;
          if (!senderKinds[c.reply]) {
            out.push({
              severity: 'error',
              code: 'dangling_reply',
              msg: `${folder}.${kind}: обещает ответ "${c.reply}", но «${f}» такого kind не принимает.`,
            });
          } else if (!sentBy.has(`${folder}→${f}:${c.reply}`)) {
            out.push({
              severity: 'warn',
              code: 'reply_not_sent',
              msg: `${folder}.${kind}: обещает ответ "${c.reply}" к «${f}», но ни один скил «${folder}» его не шлёт.`,
            });
          }
        }
      }
    }
  }

  for (const r of input.fragmentRefs) {
    if (!folders.has(r.target)) {
      out.push({
        severity: 'error',
        code: 'unknown_fragment_ref',
        msg: `${r.where}: читает profiles/${r.target}.md — такого агента нет.`,
      });
    }
  }

  return out;
}
```

- [ ] **Step 4: Прогнать**

```bash
pnpm exec vitest run src/modules/agent-to-agent/a2a-lint.test.ts
```
Ожидаемо: PASS (11 тестов).

- [ ] **Step 5: Коммит**

```bash
git add src/modules/agent-to-agent/a2a-lint.ts src/modules/agent-to-agent/a2a-lint.test.ts
git commit -m "feat(a2a): build-time lint for the contract layer

The runtime gate catches 'a skill sends what the receiver does not accept'
and bounces. It structurally cannot catch the reverse — 'the receiver
declares what nobody sends' — because nothing ever arrives to judge. That
blind spot is how 11 of 15 declared kinds rotted into fossils. This closes it.

Pure function on gathered input: groups/ is gitignored and
installation-specific, so the repo tests rules against fixtures and the
live install gets asserted by \`ncl groups lint\` instead.

A disarmed target (no a2a_in) is never an error — it fails open by design,
so a send to it cannot be wrong.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Скан + `ncl groups lint`

**Files:**
- Create: `src/modules/agent-to-agent/lint-scan.ts`
- Modify: `src/cli/resources/groups.ts`
- Test: `src/modules/agent-to-agent/lint-scan.test.ts`

**Контекст.** IO-половина: собрать `LintInput` с диска и из БД. `ncl groups lint` — новый verb у существующего ресурса `groups` (шаблон — verb `restart` там же, `src/cli/resources/groups.ts:63`).

- [ ] **Step 1: Написать падающий тест**

`src/modules/agent-to-agent/lint-scan.test.ts`:

```ts
import fs from 'fs';
import os from 'os';
import path from 'path';

import { describe, expect, it } from 'vitest';

import { scanSends, scanFragmentRefs } from './lint-scan.js';

function mkAgent(root: string, folder: string, files: Record<string, string>): void {
  for (const [rel, body] of Object.entries(files)) {
    const p = path.join(root, folder, rel);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, body);
  }
}

describe('scanSends', () => {
  it('finds kind= sends in skills and CLAUDE.md', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'payne', {
      'skills/chat-log/SKILL.md': 'бла\n<message to="jarvis" kind="workout_done">{"date":"x"}</message>\n',
      'CLAUDE.md': '<message to="greg" kind="workout_summary">{}</message>',
    });
    const sends = scanSends(root, ['payne']);
    expect(sends).toEqual([
      { from: 'payne', to: 'greg', kind: 'workout_summary', where: 'payne/CLAUDE.md' },
      { from: 'payne', to: 'jarvis', kind: 'workout_done', where: 'payne/skills/chat-log/SKILL.md' },
    ]);
  });

  it('ignores a message block with no kind (prose is legal)', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'greg', { 'CLAUDE.md': '<message to="jarvis">просто текст</message>' });
    expect(scanSends(root, ['greg'])).toEqual([]);
  });
});

describe('scanFragmentRefs', () => {
  it('finds profiles/<x>.md references and dedups per file', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'gordon', {
      'skills/recomp/SKILL.md': 'Прочитай `/workspace/global/profiles/greg.md`, строку `состав тела:`. Ещё раз profiles/greg.md.',
    });
    expect(scanFragmentRefs(root, ['gordon'])).toEqual([
      { from: 'gordon', target: 'greg', where: 'gordon/skills/recomp/SKILL.md' },
    ]);
  });

  it('does not report an agent referencing its own fragment', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'greg', { 'CLAUDE.md': 'публикуешь в profiles/greg.md' });
    expect(scanFragmentRefs(root, ['greg'])).toEqual([]);
  });
});
```

- [ ] **Step 2: Прогнать — должно падать**

```bash
pnpm exec vitest run src/modules/agent-to-agent/lint-scan.test.ts
```
Ожидаемо: FAIL — модуля нет.

- [ ] **Step 3: Реализовать скан**

`src/modules/agent-to-agent/lint-scan.ts`:

```ts
/**
 * Gather `LintInput` from disk and the central DB. The IO half of the lint —
 * kept apart from `a2a-lint.ts` so the rules stay pure and fixture-testable.
 */
import fs from 'fs';
import path from 'path';

import { readAgentDescriptor, type AgentDescriptor } from '../../agent-registry.js';
import { getAllAgentGroups } from '../../db/agent-groups.js';
import { getDestinations } from './db/agent-destinations.js';
import type { A2aSend, FragmentRef, LintInput } from './a2a-lint.js';

const SEND_RE = /<message\s+to="([a-zA-Z0-9_-]+)"\s+kind="([a-zA-Z0-9_-]+)"/g;
const FRAGMENT_RE = /profiles\/([a-zA-Z0-9_-]+)\.md/g;

/** Every markdown file an agent's prompt can pull in: its CLAUDE.md and its skills. */
function agentDocs(agentsDir: string, folder: string): string[] {
  const out: string[] = [];
  const claude = path.join(agentsDir, folder, 'CLAUDE.md');
  if (fs.existsSync(claude)) out.push(claude);
  const skills = path.join(agentsDir, folder, 'skills');
  let entries: fs.Dirent[] = [];
  try {
    entries = fs.readdirSync(skills, { withFileTypes: true, recursive: true } as never) as fs.Dirent[];
  } catch {
    return out;
  }
  for (const e of entries) {
    if (!e.isFile() || !e.name.endsWith('.md')) continue;
    // `recursive: true` gives parentPath; join it so nested skills resolve.
    const parent = (e as unknown as { parentPath?: string; path?: string }).parentPath ?? (e as unknown as { path: string }).path;
    out.push(path.join(parent, e.name));
  }
  return out;
}

function rel(agentsDir: string, p: string): string {
  return path.relative(agentsDir, p).split(path.sep).join('/');
}

export function scanSends(agentsDir: string, folders: string[]): A2aSend[] {
  const out: A2aSend[] = [];
  const seen = new Set<string>();
  for (const folder of folders) {
    for (const file of agentDocs(agentsDir, folder)) {
      const body = fs.readFileSync(file, 'utf8');
      for (const m of body.matchAll(SEND_RE)) {
        const key = `${folder}|${m[1]}|${m[2]}|${file}`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({ from: folder, to: m[1], kind: m[2], where: rel(agentsDir, file) });
      }
    }
  }
  return out.sort((a, b) => a.where.localeCompare(b.where) || a.kind.localeCompare(b.kind));
}

export function scanFragmentRefs(agentsDir: string, folders: string[]): FragmentRef[] {
  const out: FragmentRef[] = [];
  const seen = new Set<string>();
  for (const folder of folders) {
    for (const file of agentDocs(agentsDir, folder)) {
      const body = fs.readFileSync(file, 'utf8');
      for (const m of body.matchAll(FRAGMENT_RE)) {
        // Its own fragment is its publish target, not a peer read.
        if (m[1] === folder) continue;
        const key = `${folder}|${m[1]}|${file}`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({ from: folder, target: m[1], where: rel(agentsDir, file) });
      }
    }
  }
  return out.sort((a, b) => a.where.localeCompare(b.where) || a.target.localeCompare(b.target));
}

/** Assemble the full input: descriptors from disk, edges from the central DB. */
export function gatherLintInput(agentsDir: string): LintInput {
  const groups = getAllAgentGroups();
  const byId = new Map(groups.map((g) => [g.id, g.folder]));
  const folders = groups.map((g) => g.folder);

  const descriptors: Record<string, AgentDescriptor | null> = {};
  for (const f of folders) descriptors[f] = readAgentDescriptor(agentsDir, f);

  const edges: Array<{ from: string; to: string }> = [];
  for (const g of groups) {
    for (const row of getDestinations(g.id)) {
      if (row.target_type !== 'agent') continue;
      const to = byId.get(row.target_id);
      if (to) edges.push({ from: g.folder, to });
    }
  }

  return { descriptors, sends: scanSends(agentsDir, folders), edges, fragmentRefs: scanFragmentRefs(agentsDir, folders) };
}
```

- [ ] **Step 4: Прогнать скан-тесты**

```bash
pnpm exec vitest run src/modules/agent-to-agent/lint-scan.test.ts
```
Ожидаемо: PASS.

- [ ] **Step 5: Добавить verb `lint`**

В `src/cli/resources/groups.ts`, рядом с `restart` (строка ~63), добавить в тот же объект:

```ts
    lint: {
      help:
        'Check the agent contract layer for drift: kinds sent but not declared, kinds declared but never sent, ' +
        'from[] without a destination edge, dangling replies, fragments with no published contract. ' +
        'Reads agents/<folder>/agent.json, the skills, and agent_destinations. Read-only.',
      handler: async () => {
        const { gatherLintInput } = await import('../../modules/agent-to-agent/lint-scan.js');
        const { lintA2a } = await import('../../modules/agent-to-agent/a2a-lint.js');
        const { AGENTS_DIR } = await import('../../config.js');
        const findings = lintA2a(gatherLintInput(AGENTS_DIR));
        return {
          errors: findings.filter((f) => f.severity === 'error').length,
          warnings: findings.filter((f) => f.severity === 'warn').length,
          findings,
        };
      },
    },
```

Динамический импорт — тот же приём, что у core container-runner для `writeDestinations`: без установленного модуля agent-to-agent таблицы `agent_destinations` нет.

- [ ] **Step 6: Билд + весь тест-ран**

```bash
pnpm run build && pnpm test
```
Ожидаемо: билд чистый, тесты зелёные.

- [ ] **Step 7: Коммит**

```bash
git add src/modules/agent-to-agent/lint-scan.ts src/modules/agent-to-agent/lint-scan.test.ts src/cli/resources/groups.ts
git commit -m "feat(cli): ncl groups lint — run the contract lint against the live install

The rules live in a pure function; this is the IO half plus the verb. The
split exists because groups/ is gitignored and installation-specific: the
repo can test rules on fixtures but cannot assert anything about a
particular install's agents. The live assertion is this command.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Warn на проекции фрагмента

**Files:**
- Modify: `src/public-profiles.ts`, `src/host-sweep.ts:145`
- Test: `src/public-profiles.test.ts`

**Контекст.** `public-profiles.ts` — choke point проекции `public.md` → `profiles/<folder>.md`. Сегодня валидирует ноль. Копия **hash-gated** (`sha(dest) === sha(src)` → `continue`), и это подарок: ставим проверку **за** гейтом — она сработает только когда фрагмент изменился, а не каждые 60 секунд на неизменный. Warn на изменение, как ворнинг сборки.

Забунсать запись файла нельзя — отказ убил бы дашборд. Warn против сегодняшней полной тишины и есть недостающий сигнал.

- [ ] **Step 1: Написать падающий тест**

В `src/public-profiles.test.ts` добавить (и поправить существующие вызовы под новую сигнатуру — второй аргумент `agentsDir`):

```ts
describe('fragment contract validation', () => {
  function withDescriptor(agentsDir: string, folder: string, publishes: unknown): void {
    fs.mkdirSync(path.join(agentsDir, folder), { recursive: true });
    fs.writeFileSync(path.join(agentsDir, folder, 'agent.json'), JSON.stringify({ publishes }));
  }

  it('warns when a declared non-optional field is missing from the body', () => {
    const tmp = mkPersonRoot({ greg: '**Готовность:** 69/100' });
    const agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
    withDescriptor(agentsDir, 'greg', { desc: 'd', fields: { 'Готовность': 'N/100', 'Тренд': 'строка' } });
    const spy = vi.spyOn(log, 'warn');
    projectPublicProfiles(tmp, agentsDir);
    expect(spy).toHaveBeenCalledWith(
      'Fragment is missing declared fields',
      expect.objectContaining({ folder: 'greg', missing: ['Тренд'] }),
    );
  });

  it('does not warn for an optional field', () => {
    const tmp = mkPersonRoot({ greg: '**Готовность:** 69/100' });
    const agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
    withDescriptor(agentsDir, 'greg', {
      desc: 'd',
      fields: { 'Готовность': 'N/100', 'Состав тела': 'вес' },
      optional: ['Состав тела'],
    });
    const spy = vi.spyOn(log, 'warn');
    projectPublicProfiles(tmp, agentsDir);
    expect(spy).not.toHaveBeenCalled();
  });

  it('still projects the fragment when a field is missing — warn, never block', () => {
    const tmp = mkPersonRoot({ greg: '**Готовность:** 69/100' });
    const agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
    withDescriptor(agentsDir, 'greg', { desc: 'd', fields: { 'Тренд': 'строка' } });
    expect(projectPublicProfiles(tmp, agentsDir)).toBe(1);
    expect(fs.existsSync(path.join(tmp, 'global', 'profiles', 'greg.md'))).toBe(true);
  });

  it('is silent for an agent with no descriptor', () => {
    const tmp = mkPersonRoot({ greg: '**Готовность:** 69/100' });
    const agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
    const spy = vi.spyOn(log, 'warn');
    expect(projectPublicProfiles(tmp, agentsDir)).toBe(1);
    expect(spy).not.toHaveBeenCalled();
  });

  it('does not re-warn while the fragment is unchanged (hash gate)', () => {
    const tmp = mkPersonRoot({ greg: '**Готовность:** 69/100' });
    const agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
    withDescriptor(agentsDir, 'greg', { desc: 'd', fields: { 'Тренд': 'строка' } });
    const spy = vi.spyOn(log, 'warn');
    projectPublicProfiles(tmp, agentsDir);
    projectPublicProfiles(tmp, agentsDir);
    // A 60s sweep must not emit 1440 warns/day for one stale fragment.
    expect(spy).toHaveBeenCalledTimes(1);
  });
});
```

Хелпер `mkPersonRoot` (добавить, если нет):

```ts
function mkPersonRoot(fragments: Record<string, string>): string {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'person-'));
  for (const [folder, body] of Object.entries(fragments)) {
    const p = path.join(tmp, folder, 'memories');
    fs.mkdirSync(p, { recursive: true });
    fs.writeFileSync(path.join(p, 'public.md'), body);
  }
  return tmp;
}
```

Импорты в тест: `import { vi } from 'vitest';`, `import os from 'os';`, `import { log } from './log.js';`.

- [ ] **Step 2: Прогнать — должно падать**

```bash
pnpm exec vitest run src/public-profiles.test.ts
```
Ожидаемо: FAIL — `projectPublicProfiles` берёт один аргумент и не валидирует.

- [ ] **Step 3: Реализовать**

В `src/public-profiles.ts` добавить импорт и функцию проверки, поменять сигнатуры:

```ts
import { readAgentDescriptor } from './agent-registry.js';
```

```ts
/**
 * Which declared, non-optional body labels are missing from the fragment.
 *
 * Substring match on the label, deliberately loose: the live fragments write it
 * as `**Состав тела:**` while Jarvis writes `**Погода**` with no colon, and the
 * peer reading it is an LLM that matches loosely too. The job here is to notice
 * when a publisher STOPS writing a declared field — not to police formatting.
 */
function missingFields(body: string, agentsDir: string, folder: string): string[] {
  const p = readAgentDescriptor(agentsDir, folder)?.publishes;
  if (!p) return [];
  const optional = new Set(p.optional ?? []);
  return Object.keys(p.fields).filter((label) => !optional.has(label) && !body.includes(label));
}
```

В `projectPublicProfiles` изменить сигнатуру и вставить проверку **после** хэш-гейта, перед записью:

```ts
export function projectPublicProfiles(groupsDir: string, agentsDir: string): number {
```

```ts
    if (dest !== null && sha(dest) === sha(src)) continue;

    // Behind the hash gate on purpose: this fires only when the fragment
    // actually changed, so a stale one costs one warn, not one per 60s sweep.
    // Warn, never block — a fragment missing a field is degraded, not invalid,
    // and refusing the write would take the dashboard down with it.
    const missing = missingFields(src, agentsDir, folder);
    if (missing.length > 0) {
      log.warn('Fragment is missing declared fields', { folder, missing });
    }

    try {
```

И `projectAllPublicProfiles`:

```ts
export function projectAllPublicProfiles(userMemoryBase: string, agentsDir: string): number {
  // ...
    written += projectPublicProfiles(path.join(userMemoryBase, p.name), agentsDir);
```

Обновить JSDoc модуля, добавив абзац:

```
 * The projection is also where the fragment's declared contract is checked. An
 * agent's `publishes.fields` in agent.json names the body labels its PEERS read;
 * if a declared non-optional label stops being written, this is the only place
 * that can notice. It warns rather than blocks — see missingFields.
```

В `src/host-sweep.ts:145`:

```ts
    const written = projectAllPublicProfiles(path.join(DATA_DIR, 'user-memory'), AGENTS_DIR);
```

Убедиться, что `AGENTS_DIR` импортирован в host-sweep из `./config.js` (он уже используется другими вызовами; если нет — добавить в существующий импорт).

- [ ] **Step 4: Прогнать**

```bash
pnpm exec vitest run src/public-profiles.test.ts && pnpm run build && pnpm test
```
Ожидаемо: PASS, билд чистый.

- [ ] **Step 5: Коммит**

```bash
git add src/public-profiles.ts src/public-profiles.test.ts src/host-sweep.ts
git commit -m "feat(profiles): warn when a fragment drops a declared field

The fragment has two consumers and only one had a type. iOS parses the
frontmatter through a real interface; peer agents read the body by
eyeballing a line label — gordon/skills/recomp reads greg.md's 'состав
тела:' line, a contract declared nowhere and checked nowhere. Worse,
gordon/CLAUDE.md pre-declares the failure normal ('the line may be
absent'), so a break could not even be noticed. a2a at least bounces; this
projection was a 97-line copy that validated nothing.

Checks only the body — the frontmatter is already typed by the parser in
trunk, so declaration already equals enforcement there.

Sits behind the existing hash gate so a stale fragment costs one warn, not
one per 60s sweep. Warns rather than blocks: a fragment missing a field is
degraded, not invalid, and refusing the write would take the dashboard down.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Авторить 5 типизированных дескрипторов + вердикт

**Files:**
- Modify (scp, НЕ git): `groups/{greg,payne,jarvis,gordon,scrooge}/agent.json`

**Контекст.** Вердикт из спеки: 4 живых остаются, 3 воскрешаются, 8 хоронятся. Гордон и Скрудж получают `a2a_in: {}` — взведено text-only.

**`publishes` писать с ЖИВЫХ фрагментов на VDS, не со скилов.** Это правило родилось из прошлого захода: проза расходилась с проводом в обе стороны.

- [ ] **Step 1: Снять живые фрагменты как истину**

```bash
ssh root@148.253.211.164 'for f in greg payne gordon scrooge jarvis; do echo "### $f"; cat /home/nanoclaw/nanoclaw/data/user-memory/owner/global/profiles/$f.md; echo; done'
```
Выписать подписи тела **как они есть**. Замер на 2026-07-17:
- greg: `**Готовность:**`, `**Восстановление:**`, `**Энергия/стресс:**`, `**Тренд:**`, `**Флаги:**`, `**Состав тела:**`
- payne: `**Программа:**`, `**Последняя:**`, `**Следующая:**`, `**Трен-день сегодня:**`
- gordon: `**Цель:**`, `**Таргеты:**`, `**Вчера:**`
- scrooge: `**Запас:**`, `**Траты (30 дней):**`, `**Доход покрывает траты:**`
- jarvis: `**Погода**`, `**Сегодня**`, `**Почта**`, `**Задачи**` — **без двоеточия внутри жирного**, в отличие от остальных. Ключи `fields` — подписи без `**` и без `:`.

- [ ] **Step 2: Написать `groups/greg/agent.json`**

```json
{
  "role": "Аналитик здоровья. Считает метрики скриптами, флагует аномалии и тренды, не ставит диагнозов. Голос — Доктор Хаус.",
  "aka": ["Грег", "Доктор Хаус"],
  "a2a_in": {
    "workout_summary": {
      "desc": "Пейн — итог тренировки для health-аналитики. Коррекция уже присланной — то же сообщение с её date.",
      "from": ["payne"],
      "fields": {
        "date": "string (ISO date)",
        "tonnage_kg": "number",
        "duration_min": "number",
        "perceived_overall_rir": "number",
        "note": "string (опционально)"
      }
    },
    "health_signal_ack": {
      "desc": "Пейн подтверждает приём health_signal: применил ли модификатор и что поставил на следующую.",
      "from": ["payne"],
      "fields": {
        "date": "string (ISO date)",
        "applied": "boolean — применил ли модификатор",
        "level": "green|yellow|red — на что реагировал",
        "next_session": "string (ISO date или day_name)",
        "note": "string (опционально)"
      }
    },
    "differential": {
      "desc": "Джарвис просит разбор жалобы. Ответ терминальный — 2-3 ранжированные гипотезы, без авто-пингов.",
      "from": ["jarvis"],
      "fields": {
        "complaint": "string — жалоба человека своими словами",
        "window_days": "number — окно анализа, обычно 14"
      },
      "reply": "finding"
    },
    "sick_day_ack": {
      "desc": "Джарвис: человек подтвердил, что болеет. Продлевает suppress; decision=\"уже ок\" снимает его.",
      "from": ["jarvis"],
      "fields": {
        "date": "string (ISO date)",
        "decision": "string — 'болею' продлевает suppress, 'уже ок' снимает"
      }
    }
  },
  "publishes": {
    "desc": "Дневная сводка здоровья: готовность, восстановление, тренд, состав тела, флаги.",
    "fields": {
      "Готовность": "N/100 (зелёный|жёлтый|красный)",
      "Восстановление": "↑|↓|→ плюс слово",
      "Энергия/стресс": "N/N справочно",
      "Тренд": "сон · RHR · HRV · ЧСС · шаги · SpO₂",
      "Флаги": "список аномалий за окно",
      "Состав тела": "вес кг · жир кг и % · сухая кг; за месяц жир ↓/↑, сухая ↑/↓"
    },
    "optional": ["Состав тела"]
  }
}
```

`Состав тела` в `optional` — потому что законно отсутствует, пока нет данных с весов. Это ровно та сноска из `gordon/CLAUDE.md:57`, ставшая полем.

- [ ] **Step 3: Написать `groups/payne/agent.json`**

```json
{
  "role": "Фитнес-тренер. Ведёт программу, веса и прогрессию, держит запреты по травмам. Голос — майор Пейн.",
  "aka": ["Пейн", "Payne"],
  "a2a_in": {
    "health_signal": {
      "desc": "Грег — готовность на сегодня. yellow → set_modifier *= 0.9 и rir +1; red → отдых или лёгкое кардио, дождись подтверждения.",
      "from": ["greg"],
      "fields": {
        "date": "string (ISO date)",
        "level": "green|yellow|red",
        "factors": "string[] — что именно просело",
        "recommendation": "string",
        "readiness": "number 0-100"
      },
      "reply": "health_signal_ack"
    }
  },
  "publishes": {
    "desc": "Трен-статус: программа, последняя и следующая тренировка, есть ли трен-день сегодня.",
    "fields": {
      "Программа": "название — мезоцикл N, неделя X/Y (тип недели)",
      "Последняя": "дата + день программы",
      "Следующая": "day_name",
      "Трен-день сегодня": "да|нет"
    }
  }
}
```

- [ ] **Step 4: Написать `groups/jarvis/agent.json`**

```json
{
  "role": "Хаб-оркестратор и автор утреннего брифа. Ассемблер фрагментов остальных агентов; единственный писатель общей памяти о человеке (about.md).",
  "aka": ["Джарвис"],
  "a2a_in": {
    "finding": {
      "desc": "Грег — health-наблюдение. Гейтишь человеку: critical — сразу, warn — только в открытое проактивное окно и если он не в курсе, info — к сведению, не беспокоить.",
      "from": ["greg"],
      "fields": {
        "severity": "info|warn|critical",
        "metric": "string",
        "window": "{from, to, days}",
        "observation": "string — человеческая формулировка",
        "suggestion": "string",
        "house_quote": "string — цитируешь verbatim",
        "mode": "anomaly|differential|sick_day",
        "generated_at": "string (ISO)"
      }
    },
    "workout_done": {
      "desc": "Пейн — отчёт о проведённой тренировке. Технический ack, не повод дёргать человека; упомяни в вечерней сводке если уместно.",
      "from": ["payne"],
      "fields": {
        "date": "string (ISO date)",
        "type": "string — day_name",
        "duration_min": "number",
        "perceived_overall_rir": "number",
        "notes": "string (опционально)"
      }
    }
  },
  "publishes": {
    "desc": "Утренняя сводка: погода, события дня, почта, задачи.",
    "fields": {
      "Погода": "город: температура, облачность, ветер, осадки",
      "Сегодня": "список событий с временем",
      "Почта": "чистая | N писем",
      "Задачи": "нет | список"
    }
  }
}
```

Подписи Джарвиса — без двоеточия внутри `**`, поэтому ключи именно `Погода`, а не `Погода:`. Совпадение по подстроке (`body.includes(label)`) ловит оба варианта.

- [ ] **Step 5: Написать `groups/gordon/agent.json`**

```json
{
  "role": "Нутрициолог. Питание, рекомп, БЖУ, разбор еды. Голос — Гордон Рамзи.",
  "aka": ["Гордон", "Рамзи"],
  "a2a_in": {},
  "publishes": {
    "desc": "Сводка питания: цель, таргеты, вчерашний факт.",
    "fields": {
      "Цель": "рекомпозиция|дефицит|поддержка",
      "Таргеты": "N ккал · белок N г",
      "Вчера": "N% калорий, белок недобор/перебор N г"
    }
  }
}
```

`"a2a_in": {}` — взведено text-only: «прозу принимаю, структурных контрактов пока нет». **Не** отсутствие поля (это разоружило бы). Ноль измеренного структурного трафика → выдумывать kind'ы нельзя.

- [ ] **Step 6: Написать `groups/scrooge/agent.json`**

```json
{
  "role": "Финансовый аналитик. Считает деньги скриптами: реестр, net worth, траты, налог ИП. Денег не двигает и не торгует — читает, считает, советует; решает человек.",
  "aka": ["Скрудж"],
  "a2a_in": {},
  "publishes": {
    "desc": "Финансовая сводка огрублённо: запас, тренд трат, покрывает ли доход. Без точных сумм.",
    "fields": {
      "Запас": "N–M мес",
      "Траты (30 дней)": "растут|падают (~N%)",
      "Доход покрывает траты": "да|нет"
    }
  }
}
```

- [ ] **Step 7: Проверить форму локально**

```bash
for f in greg payne jarvis gordon scrooge; do
  printf "%-9s " "$f"; node -e "JSON.parse(require('fs').readFileSync('groups/$f/agent.json','utf8')); console.log('ok')" || echo "BROKEN";
done
```
Ожидаемо: пять `ok`.

- [ ] **Step 8: Не коммитить**

`groups/` в `.gitignore`. Проверить, что ничего не просочилось:
```bash
git status --porcelain groups/ | head
```
Ожидаемо: пусто.

---

### Task 7: Меш + 3 воскрешённых отправителя

**Files:**
- БД VDS: 10 рёбер `agent_destinations`
- Modify (scp): `groups/payne/skills/workout-mode/SKILL.md`, `groups/jarvis/skills/` (новый скил), `groups/greg/skills/differential/SKILL.md`

**Контекст.** Без рёбер `from` в дескрипторах — ложь: линт даст `missing_edge`. Без скилов-отправителей воскрешённые kind'ы останутся фантомами: линт даст `phantom_kind`.

- [ ] **Step 1: Провести 10 рёбер на VDS**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && \
  ncl destinations add --agent-group-id ag-1778740750341-ru9i6e --local-name gordon --target-type agent --target-id gordon && \
  ncl destinations add --agent-group-id greg --local-name scrooge --target-type agent --target-id scrooge && \
  ncl destinations add --agent-group-id greg --local-name gordon --target-type agent --target-id gordon && \
  ncl destinations add --agent-group-id payne --local-name scrooge --target-type agent --target-id scrooge && \
  ncl destinations add --agent-group-id payne --local-name gordon --target-type agent --target-id gordon && \
  ncl destinations add --agent-group-id scrooge --local-name gordon --target-type agent --target-id gordon && \
  ncl destinations add --agent-group-id gordon --local-name jarvis --target-type agent --target-id ag-1778740750341-ru9i6e && \
  ncl destinations add --agent-group-id gordon --local-name greg --target-type agent --target-id greg && \
  ncl destinations add --agent-group-id gordon --local-name payne --target-type agent --target-id payne && \
  ncl destinations add --agent-group-id gordon --local-name scrooge --target-type agent --target-id scrooge'
```

Сначала свериться с точным синтаксисом: `ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && ncl destinations help'`. Джарвис — единственный, у кого id ≠ folder (`ag-1778740750341-ru9i6e`); остальные совпадают.

- [ ] **Step 2: Проверить 20/20**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && /usr/bin/node -e "
const D=require(\"better-sqlite3\");const d=new D(\"data/v2.db\",{readonly:true});
const n=d.prepare(\"SELECT COUNT(*) c FROM agent_destinations WHERE target_type=?\").get(\"agent\").c;
console.log(n+\" agent edges (expect 20)\");
"'
```
Ожидаемо: `20 agent edges (expect 20)`.

- [ ] **Step 3: Пейн шлёт `health_signal_ack`**

В `groups/payne/skills/workout-mode/SKILL.md`, в секцию про `health_signal` (там, где применяется модификатор), добавить после применения:

```markdown
После того как применил (или сознательно не применил) модификатор — **обязательно** ответь Грегу одним сообщением. Это его единственный способ узнать, дошёл ли сигнал:

    <message to="greg" kind="health_signal_ack">{"date":"YYYY-MM-DD","applied":true,"level":"yellow","next_session":"Верх Б","note":"снизил рабочие на 10%, rir +1"}</message>

`applied: false` — законный ответ (например, сегодня и так отдых). Тогда `note` объясняет почему. Терминально: Грег на это не отвечает.
```

- [ ] **Step 4: Джарвис шлёт `sick_day_ack` и `differential`**

Создать `groups/jarvis/skills/health-relay/SKILL.md`:

```markdown
---
name: health-relay
description: Use when the person says they are ill ("болею", "температура", "простыл", "уже ок" after being ill) or complains about a physical symptom that wants analysis ("сплю плохо неделю", "устаю", "давление скачет"). Sends Greg either sick_day_ack (confirming illness → he extends his 24h suppress) or differential (a complaint → he returns 2-3 ranked hypotheses as a finding). Terminal both ways — Greg does not ping back beyond the one reply.
---

# Health-relay

Два повода написать Грегу. Оба терминальны: один ответ, никаких авто-пингов.

## 1. Человек подтвердил болезнь

Грег умеет сам ловить sick-day по сигналам с телефона и глушит себя на 24 часа. Но если человек **сам** сказал, что болеет, — Грег об этом не знает. Скажи ему:

    <message to="greg" kind="sick_day_ack">{"date":"YYYY-MM-DD","decision":"болею"}</message>

Когда человек говорит, что поправился:

    <message to="greg" kind="sick_day_ack">{"date":"YYYY-MM-DD","decision":"уже ок"}</message>

`decision` — свободная строка, но «болею» продлевает suppress, «уже ок» снимает. Не пересказывай симптомы: если их надо разобрать — это второй повод, ниже.

## 2. Жалоба, которую стоит разобрать

Человек жалуется на что-то телесное, что тянет на анализ данных («сплю плохо неделю», «сил нет», «пульс скачет»). Не диагностируй сам — у тебя нет ни данных, ни права. Спроси Грега:

    <message to="greg" kind="differential">{"complaint":"сплю плохо неделю, просыпаюсь в 4 утра","window_days":14}</message>

`complaint` — словами человека, не твоим пересказом. `window_days` — 14, если нет причины взять другое окно.

Грег ответит одним `finding` с `mode: "differential"` — там 2-3 ранжированные гипотезы. Дальше действуй как с любым finding'ом (§Как гейтить finding в CLAUDE.md): цитируй `house_quote` verbatim, гипотезы не переписывай.

## Не делай

- Не шли `differential` на каждое «устал» — только когда жалоба про тело и держится не один день.
- Не шли оба сразу на одно сообщение. Болеет → `sick_day_ack`. Разобрать → `differential`.
- Не жди второго ответа. Оба контракта терминальны.
```

Зарегистрировать скил в `groups/jarvis/skills/index.md` (строкой в том же формате, что соседние).

- [ ] **Step 5: Починить доармейную форму в `differential`**

`groups/greg/skills/differential/SKILL.md:3` описывает вызов голым JSON (`{ "complaint": ..., "window_days": 14 }`) — доармейная форма. Под гейтом это бы отскочило `unmarked_json`. Заменить в `description:`:

```
description: Use when Jarvis sends `<message kind="differential">{"complaint":"<жалоба>","window_days":14}</message>` — режим House «дай два варианта». Runs `bun analyze.js --mode differential`, reads `/tmp/diff.json`, формирует 2-3 ранжированные гипотезы с evidence и next_check, генерирует `house_quote`, отправляет Jarvis ОДНО терминальное сообщение (`kind="finding"`, `mode: "differential"` — см. skill `finding-contract`). Не порождает дальнейших пингов.
```

- [ ] **Step 6: Никаких коммитов**

`groups/` gitignored. Деплой — Task 10.

---

### Task 8: Доктрина pull-first + Гордон читает объявленное

**Files:**
- Modify (scp): `groups/INSTRUCTIONS.md`, `groups/gordon/skills/recomp/SKILL.md`, `groups/gordon/CLAUDE.md`

- [ ] **Step 1: Вбить правило pull-first в INSTRUCTIONS**

В `groups/INSTRUCTIONS.md`, §Agent-to-agent, сразу после абзаца «Who's who», вставить:

```markdown
**Push против pull — сначала считай цену.** `<message to="...">` это **push: он будит контейнер пира**. Пробуждение = полный ход агента: его системный промпт, его скилы, его токены, его латентность. Фрагмент `/workspace/global/profiles/<агент>.md` — **pull: чтение файла, ноль пробуждений, ноль его токенов**. Все фрагменты команды смонтированы тебе на чтение — не только «твоих» пиров.

По умолчанию — **pull**. Реестр говорит, что лежит в фрагменте каждого («Публикует»), так что ты знаешь, стоит ли открывать, ещё не открыв.

a2a оправдан ровно когда:
- пиру надо **действовать** (Грег шлёт Пейну health_signal — Пейн должен переписать сегодняшнюю тренировку), или
- пира надо **разбудить** (событие, которого он не увидит, читая свои данные по расписанию).

«Мне нужен свежий контекст про него» — это pull, не a2a. Разбудить пира, чтобы он пересказал то, что уже опубликовал, — это сжечь его ход ради файла, который лежит у тебя под рукой.
```

- [ ] **Step 2: Гордон читает объявленную подпись, а не угаданную**

В `groups/gordon/skills/recomp/SKILL.md:11` заменить:

```markdown
1. **Тренд тела — у Грега.** Прочитай `/workspace/global/profiles/greg.md`, поле `Состав тела` (вес кг · жир кг и % · сухая кг; за месяц жир ↓/↑, сухая ↑/↓). Какие поля есть в его фрагменте — объявлено в реестре `/workspace/global/agents.md` («Публикует»); своей копии этого списка не заводи. Поле помечено «может отсутствовать»: пока нет данных с весов, его законно нет — это норма, а не поломка. Механизм фрагментов — INSTRUCTIONS §Public profiles.
```

В `groups/gordon/CLAUDE.md:57` заменить строку про `greg.md`:

```markdown
- `greg.md` — состав тела и тренд. Источник для рекомп-вердикта (skill `recomp`). Что именно в нём лежит — реестр `/workspace/global/agents.md`, раздел «Публикует» Грега; здесь не дублирую (копия прозы — то, из-за чего контракты разъехались в прошлый раз).
```

- [ ] **Step 3: Проверить, что нет второй копии контракта**

```bash
grep -rn "состав тела\|Состав тела" groups/gordon groups/greg | grep -v agent.json
```
Ожидаемо: только две правленные строки. Любая третья — это ещё одна копия, которую надо снести и заменить указателем на реестр.

---

### Task 9: Единый скелет + починка стухшей доктрины

**Files:**
- Modify: `CLAUDE.md:142` и таблица `cli_scope`, `docs/db-central.md:320`
- Modify (scp): 5 × `groups/*/CLAUDE.md` — порядок секций

- [ ] **Step 1: Убить ссылки на удалённый модуль**

`CLAUDE.md:142` — убрать `src/claude-md-compose.ts` (удалён в `15945ba5`, преемник `instructions-gen.ts` — в `1d222b76`):

```
Key files: `src/db/container-configs.ts`, `src/container-config.ts`, `src/cli/dispatch.ts` (scope enforcement).
```

`docs/db-central.md:320` — то же:

```
- **Readers:** `src/container-config.ts`, `src/container-runner.ts`, `src/cli/dispatch.ts` (scope enforcement)
```

- [ ] **Step 2: Починить ложное обещание про `cli_scope`**

В `CLAUDE.md` таблица `cli_scope`, строка `disabled` — сейчас обещает «Agent never learns about ncl (instructions excluded from CLAUDE.md)». Исключать нечем: `1d222b76` сделал инструкции статическими. Заменить на правду:

```
| `disabled` | Host dispatch rejects any `cli_request` with `forbidden`. Note: the agent still READS the ncl section of the shared `INSTRUCTIONS.md` — instruction files went static in `1d222b76`, so nothing excludes it per-agent. It will learn ncl exists, try it, and be refused. |
```

- [ ] **Step 3: Привести 5 CLAUDE.md к одному порядку секций**

Порядок (у Гордона он уже почти такой — брать за образец):

```
@./INSTRUCTIONS.md
# <Имя> — <роль одной строкой>
## Личность
## Манера общения
## Память
## Скилы
## Данные
## Команда
## Старт сессии
```

Только **переставить** существующие секции и добавить отсутствующие заголовки. **Содержание не переписывать** — размер Джарвиса (264 строки) в этот заход не входит (спека, «Что НЕ делаем»).

- [ ] **Step 4: Проверить скелет**

```bash
for a in greg payne jarvis gordon scrooge; do
  printf "%-9s " "$a"; grep -c '^## ' groups/$a/CLAUDE.md | tr -d '\n'; echo -n " секций: "; grep '^## ' groups/$a/CLAUDE.md | tr '\n' '|';
  echo;
done
```
Ожидаемо: у всех пятерых одинаковый набор заголовков в одинаковом порядке.

- [ ] **Step 5: Коммит (только git-часть)**

```bash
git add CLAUDE.md docs/db-central.md
git commit -m "docs: drop the deleted claude-md-compose, fix the cli_scope promise

CLAUDE.md listed src/claude-md-compose.ts as a key file for 'instructions
exclusion' and db-central.md listed it as a reader. It was deleted in
15945ba5, superseded by instructions-gen.ts, which 1d222b76 then deleted
too when it made instruction files static.

The cli_scope table still promised disabled means 'Agent never learns about
ncl (instructions excluded from CLAUDE.md)'. There is nothing left to
exclude: the shared INSTRUCTIONS.md is bind-mounted whole into every
container, so the agent reads all 42 ncl lines regardless of scope, tries
to use it, and gets forbidden at dispatch. Documents the real behavior.

Declaration diverged from enforcement — in the file that governs the work.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Деплой + верификация

> **ИСПОЛНЕНО 2026-07-17. Четыре команды ниже были неверны — исправлены по месту, см. «Правки, найденные исполнением» в конце файла.** Главная: `scp groups/INSTRUCTIONS.md` ехал в `agents/`, а читается из `GROUPS_DIR` — молчаливый no-op, доктрина Task 8 не дошла бы ни до кого. И между Step 3 и Step 4 не хватало рестарта хоста.

**Контекст.** Порядок безразличен: и новый код со старыми дескрипторами, и старый код с новыми дают `null` → разоружено. Ни один порядок не вооружает неверно. **Замерено на исполнении:** 21 warning между scp и рестартом, 0 после. Окно реально, fail-open — но закрывать рестартом сразу.

`INSTRUCTIONS.md`/`CLAUDE.md` bind-mounted RO и читаются при старте контейнера → нужен rebirth пятерых.

- [ ] **Step 1: Сверить дрейф скилов ПЕРЕД scp**

Скилы в контейнере RW — агенты могли править себя.

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw/agents && find . -name "*.md" -path "*/skills/*" | sort | xargs md5sum' > /tmp/vds-skills.txt
cd /Users/serg/git/nanoclaw/groups && find . -name "*.md" -path "*/skills/*" | sort | xargs md5 -r | awk '{print $1"  "$2}' > /tmp/local-skills.txt
diff /tmp/vds-skills.txt /tmp/local-skills.txt
```
Ожидаемо: расходятся **ровно** правленные в Tasks 7-8. Любой другой файл = runtime-самоправка, её надо сначала втянуть локально, иначе scp её затрёт.

- [ ] **Step 2: Push кода**

```bash
git fetch origin && git log --oneline origin/main..HEAD
git push origin main
```
Параллельные сессии на main — `fetch` перед push обязателен, rebase/force запрещены.

- [ ] **Step 3: Билд на VDS**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && sudo -u nanoclaw git pull && sudo -u nanoclaw pnpm run build'
```
`dist/` gitignored — без билда изменения хоста не поедут.

- [ ] **Step 3b: Рестарт хоста — БЕЗ НЕГО БИЛД НИЧЕГО НЕ МЕНЯЕТ**

```bash
ssh root@148.253.211.164 'systemctl --user --machine=nanoclaw@ restart nanoclaw'
ssh root@148.253.211.164 'systemctl --user --machine=nanoclaw@ status nanoclaw --no-pager | head -4'
```
`ExecStart=/usr/bin/node /home/nanoclaw/nanoclaw/dist/index.js` — хост крутится из `dist/`, сборка живой процесс не трогает. Двойное следствие: (1) `ncl` диспатчит **в работающий хост** через `data/ncl.sock`, значит verb `lint` без рестарта не существует и Step 5 упадёт; (2) старый ридер отвергает новые дескрипторы (старая проверка — `Object.values(a).some(v => typeof v !== 'string')`) → whole-file null → все пятеро разоружены, и так и останутся.

- [ ] **Step 4: scp дескрипторов, INSTRUCTIONS и скилов**

Маковый мусор не везти: `._*` (AppleDouble) и `.DS_Store`.

```bash
cd /Users/serg/git/nanoclaw
for f in greg payne jarvis gordon scrooge; do
  scp groups/$f/agent.json root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/$f/agent.json
done
# INSTRUCTIONS.md живёт под GROUPS_DIR, НЕ под agents/ — container-runner.ts:511 + :569.
# Один общий файл на пятерых не может лежать в папке одного из них.
scp groups/INSTRUCTIONS.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md
scp groups/payne/skills/workout-mode/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/payne/skills/workout-mode/SKILL.md
scp groups/greg/skills/differential/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/skills/differential/SKILL.md
scp -r groups/jarvis/skills/health-relay root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/jarvis/skills/
scp groups/jarvis/skills/index.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/jarvis/skills/index.md
scp groups/gordon/skills/recomp/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/gordon/skills/recomp/SKILL.md
scp groups/gordon/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/gordon/CLAUDE.md
for f in greg payne jarvis scrooge; do
  scp groups/$f/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/$f/CLAUDE.md
done
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw/agents && find . -name "._*" -delete; find . -name ".DS_Store" -delete; chown -R nanoclaw:nanoclaw .'
```

Проверить, что INSTRUCTIONS реально лежит там, куда смотрит маунт (`container-runner.ts:511` берёт `GROUPS_DIR/INSTRUCTIONS.md`):
```bash
ssh root@148.253.211.164 'grep -n "^GROUPS_DIR\|AGENTS_DIR" /home/nanoclaw/nanoclaw/.env; ls -la /home/nanoclaw/nanoclaw/agents/INSTRUCTIONS.md'
```

- [ ] **Step 5: Линт — должен быть ЧИСТ**

```bash
# `ncl` не на PATH под sudo -u nanoclaw — абсолютным путём.
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && sudo -u nanoclaw /home/nanoclaw/nanoclaw/bin/ncl groups lint'
```
Ожидаемо: `errors: 0`. **Получено на исполнении: `{"errors": 0, "warnings": 0, "findings": []}`.** Предупреждения допустимы только осознанные. **Любой `phantom_kind` или `missing_edge` = вердикт из Task 6 разошёлся с реальностью Task 7 — чинить, а не объяснять.**

- [ ] **Step 6: Rebirth пятерых**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && for g in ag-1778740750341-ru9i6e greg payne gordon scrooge; do sudo -u nanoclaw /home/nanoclaw/nanoclaw/bin/ncl groups restart --id $g; done'
```

**`ncl groups restart` continuation НЕ снимает** — `container-restart.ts` к `session_state` не прикасается. Снимать отдельно, иначе свежий контейнер возобновит SDK-сессию со старым системным промптом (см. `feedback_agent_instruction_reload`):

```bash
# в <session>/outbound.db: DELETE FROM session_state WHERE key LIKE 'continuation:%'
```
На исполнении: 51 сессия, живой continuation оказался **один** (headless-сессия Джарвиса) — остальные уже без него. Рестарт хоста снимает контейнеры сам, так что `restarted: 0` — норма, а не ошибка: свежие поднимутся на первом сообщении.

- [ ] **Step 7: Верификация — измерить, не предположить**

```bash
# 1. Реестр несёт поля и фрагменты
ssh root@148.253.211.164 'head -40 /home/nanoclaw/nanoclaw/data/user-memory/owner/global/agents.md'
# ожидаемо: таблица + «Поля:» + «### Публикует:» на каждого

# 2. Ноль warning'ов про дескрипторы = все пять распарсились
ssh root@148.253.211.164 'grep -c "agent-registry:" /home/nanoclaw/nanoclaw/logs/nanoclaw.log || echo 0'

# 3. Гейт по-прежнему вооружён: проекция kind'ов в сессию Грега
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && /usr/bin/node -e "
const D=require(\"better-sqlite3\");const fs=require(\"fs\");
const base=\"data/v2-sessions/greg\";
const s=fs.readdirSync(base)[0];
const d=new D(base+\"/\"+s+\"/inbound.db\",{readonly:true});
for(const r of d.prepare(\"SELECT name,type,a2a_kinds FROM destinations\").all()) console.log(r.name, r.type, r.a2a_kinds);
"'
# ожидаемо: jarvis/payne несут массивы kind, gordon/scrooge несут [], каналы NULL

# 4. Фрагменты проецируются без неожиданных warn'ов
ssh root@148.253.211.164 'grep "missing declared fields" /home/nanoclaw/nanoclaw/logs/nanoclaw.log | tail -5'
# ожидаемо: пусто (или только осознанные)

# 5. Хост жив
ssh root@148.253.211.164 'systemctl --user --machine=nanoclaw@ status nanoclaw --no-pager | head -5'
```

- [ ] **Step 8: Обновить память**

Обновить `project_a2a_normalization.md` (или завести `project_typed_agent_contracts.md` со ссылкой) — статус, что оказалось ложью, грабли. **Никогда не пушить `memories/` никуда.**

---

## Self-Review

**Покрытие спеки.** Дескриптор→Task 1 · реестр→Task 2 · линт→Tasks 3-4 · меш→Task 7 · вердикт 15 kind'ов→Task 6+7 · pull-доктрина+контракт→Tasks 5,6,8 · скелет→Task 9 · доктрина→Task 9 · деплой→Task 10. Дыр нет.

**Плейсхолдеры.** Каждый шаг несёт код или точную команду. Единственное «свериться на месте» — синтаксис `ncl destinations add` (Task 7 Step 1) и `GROUPS_DIR` (Task 10 Step 4); оба с явной командой проверки, потому что угадывать чужой CLI хуже, чем спросить его самого.

**Согласованность типов.** `KindContract`/`PublishContract`/`AgentDescriptor` (Task 1) — те же имена в Tasks 2,3,5. `LintInput`/`LintFinding`/`A2aSend`/`FragmentRef` (Task 3) — те же в Task 4. `projectPublicProfiles(groupsDir, agentsDir)` (Task 5) — та же сигнатура в host-sweep.

---

## Правки, найденные исполнением (2026-07-17)

Все — измерением, не чтением. Три из пяти были **молчаливыми**: деплой отрапортовал бы успех.

1. **INSTRUCTIONS.md ехал не туда.** Step 4 слал в `agents/INSTRUCTIONS.md`; читается из `GROUPS_DIR/INSTRUCTIONS.md` (`container-runner.ts:511` → маунт `:569`). Создался бы файл, который никто не читает, живой остался бы протухшим → доктрина pull-first из Task 8 не дошла бы **ни до одного агента**. Асимметрия неслучайна: всё агент-специфичное (CLAUDE.md, skills, scripts, agent.json) — из `agents/<folder>/`, а один общий файл на пятерых не может лежать в папке одного.
2. **Не было рестарта хоста** (Step 3b добавлен). Хост крутится из `dist/`; `ncl` диспатчит в живой процесс → Step 5 упал бы на несуществующем verb'е, а старый ридер держал бы всех пятерых разоружёнными.
3. **Линт не отличал сознательный disarm от случайного.** `readAgentDescriptor` отдаёт `a2a_in: undefined` и когда ключа нет (политика), и когда он отброшен (открытый провод). Правило `if (!d?.a2a_in) continue` читало второе как первое — checkpoint был слеп ровно к тому дрейфу, что открывает гейт. Закрыто: `lint-scan.ts` диффает сырой JSON против распарсенного → `rejected[]` → `malformed_descriptor`. Вероятнейший триггер — `"reply": null`.
4. **`ncl` не на PATH** под `sudo -u nanoclaw` → `/home/nanoclaw/nanoclaw/bin/ncl`. (Падает громко.)
5. **Скелет Task 9 не назвал слот `## Специфика`**, которым пользуются 4 из 5. Гордон был взят за образец — единственный, у кого его нет, потому что он самый маленький. У Джарвиса в нём бо́льшая часть файла. Реальный скелет: `Личность → Манера → Память → Скилы → [Данные] → Команда → [Специфика] → [Старт сессии]`.

**Слепые фикстуры в тестах самого плана — трижды.** Гарды: 9 внутренних проверок, **ни одну нельзя было убить** (одна негативная фикстура нарушала три разом → не пиннила ни одной). `unknown_target`/`unknown_sender`: изолирующего теста не было вовсе. Фикстура `family`: потеряла различающую силу от смены типа. Причина одна — тесты писались, описывая что правило делает, а не спрашивая что его убьёт. Все три поймала мутация; ни одну — перечитывание.

**Найдено сверх плана:** `ncl groups lint` был доступен любому контейнеру с полным графом маршрутов (`dispatch.ts` пропускает scope-фильтр для custom ops, обосновывая тем, что они pinned by `--id` или gated by approval — `lint` не выполнял ни одной ветки). Сделан host-only. И `FRAGMENT_RE` не видел brace-форму `profiles/{a,b,c}.md` — та же конструкция, что обманула grep на этапе дизайна; Джарвис был невидим как читатель фрагментов (4→8 ссылок).

**Не сделано, вынесено:** у greg/payne/scrooge нет `## Старт сессии` — не читают baseline при старте разговора, в отличие от gordon/jarvis. Поведенческая дыра, спека исключила («Содержание не переписывать»).

---

**Вердикт сходится.** greg принимает 4, payne 1, jarvis 2 = **7**. Объявлено было 15 → похоронено 8. Отправители: payne→greg `workout_summary`+`health_signal_ack`, greg→payne `health_signal`, greg→jarvis `finding`, payne→jarvis `workout_done`, jarvis→greg `differential`+`sick_day_ack` = 7 контрактов, у каждого ≥1 отправитель → `phantom_kind` = 0. `reply`: `health_signal→health_signal_ack` (payne шлёт, Task 7 Step 3 ✓), `differential→finding` (greg шлёт ✓). Висячих нет.
