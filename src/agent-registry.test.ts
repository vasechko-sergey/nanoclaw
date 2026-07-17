import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

// Mocked so the disarming warn can be asserted on: it is the ONLY signal that a
// descriptor dropped its a2a_in and opened that agent's wire.
vi.mock('./log.js', () => ({
  log: { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn(), fatal: vi.fn() },
}));

import {
  readAgentDescriptor,
  getLegalKinds,
  buildRegistry,
  renderRegistryMarkdown,
  writeAgentRegistry,
} from './agent-registry.js';
import { initTestDb, closeDb, runMigrations, createAgentGroup, updateAgentGroup } from './db/index.js';
import { log } from './log.js';

let tmp: string;

function now(): string {
  return new Date().toISOString();
}

function writeDescriptor(folder: string, body: string): void {
  const dir = path.join(tmp, folder);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'agent.json'), body);
}

beforeEach(() => {
  vi.clearAllMocks();
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-registry-'));
  const db = initTestDb();
  runMigrations(db);
});

afterEach(() => {
  closeDb();
  fs.rmSync(tmp, { recursive: true, force: true });
});

describe('readAgentDescriptor', () => {
  it('reads a well-formed descriptor', () => {
    const workoutDone = { desc: 'лог', from: ['jarvis'], fields: { reps: 'number' } };
    writeDescriptor('payne', JSON.stringify({ role: 'фитнес-тренер', a2a_in: { workout_done: workoutDone } }));
    expect(readAgentDescriptor(tmp, 'payne')).toEqual({
      role: 'фитнес-тренер',
      a2a_in: { workout_done: workoutDone },
    });
  });

  it('returns null when the descriptor is absent', () => {
    expect(readAgentDescriptor(tmp, 'nobody')).toBeNull();
  });

  it('returns null on malformed JSON instead of throwing', () => {
    writeDescriptor('broken', '{not json');
    expect(readAgentDescriptor(tmp, 'broken')).toBeNull();
  });

  it('returns null when the descriptor is not an object', () => {
    writeDescriptor('weird', '["array"]');
    expect(readAgentDescriptor(tmp, 'weird')).toBeNull();
  });

  it('drops aka when it is not a string array, keeps the rest (field-level degradation)', () => {
    writeDescriptor('typo', JSON.stringify({ role: 'x', aka: 'Пейн' }));
    expect(readAgentDescriptor(tmp, 'typo')).toEqual({ role: 'x' });
  });

  it('drops a2a_in when it is not an object, keeps the rest (gate disarmed)', () => {
    writeDescriptor('typo2', JSON.stringify({ role: 'x', a2a_in: 'workout_done' }));
    expect(readAgentDescriptor(tmp, 'typo2')).toEqual({ role: 'x' });
  });

  it('drops a2a_in when a contract entry is missing required fields (gate disarmed)', () => {
    writeDescriptor('typo3', JSON.stringify({ role: 'x', a2a_in: { workout_done: { desc: 'nested' } } }));
    expect(readAgentDescriptor(tmp, 'typo3')).toEqual({ role: 'x' });
  });
});

