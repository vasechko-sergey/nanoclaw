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
});

describe('buildRegistry', () => {
  it('joins each agent group with its descriptor, name from agent_groups', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
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
});
