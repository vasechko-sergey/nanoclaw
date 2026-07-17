import fs from 'fs';
import os from 'os';
import path from 'path';

import { describe, expect, it, beforeEach, afterEach } from 'vitest';

import { scanSends, scanFragmentRefs, rejectedFields, gatherLintInput } from './lint-scan.js';
import { lintA2a } from './a2a-lint.js';
import { readAgentDescriptor } from '../../agent-registry.js';
import { initTestDb, closeDb, runMigrations, createAgentGroup } from '../../db/index.js';
import { getDb } from '../../db/connection.js';
import { createDestination } from './db/agent-destinations.js';

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

  it('yields two entries when the same kind goes to the same target from two different files', () => {
    // Real shape: payne sends workout_summary to greg from BOTH workout-mode/SKILL.md
    // and chat-log/SKILL.md. The dedup key includes `file`, so this must NOT collapse
    // to one entry — each file is a separate place the lint can point an operator at.
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'payne', {
      'skills/workout-mode/SKILL.md': '<message to="greg" kind="workout_summary">{"a":1}</message>',
      'skills/chat-log/SKILL.md': '<message to="greg" kind="workout_summary">{"a":2}</message>',
    });
    const sends = scanSends(root, ['payne']);
    expect(sends).toHaveLength(2);
    expect(sends).toEqual([
      { from: 'payne', to: 'greg', kind: 'workout_summary', where: 'payne/skills/chat-log/SKILL.md' },
      { from: 'payne', to: 'greg', kind: 'workout_summary', where: 'payne/skills/workout-mode/SKILL.md' },
    ]);
  });

  it('collapses a literal repeat of the same tag within one file (dedup key has no line number)', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'payne', {
      'CLAUDE.md':
        '<message to="greg" kind="workout_summary">{"a":1}</message>\n' +
        'later in the same file...\n' +
        '<message to="greg" kind="workout_summary">{"a":2}</message>\n',
    });
    expect(scanSends(root, ['payne'])).toEqual([
      { from: 'payne', to: 'greg', kind: 'workout_summary', where: 'payne/CLAUDE.md' },
    ]);
  });

  it('finds a send two levels deep under skills/ (skills/foo/bar/BAZ.md)', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'payne', {
      'skills/foo/bar/BAZ.md': '<message to="greg" kind="workout_summary">{}</message>',
    });
    expect(scanSends(root, ['payne'])).toEqual([
      { from: 'payne', to: 'greg', kind: 'workout_summary', where: 'payne/skills/foo/bar/BAZ.md' },
    ]);
  });

  it('sorts output by where regardless of folder iteration order', () => {
    // Folder order is the caller's (DB query order), not alphabetical — the
    // output must still come out sorted. Iterating readdir happens to return
    // alphabetical order on this filesystem, which would mask a missing sort
    // if the only variation were readdir order; driving it through `folders`
    // instead exercises the sort regardless of filesystem behavior.
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'zzz-agent', { 'CLAUDE.md': '<message to="x" kind="k1">{}</message>' });
    mkAgent(root, 'aaa-agent', { 'CLAUDE.md': '<message to="x" kind="k2">{}</message>' });
    const sends = scanSends(root, ['zzz-agent', 'aaa-agent']);
    expect(sends.map((s) => s.where)).toEqual(['aaa-agent/CLAUDE.md', 'zzz-agent/CLAUDE.md']);
  });

  it('finds sends at every nesting depth at once (index.md, one-deep, two-deep)', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'payne', {
      'skills/index.md': '<message to="a" kind="k0">{}</message>',
      'skills/one/SKILL.md': '<message to="b" kind="k1">{}</message>',
      'skills/two/deep/SKILL.md': '<message to="c" kind="k2">{}</message>',
    });
    const sends = scanSends(root, ['payne']);
    expect(sends.map((s) => s.where).sort()).toEqual([
      'payne/skills/index.md',
      'payne/skills/one/SKILL.md',
      'payne/skills/two/deep/SKILL.md',
    ]);
  });
});