describe('getLegalKinds', () => {
  it('returns the declared kinds for an authored descriptor', () => {
    writeDescriptor(
      'payne',
      JSON.stringify({
        role: 'фитнес-тренер',
        a2a_in: {
          set_log: { desc: 'лог подхода', from: ['jarvis'], fields: {} },
          ack: { desc: 'квитанция', from: ['jarvis'], fields: {} },
        },
      }),
    );
    expect(getLegalKinds(tmp, 'payne')).toEqual(['set_log', 'ack']);
  });

  it('returns null when no descriptor is authored — gate disarmed', () => {
    expect(getLegalKinds(tmp, 'nobody')).toBeNull();
  });

  it('returns null for a malformed descriptor — fails OPEN, never bounces everything', () => {
    writeDescriptor('broken', JSON.stringify({ a2a_in: 'not-an-object' }));
    expect(getLegalKinds(tmp, 'broken')).toBeNull();
  });

  it('returns null for a descriptor with no a2a_in — a registry-only entry stays disarmed', () => {
    // agent.json predates the gate and its documented contract is "every field
    // optional — a partial descriptor degrades to a name-only entry". Adding a
    // `role` (the shipped registry's entire purpose) must NOT arm anything: an
    // agent whose owner never made a claim about the a2a wire has not made the
    // claim "I accept nothing but text". Presence of the FILE is not the
    // declaration; presence of `a2a_in` is.
    writeDescriptor('mute', JSON.stringify({ role: 'наблюдатель' }));
    expect(getLegalKinds(tmp, 'mute')).toBeNull();
  });

  it('returns an empty array for an explicit empty a2a_in — deliberately armed, text-only', () => {
    // Distinct from null: this descriptor DOES make a claim about the wire, and
    // the claim is "nothing structured". Gate ARMED. Collapsing [] to null (or
    // null to []) inverts the rollout — see the doc comment on getLegalKinds.
    writeDescriptor('strict', JSON.stringify({ role: 'наблюдатель', a2a_in: {} }));
    expect(getLegalKinds(tmp, 'strict')).toEqual([]);
  });
});

