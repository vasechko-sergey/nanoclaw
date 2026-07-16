import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { readAgentDescriptor, buildRegistry, renderRegistryMarkdown, writeAgentRegistry } from './agent-registry.js';
import { initTestDb, closeDb, runMigrations, createAgentGroup } from './db/index.js';

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
    writeDescriptor('payne', JSON.stringify({ role: 'фитнес-тренер', a2a_in: { workout_done: 'лог' } }));
    expect(readAgentDescriptor(tmp, 'payne')).toEqual({ role: 'фитнес-тренер', a2a_in: { workout_done: 'лог' } });
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

  it('returns null when aka is not a string array', () => {
    writeDescriptor('typo', JSON.stringify({ role: 'x', aka: 'Пейн' }));
    expect(readAgentDescriptor(tmp, 'typo')).toBeNull();
  });

  it('returns null when a2a_in is not an object', () => {
    writeDescriptor('typo2', JSON.stringify({ a2a_in: 'workout_done' }));
    expect(readAgentDescriptor(tmp, 'typo2')).toBeNull();
  });

  it('returns null when a2a_in has non-string values', () => {
    writeDescriptor('typo3', JSON.stringify({ a2a_in: { workout_done: { desc: 'nested' } } }));
    expect(readAgentDescriptor(tmp, 'typo3')).toBeNull();
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
    writeDescriptor('payne', JSON.stringify({ role: 'фитнес-тренер', a2a_in: { workout_done: 'лог тренировки' } }));

    expect(buildRegistry(tmp)).toEqual([
      {
        id: 'payne',
        name: 'Майор Пейн',
        role: 'фитнес-тренер',
        a2a_in: { workout_done: 'лог тренировки' },
        aka: [],
      },
    ]);
  });

  it('still lists an agent that has no descriptor (name-only entry)', () => {
    createAgentGroup({ id: 'greg', name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
    expect(buildRegistry(tmp)).toEqual([{ id: 'greg', name: 'Greg', role: '', a2a_in: {}, aka: [] }]);
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
      { id: 'payne', name: 'Майор Пейн', role: 'фитнес-тренер', a2a_in: { workout_done: 'лог тренировки' }, aka: [] },
    ]);
    expect(md).toContain('| `payne` | Майор Пейн | фитнес-тренер | `workout_done` |');
    expect(md).toContain('- `workout_done` — лог тренировки');
  });

  it('renders a dash for an agent with no role or actions', () => {
    const md = renderRegistryMarkdown([{ id: 'greg', name: 'Greg', role: '', a2a_in: {}, aka: [] }]);
    expect(md).toContain('| `greg` | Greg | — | — |');
  });

  it('renders a detail section for an agent with aliases but no a2a actions', () => {
    const md = renderRegistryMarkdown([
      { id: 'greg', name: 'Greg', role: 'аналитик здоровья', a2a_in: {}, aka: ['Грег'] },
    ]);
    expect(md).toContain('## Greg (`greg`)');
    expect(md).toContain('Также зовут: Грег');
  });

  it('escapes pipes and newlines so a crafted name cannot corrupt the table', () => {
    const md = renderRegistryMarkdown([{ id: 'evil', name: 'Evil | ghost', role: 'a\nb', a2a_in: {}, aka: [] }]);
    const row = md.split('\n').find((l) => l.startsWith('| `evil`'))!;
    expect(cells(row)).toEqual(['`evil`', 'Evil \\| ghost', 'a b', '—']);
  });

  it('escapes a pre-existing backslash so it cannot defeat the pipe escape', () => {
    const md = renderRegistryMarkdown([{ id: 'bs', name: 'a\\|b', role: 'r', a2a_in: {}, aka: [] }]);
    const row = md.split('\n').find((l) => l.startsWith('| `bs`'))!;
    // 4 cells, not 5: the pipe must stay escaped even though a backslash preceded it
    expect(cells(row)).toHaveLength(4);
  });

  it('collapses a bare carriage return, which alone splits a row', () => {
    const md = renderRegistryMarkdown([{ id: 'cr', name: 'a\rb', role: 'r', a2a_in: {}, aka: [] }]);
    const row = md.split('\n').find((l) => l.startsWith('| `cr`'))!;
    expect(cells(row)).toEqual(['`cr`', 'a b', 'r', '—']);
  });

  it('strips backticks from ids and action names so code spans cannot break', () => {
    const md = renderRegistryMarkdown([{ id: 'x`y', name: 'N', role: 'r', a2a_in: { 'ev`il': 'd' }, aka: [] }]);
    const row = md.split('\n').find((l) => l.startsWith('| `xy`'))!;
    expect(cells(row)).toEqual(['`xy`', 'N', 'r', '`evil`']);
  });
});

describe('writeAgentRegistry', () => {
  it('writes agents.json + agents.md into every person global dir', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    writeDescriptor('payne', JSON.stringify({ role: 'фитнес-тренер', a2a_in: { workout_done: 'лог' } }));

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
        { id: 'payne', name: 'Майор Пейн', role: 'фитнес-тренер', a2a_in: { workout_done: 'лог' }, aka: [] },
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
    writeAgentRegistry(userMemoryBase, tmp);

    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(2);
    expect(fs.readFileSync(path.join(userMemoryBase, 'owner', 'global', 'agents.md'), 'utf8')).toContain('Майор Пейн');
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

  it('ignores non-directory entries in the user-memory base', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });
    fs.writeFileSync(path.join(userMemoryBase, 'stray.txt'), 'not a person');
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(2);
  });
});
