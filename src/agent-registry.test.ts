import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { readAgentDescriptor, buildRegistry, renderRegistryMarkdown } from './agent-registry.js';
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
    expect(row).toContain('Evil \\| ghost');
    expect(row).toContain('a b');
    // 4 columns → exactly 5 unescaped pipes; the escaped one must not add a column
    expect(row.match(/(?<!\\)\|/g)!.length).toBe(5);
  });
});
