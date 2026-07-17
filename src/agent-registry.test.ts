import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

import {
  readAgentDescriptor,
  getLegalKinds,
  buildRegistry,
  renderRegistryMarkdown,
  writeAgentRegistry,
} from './agent-registry.js';
import { initTestDb, closeDb, runMigrations, createAgentGroup, updateAgentGroup } from './db/index.js';

let tmp: string;

function now(): string {
  return new Date().toISOString();
}

function writeDescriptor(folder: string, body: string): void {
  const dir = path.join(tmp, folder);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'agent.json'), body);
}

function mkTmp(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'agent-registry-'));
}

beforeEach(() => {
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
        publishes: { desc: 'сводка', fields: { Готовность: 'N/100' } },
      }),
    );
    const d = readAgentDescriptor(dir, 'greg');
    expect(d?.a2a_in).toBeUndefined();
    expect(getLegalKinds(dir, 'greg')).toBeNull(); // disarmed, fail-open
    expect(d?.role).toBe('Аналитик');
    expect(d?.publishes?.fields).toEqual({ Готовность: 'N/100' });
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
        publishes: { desc: 'Трен-статус', fields: { Программа: 'текст' }, optional: [] },
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
