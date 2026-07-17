/**
 * `ncl groups lint` is host-only, and that is enforced in the verb's own
 * handler rather than by the dispatcher — see the comment on the gate in
 * groups.ts. These tests drive the REAL dispatch → registry → handler path
 * (no mocked dispatcher) because the invariant being protected is precisely
 * that the dispatcher does NOT scope-filter custom operations.
 */
import fs from 'fs';
import path from 'path';

import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';

const TEST_DIR = '/tmp/nanoclaw-test-cli-groups-lint';

vi.mock('../../config.js', async () => {
  const actual = await vi.importActual('../../config.js');
  return { ...actual, AGENTS_DIR: '/tmp/nanoclaw-test-cli-groups-lint/agents' };
});

import { initTestDb, closeDb, runMigrations, createAgentGroup } from '../../db/index.js';
import { ensureContainerConfig } from '../../db/container-configs.js';
import { createSession } from '../../db/sessions.js';
import { dispatch } from '../dispatch.js';
import type { CallerContext } from '../frame.js';
import './groups.js'; // side effect: registerResource -> registers `groups-lint`

const AGENTS_DIR = path.join(TEST_DIR, 'agents');

function now(): string {
  return new Date().toISOString();
}

const agentCtx: CallerContext = {
  caller: 'agent',
  sessionId: 'sess-1',
  agentGroupId: 'ag-greg',
  messagingGroupId: 'mg-1',
};

beforeEach(() => {
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true, force: true });
  fs.mkdirSync(AGENTS_DIR, { recursive: true });
  const db = initTestDb();
  runMigrations(db);

  createAgentGroup({ id: 'ag-greg', name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
  fs.mkdirSync(path.join(AGENTS_DIR, 'greg'), { recursive: true });
  fs.writeFileSync(
    path.join(AGENTS_DIR, 'greg', 'agent.json'),
    JSON.stringify({ role: 'Аналитик', publishes: { desc: 'd', fields: { A: 'x' } } }),
  );

  ensureContainerConfig('ag-greg');
  createSession({
    id: 'sess-1',
    agent_group_id: 'ag-greg',
    messaging_group_id: null,
    thread_id: null,
    owner_key: null,
    agent_provider: null,
    status: 'active',
    container_status: 'stopped',
    last_active: null,
    created_at: now(),
  });
});

afterEach(() => {
  closeDb();
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true, force: true });
});

describe('groups lint — host-only gate', () => {
  it('a host caller gets the report', async () => {
    const resp = await dispatch({ id: '1', command: 'groups-lint', args: {} }, { caller: 'host' });

    expect(resp.ok).toBe(true);
    if (resp.ok) {
      expect(resp.data).toMatchObject({ errors: expect.any(Number), warnings: expect.any(Number) });
      expect((resp.data as { findings: unknown[] }).findings).toBeInstanceOf(Array);
    }
  });

  it('a group-scoped agent caller is refused and gets no mesh data', async () => {
    // 'groups' IS in the group-scope resource whitelist and lint is access:'open',
    // so nothing upstream of the handler stops this — the gate is the only thing
    // between a container and the full descriptor + destination graph.
    const resp = await dispatch({ id: '2', command: 'groups-lint', args: {} }, agentCtx);

    expect(resp.ok).toBe(false);
    if (!resp.ok) {
      expect(resp.error.message).toContain('host-only');
      // The refusal must not leak the thing it is refusing to hand over.
      expect(JSON.stringify(resp)).not.toContain('findings');
    }
  });

  it('a global-scoped agent caller is refused too — scope is not the point, the caller is', async () => {
    // cli_scope:'global' waives the dispatcher's resource whitelist entirely.
    // The gate must not be reachable around that way: this verb is host-only
    // regardless of how privileged the container claims to be.
    const { updateContainerConfigScalars } = await import('../../db/container-configs.js');
    updateContainerConfigScalars('ag-greg', { cli_scope: 'global' });

    const resp = await dispatch({ id: '3', command: 'groups-lint', args: {} }, agentCtx);

    expect(resp.ok).toBe(false);
    if (!resp.ok) expect(resp.error.message).toContain('host-only');
  });
});