describe('buildRegistry', () => {
  it('joins each agent group with its descriptor, name from agent_groups', () => {
    createAgentGroup({
      id: 'ag-1778-xyz',
      name: 'Майор Пейн',
      folder: 'payne',
      agent_provider: null,
      created_at: now(),
    });
    const workoutDone = { desc: 'лог тренировки', from: ['jarvis'], fields: { reps: 'number' } };
    writeDescriptor('payne', JSON.stringify({ role: 'фитнес-тренер', a2a_in: { workout_done: workoutDone } }));

    expect(buildRegistry(tmp)).toEqual([
      {
        id: 'payne',
        name: 'Майор Пейн',
        role: 'фитнес-тренер',
        a2a_in: { workout_done: workoutDone },
        aka: [],
        publishes: null,
      },
    ]);
  });

  it('still lists an agent that has no descriptor (name-only entry)', () => {
    createAgentGroup({ id: 'greg', name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
    expect(buildRegistry(tmp)).toEqual([{ id: 'greg', name: 'Greg', role: '', a2a_in: {}, aka: [], publishes: null }]);
  });

  it('returns an empty list when there are no agent groups', () => {
    expect(buildRegistry(tmp)).toEqual([]);
  });
});

describe('renderRegistryMarkdown', () => {
  /** Split a markdown table row into cells on UNESCAPED pipes (odd backslash run = escaped). */
  function cells(row: string): string[] {
    const out: string[] = [];
    let cur = '';
    let slashes = 0;
    for (const ch of row) {
      if (ch === '|' && slashes % 2 === 0) {
        out.push(cur);
        cur = '';
        slashes = 0;
        continue;
      }
      slashes = ch === '\\' ? slashes + 1 : 0;
      cur += ch;
    }
    out.push(cur);
    return out.slice(1, -1).map((c) => c.trim());
  }

  it('renders a table row per agent with name, role and actions', () => {
    const md = renderRegistryMarkdown([
      {
        id: 'payne',
        name: 'Майор Пейн',
        role: 'фитнес-тренер',
        a2a_in: { workout_done: { desc: 'лог тренировки', from: ['jarvis'], fields: {} } },
        aka: [],
        publishes: null,
      },
    ]);
    expect(md).toContain('| `payne` | Майор Пейн | фитнес-тренер | `workout_done` |');
    expect(md).toContain('- `workout_done` — лог тренировки');
  });

  it('renders a dash for an agent with no role or actions', () => {
    const md = renderRegistryMarkdown([{ id: 'greg', name: 'Greg', role: '', a2a_in: {}, aka: [], publishes: null }]);
    expect(md).toContain('| `greg` | Greg | — | — |');
  });

  it('renders a detail section for an agent with aliases but no a2a actions', () => {
    const md = renderRegistryMarkdown([
      { id: 'greg', name: 'Greg', role: 'аналитик здоровья', a2a_in: {}, aka: ['Грег'], publishes: null },
    ]);
    expect(md).toContain('## Greg (`greg`)');
    expect(md).toContain('Также зовут: Грег');
  });

  it('escapes pipes and newlines so a crafted name cannot corrupt the table', () => {
    const md = renderRegistryMarkdown([
      { id: 'evil', name: 'Evil | ghost', role: 'a\nb', a2a_in: {}, aka: [], publishes: null },
    ]);
    const row = md.split('\n').find((l) => l.startsWith('| `evil`'))!;
    expect(cells(row)).toEqual(['`evil`', 'Evil \\| ghost', 'a b', '—']);
  });

  it('escapes a pre-existing backslash so it cannot defeat the pipe escape', () => {
    const md = renderRegistryMarkdown([{ id: 'bs', name: 'a\\|b', role: 'r', a2a_in: {}, aka: [], publishes: null }]);
    const row = md.split('\n').find((l) => l.startsWith('| `bs`'))!;
    // 4 cells, not 5: the pipe must stay escaped even though a backslash preceded it
    expect(cells(row)).toHaveLength(4);
  });

  it('collapses a bare carriage return, which alone splits a row', () => {
    const md = renderRegistryMarkdown([{ id: 'cr', name: 'a\rb', role: 'r', a2a_in: {}, aka: [], publishes: null }]);
    const row = md.split('\n').find((l) => l.startsWith('| `cr`'))!;
    expect(cells(row)).toEqual(['`cr`', 'a b', 'r', '—']);
  });

  it('strips backticks from ids and action names so code spans cannot break', () => {
    const md = renderRegistryMarkdown([
      {
        id: 'x`y',
        name: 'N',
        role: 'r',
        a2a_in: { 'ev`il': { desc: 'd', from: [], fields: {} } },
        aka: [],
        publishes: null,
      },
    ]);
    const row = md.split('\n').find((l) => l.startsWith('| `xy`'))!;
    expect(cells(row)).toEqual(['`xy`', 'N', 'r', '`evil`']);
  });
});

describe('writeAgentRegistry', () => {
  it('writes agents.json + agents.md into every person global dir', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    const workoutDone = { desc: 'лог', from: ['jarvis'], fields: {} };
    writeDescriptor('payne', JSON.stringify({ role: 'фитнес-тренер', a2a_in: { workout_done: workoutDone } }));

    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });
    fs.mkdirSync(path.join(userMemoryBase, 'p2'), { recursive: true });

    // 2 files × 2 persons
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(4);

    for (const person of ['owner', 'p2']) {
      const md = fs.readFileSync(path.join(userMemoryBase, person, 'global', 'agents.md'), 'utf8');
      expect(md).toContain('Майор Пейн');
      const json = JSON.parse(fs.readFileSync(path.join(userMemoryBase, person, 'global', 'agents.json'), 'utf8'));
      expect(json).toEqual([
        {
          id: 'payne',
          name: 'Майор Пейн',
          role: 'фитнес-тренер',
          a2a_in: { workout_done: workoutDone },
          aka: [],
          publishes: null,
        },
      ]);
    }
  });

  it('does not rewrite unchanged content (hash-gated)', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });

    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(2);
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(0);
  });

  it('rewrites when a name changes', () => {
    createAgentGroup({ id: 'greg', name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(2);

    updateAgentGroup('greg', { name: 'Грег' });
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(2);
    expect(fs.readFileSync(path.join(userMemoryBase, 'owner', 'global', 'agents.md'), 'utf8')).toContain('Грег');
  });

  it('returns 0 when the user-memory base does not exist', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    expect(writeAgentRegistry(path.join(tmp, 'nonexistent'), tmp)).toBe(0);
  });

  it('returns 0 when there are no agent groups (never publishes an empty registry)', () => {
    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(0);
    expect(fs.existsSync(path.join(userMemoryBase, 'owner', 'global', 'agents.md'))).toBe(false);
  });

  it('does not publish when the agents dir is unreadable (would blank roles/actions)', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    writeDescriptor('payne', JSON.stringify({ role: 'фитнес-тренер', a2a_in: { workout_done: 'лог' } }));
    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });

    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(2);
    const good = fs.readFileSync(path.join(userMemoryBase, 'owner', 'global', 'agents.md'), 'utf8');
    expect(good).toContain('фитнес-тренер');

    // agents dir unreadable → must NOT overwrite the good file with a name-only one
    expect(writeAgentRegistry(userMemoryBase, path.join(tmp, 'gone'))).toBe(0);
    expect(fs.readFileSync(path.join(userMemoryBase, 'owner', 'global', 'agents.md'), 'utf8')).toBe(good);
  });

  // Contract test, NOT branch coverage for the isDirectory() filter: a stray file
  // contributes 0 either way (mkdir on `<file>/global` throws ENOTDIR and is
  // swallowed). It still pins that a stray file can't break the fan-out.
  it('a stray file under the user-memory base does not break the fan-out', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });
    fs.writeFileSync(path.join(userMemoryBase, 'stray.txt'), 'not a person');
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(2);
  });
});