describe('scanFragmentRefs', () => {
  it('finds profiles/<x>.md references and dedups per file', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'gordon', {
      'skills/recomp/SKILL.md':
        'Прочитай `/workspace/global/profiles/greg.md`, строку `состав тела:`. Ещё раз profiles/greg.md.',
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

  it('sorts output by where regardless of folder iteration order', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'zzz-agent', { 'CLAUDE.md': 'читает profiles/aaa-agent.md' });
    mkAgent(root, 'aaa-agent', { 'CLAUDE.md': 'читает profiles/zzz-agent.md' });
    const refs = scanFragmentRefs(root, ['zzz-agent', 'aaa-agent']);
    expect(refs.map((r) => r.where)).toEqual(['aaa-agent/CLAUDE.md', 'zzz-agent/CLAUDE.md']);
  });

  it('expands the brace form into one ref per name (real jarvis/CLAUDE.md:91 shape)', () => {
    // Verbatim shape from the real file. This exact construct is invisible to a
    // single-identifier pattern — it defeated both this scanner's first cut and
    // a hand grep during design, each time hiding four real reads as zero.
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'jarvis', {
      'CLAUDE.md': '- **Читаешь** `profiles/{greg,gordon,payne,scrooge}.md` по запросу, когда тема смежная.',
    });
    expect(scanFragmentRefs(root, ['jarvis'])).toEqual([
      { from: 'jarvis', target: 'gordon', where: 'jarvis/CLAUDE.md' },
      { from: 'jarvis', target: 'greg', where: 'jarvis/CLAUDE.md' },
      { from: 'jarvis', target: 'payne', where: 'jarvis/CLAUDE.md' },
      { from: 'jarvis', target: 'scrooge', where: 'jarvis/CLAUDE.md' },
    ]);
  });

  it("skips the agent's own folder inside a brace list, keeping the others", () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'greg', { 'CLAUDE.md': 'profiles/{greg,gordon,payne}.md' });
    expect(scanFragmentRefs(root, ['greg'])).toEqual([
      { from: 'greg', target: 'gordon', where: 'greg/CLAUDE.md' },
      { from: 'greg', target: 'payne', where: 'greg/CLAUDE.md' },
    ]);
  });

  it('dedups a name appearing in both a brace list and a single ref in one file', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'jarvis', { 'CLAUDE.md': 'profiles/{greg,payne}.md ... и отдельно profiles/greg.md' });
    expect(scanFragmentRefs(root, ['jarvis'])).toEqual([
      { from: 'jarvis', target: 'greg', where: 'jarvis/CLAUDE.md' },
      { from: 'jarvis', target: 'payne', where: 'jarvis/CLAUDE.md' },
    ]);
  });

  it('handles a single-name brace list and ignores empty names from stray commas', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'jarvis', { 'CLAUDE.md': 'profiles/{greg}.md и profiles/{payne,,scrooge}.md' });
    expect(scanFragmentRefs(root, ['jarvis']).map((r) => r.target)).toEqual(['greg', 'payne', 'scrooge']);
  });
});

describe('rejectedFields', () => {
  it('reports a2a_in as rejected when a kind contract has "reply": null', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'greg', {
      'agent.json': JSON.stringify({
        role: 'Аналитик',
        a2a_in: { workout_summary: { desc: 'x', from: [], fields: {}, reply: null } },
      }),
    });
    const d = readAgentDescriptor(root, 'greg');
    expect(d?.a2a_in).toBeUndefined(); // sanity: the reader really did drop it
    expect(rejectedFields(root, 'greg', d!)).toEqual([{ folder: 'greg', field: 'a2a_in' }]);
  });

  it('reports publishes as rejected when it is malformed, without touching a2a_in', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'gordon', {
      'agent.json': JSON.stringify({ role: 'Нутрициолог', publishes: { desc: 123, fields: {} } }),
    });
    const d = readAgentDescriptor(root, 'gordon');
    expect(d?.publishes).toBeUndefined();
    expect(rejectedFields(root, 'gordon', d!)).toEqual([{ folder: 'gordon', field: 'publishes' }]);
  });

  it('reports nothing when a field is simply absent (deliberate disarm, not drift)', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'scrooge', { 'agent.json': JSON.stringify({ role: 'Финансист' }) });
    const d = readAgentDescriptor(root, 'scrooge');
    expect(rejectedFields(root, 'scrooge', d!)).toEqual([]);
  });

  it('reports nothing when every field round-trips cleanly', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-scan-'));
    mkAgent(root, 'payne', {
      'agent.json': JSON.stringify({
        role: 'Тренер',
        aka: ['Пейн'],
        a2a_in: { health_signal: { desc: 'x', from: ['greg'], fields: {} } },
        publishes: { desc: 'd', fields: { A: 'x' } },
      }),
    });
    const d = readAgentDescriptor(root, 'payne');
    expect(rejectedFields(root, 'payne', d!)).toEqual([]);
  });
});