describe('readAgentDescriptor field-level degradation', () => {
  it('drops a malformed publishes but keeps a2a_in armed', () => {
    writeDescriptor(
      'greg',
      JSON.stringify({
        role: 'Аналитик',
        a2a_in: { finding: { desc: 'd', from: ['jarvis'], fields: { severity: 'string' } } },
        publishes: 'не объект',
      }),
    );
    const d = readAgentDescriptor(tmp, 'greg');
    expect(d?.publishes).toBeUndefined();
    expect(Object.keys(d!.a2a_in!)).toEqual(['finding']);
    // The gate must stay armed — this is the whole point of field-level degradation.
    expect(getLegalKinds(tmp, 'greg')).toEqual(['finding']);
  });

  it('drops a malformed a2a_in (disarming) but keeps publishes and role', () => {
    writeDescriptor(
      'greg',
      JSON.stringify({
        role: 'Аналитик',
        a2a_in: { finding: 'старая строковая форма' },
        publishes: { desc: 'сводка', fields: { Готовность: 'N/100' } },
      }),
    );
    const d = readAgentDescriptor(tmp, 'greg');
    expect(d?.a2a_in).toBeUndefined();
    expect(getLegalKinds(tmp, 'greg')).toBeNull(); // disarmed, fail-open
    expect(d?.role).toBe('Аналитик');
    expect(d?.publishes?.fields).toEqual({ Готовность: 'N/100' });
  });

  it('accepts a full typed contract', () => {
    writeDescriptor(
      'payne',
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
        publishes: { desc: 'Трен-статус', fields: { Программа: 'текст' }, optional: [] },
      }),
    );
    const d = readAgentDescriptor(tmp, 'payne');
    expect(d!.a2a_in!.health_signal.from).toEqual(['greg']);
    expect(d!.a2a_in!.health_signal.reply).toBe('health_signal_ack');
    expect(getLegalKinds(tmp, 'payne')).toEqual(['health_signal']);
  });

  it('optional naming a field outside fields is dropped, not fatal', () => {
    writeDescriptor('greg', JSON.stringify({ publishes: { desc: 'd', fields: { A: 'x' }, optional: ['B'] } }));
    // Shape is valid — `optional` referencing an unknown field is the LINT's job
    // (optional_not_in_fields), not the reader's. The reader only rejects shapes.
    expect(readAgentDescriptor(tmp, 'greg')?.publishes?.optional).toEqual(['B']);
  });
});