describe('gatherLintInput', () => {
  const TEST_DIR = '/tmp/nanoclaw-test-a2a-lint-scan';

  beforeEach(() => {
    if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true, force: true });
    fs.mkdirSync(TEST_DIR, { recursive: true });
    const db = initTestDb();
    runMigrations(db);
  });

  afterEach(() => {
    closeDb();
    if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true, force: true });
  });

  function now(): string {
    return new Date().toISOString();
  }

  it('wires descriptors, sends, edges, fragmentRefs and rejected together from disk + DB', () => {
    createAgentGroup({ id: 'ag-greg', name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
    createAgentGroup({ id: 'ag-payne', name: 'Payne', folder: 'payne', agent_provider: null, created_at: now() });

    mkAgent(TEST_DIR, 'greg', {
      'agent.json': JSON.stringify({
        role: 'Аналитик',
        // reply: null makes this kind fail isKindContract -> whole a2a_in dropped (rejected).
        a2a_in: { workout_summary: { desc: 'x', from: ['payne'], fields: {}, reply: null } },
      }),
    });
    mkAgent(TEST_DIR, 'payne', {
      'agent.json': JSON.stringify({ role: 'Тренер', a2a_in: {} }),
      'skills/chat-log/SKILL.md': '<message to="greg" kind="workout_summary">{}</message>',
      'CLAUDE.md': 'читаю profiles/greg.md для контекста',
    });

    // Only payne -> greg edge exists; greg -> payne does not.
    createDestination({
      agent_group_id: 'ag-payne',
      local_name: 'greg',
      target_type: 'agent',
      target_id: 'ag-greg',
      created_at: now(),
    });

    const input = gatherLintInput(TEST_DIR);

    expect(input.descriptors.payne?.a2a_in).toEqual({});
    expect(input.descriptors.greg?.a2a_in).toBeUndefined(); // rejected, not merely absent
    expect(input.rejected).toEqual([{ folder: 'greg', field: 'a2a_in' }]);
    expect(input.sends).toEqual([
      { from: 'payne', to: 'greg', kind: 'workout_summary', where: 'payne/skills/chat-log/SKILL.md' },
    ]);
    expect(input.edges).toEqual([{ from: 'payne', to: 'greg' }]);
    expect(input.fragmentRefs).toEqual([{ from: 'payne', target: 'greg', where: 'payne/CLAUDE.md' }]);
  });

  it('excludes channel-type destinations from edges, even a target_id that collides with a real agent id', () => {
    // Real channel target_ids (messaging_group ids) never actually collide with
    // agent_group ids in practice — they use disjoint prefixes by convention,
    // not by schema constraint. Forcing the collision here is the only way to
    // exercise the `target_type === 'agent'` filter at all: without a colliding
    // id, byId.get(target_id) already misses for any real channel row, and the
    // filter's removal would go unnoticed.
    createAgentGroup({ id: 'ag-greg', name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
    createAgentGroup({ id: 'ag-payne', name: 'Payne', folder: 'payne', agent_provider: null, created_at: now() });
    mkAgent(TEST_DIR, 'greg', { 'agent.json': JSON.stringify({ role: 'x' }) });
    mkAgent(TEST_DIR, 'payne', { 'agent.json': JSON.stringify({ role: 'y' }) });

    createDestination({
      agent_group_id: 'ag-payne',
      local_name: 'not-a-real-agent-edge',
      target_type: 'channel',
      target_id: 'ag-greg',
      created_at: now(),
    });

    expect(gatherLintInput(TEST_DIR).edges).toEqual([]);
  });

  it('surfaces a typo inside a brace list as unknown_fragment_ref (the reason the brace form is scanned)', () => {
    // The payoff for matching the brace form: before it, all four names in
    // `profiles/{...}.md` were invisible, so a typo'd peer read clean.
    createAgentGroup({ id: 'ag-jarvis', name: 'Jarvis', folder: 'jarvis', agent_provider: null, created_at: now() });
    createAgentGroup({ id: 'ag-greg', name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
    mkAgent(TEST_DIR, 'jarvis', {
      'agent.json': JSON.stringify({ role: 'Хаб', publishes: { desc: 'd', fields: { A: 'x' } } }),
      // "gregg" is the typo; "greg" is real.
      'CLAUDE.md': 'Читаешь profiles/{greg,gregg}.md по запросу',
    });
    mkAgent(TEST_DIR, 'greg', {
      'agent.json': JSON.stringify({ role: 'Аналитик', publishes: { desc: 'd', fields: { A: 'x' } } }),
    });

    const findings = lintA2a(gatherLintInput(TEST_DIR));
    const dangling = findings.filter((f) => f.code === 'unknown_fragment_ref');
    expect(dangling).toHaveLength(1);
    expect(dangling[0].msg).toContain('gregg');
    expect(dangling[0].severity).toBe('error');
  });

  it('degrades edges to [] instead of throwing when agent_destinations is absent', () => {
    // Simulates an install where the a2a module migration has not run yet.
    getDb().exec('DROP TABLE agent_destinations');

    createAgentGroup({ id: 'ag-greg', name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
    mkAgent(TEST_DIR, 'greg', { 'agent.json': JSON.stringify({ role: 'Аналитик' }) });

    expect(() => gatherLintInput(TEST_DIR)).not.toThrow();
    expect(gatherLintInput(TEST_DIR).edges).toEqual([]);
  });
});