/**
 * One fixture per guard sub-check, each violating EXACTLY ONE check.
 *
 * These exist because a single fixture that breaks several checks at once pins
 * none of them: delete any one check and the others still reject it, so the
 * test stays green and the deletion goes unnoticed. Measured before these were
 * written: deleting each of the nine guard checks in turn left all 79 tests
 * green, nine times out of nine.
 *
 * If you add a check to a guard, add the fixture that fails ONLY when that check
 * is gone — then delete the check and watch this file go red before you trust it.
 */
describe('readAgentDescriptor guard sub-checks', () => {
  const badContracts: Array<[string, unknown]> = [
    ['desc is not a string', { desc: 5, from: ['jarvis'], fields: {} }],
    ['from is not an array', { desc: 'd', from: 'jarvis', fields: {} }],
    ['from holds a non-string', { desc: 'd', from: [1], fields: {} }],
    ['fields holds a non-string value', { desc: 'd', from: ['jarvis'], fields: { severity: 1 } }],
    ['fields is an array, not a record', { desc: 'd', from: ['jarvis'], fields: ['severity'] }],
    // JSON has no `undefined`, and the KindContract JSDoc says "Absent =
    // terminal" — so null is the natural way a human writes "no reply".
    ['reply is present but null', { desc: 'd', from: ['jarvis'], fields: {}, reply: null }],
    // A bodyless ack, `fields` omitted entirely. Plausible in a hand-authored
    // file and currently fatal to the whole a2a_in.
    ['fields is omitted — the bodyless-ack shape', { desc: 'квитанция', from: ['greg'] }],
  ];

  for (const [what, contract] of badContracts) {
    it(`drops a2a_in when ${what} — gate disarmed, role survives`, () => {
      writeDescriptor('greg', JSON.stringify({ role: 'Аналитик', a2a_in: { finding: contract } }));
      const d = readAgentDescriptor(tmp, 'greg');
      expect(d?.a2a_in).toBeUndefined();
      expect(getLegalKinds(tmp, 'greg')).toBeNull();
      expect(d?.role).toBe('Аналитик'); // per-field: the bad kind takes only a2a_in
    });
  }

  const badPublishes: Array<[string, unknown]> = [
    ['desc is not a string', { desc: 5, fields: {} }],
    ['fields holds a non-string value', { desc: 'd', fields: { Готовность: 1 } }],
    ['optional is not a string array', { desc: 'd', fields: {}, optional: 'Готовность' }],
  ];

  for (const [what, publishes] of badPublishes) {
    it(`drops publishes when ${what} — a2a_in stays armed`, () => {
      writeDescriptor(
        'greg',
        JSON.stringify({ a2a_in: { finding: { desc: 'd', from: ['jarvis'], fields: {} } }, publishes }),
      );
      expect(readAgentDescriptor(tmp, 'greg')?.publishes).toBeUndefined();
      // A typo in a fragment label must never move the wire.
      expect(getLegalKinds(tmp, 'greg')).toEqual(['finding']);
    });
  }
});

describe('readAgentDescriptor disarming warn', () => {
  it('names the offending kind — the warn is the only signal a wire went open', () => {
    // Fail-open is silent: no bounce, no error, the gate just stops checking.
    // A bare `{folder}` warn leaves an operator bisecting a file of N contracts.
    writeDescriptor(
      'greg',
      JSON.stringify({
        a2a_in: {
          finding: { desc: 'ок', from: ['jarvis'], fields: {} },
          health_signal: { desc: 'нет полей', from: ['jarvis'] },
        },
      }),
    );

    // ONE malformed kind disarms ALL of them — not just itself.
    expect(getLegalKinds(tmp, 'greg')).toBeNull();

    const warn = vi.mocked(log.warn).mock.calls.find(([msg]) => msg.includes('`a2a_in`'));
    expect(warn?.[0]).toContain('gate disarmed');
    expect(warn?.[1]).toMatchObject({ folder: 'greg', kind: 'health_signal' });
  });
});
