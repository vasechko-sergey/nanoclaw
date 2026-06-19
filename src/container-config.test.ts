import { describe, it, expect } from 'vitest';

import { configFromDb } from './container-config.js';
import type { AgentGroup, ContainerConfigRow } from './types.js';

function row(overrides: Partial<ContainerConfigRow> = {}): ContainerConfigRow {
  return {
    agent_group_id: 'ag-1',
    provider: 'claude',
    model: null,
    effort: null,
    image_tag: null,
    assistant_name: null,
    max_messages_per_prompt: null,
    skills: '"all"',
    mcp_servers: '{}',
    packages_apt: '[]',
    packages_npm: '[]',
    additional_mounts: '[]',
    cli_scope: 'group',
    factuality_gate: 'off',
    updated_at: '2026-06-17T00:00:00Z',
    ...overrides,
  };
}

const group = { id: 'ag-1', name: 'scrooge', folder: 'scrooge' } as AgentGroup;

describe('configFromDb factualityGate', () => {
  it('passes a set gate through', () => {
    expect(configFromDb(row({ factuality_gate: 'deterministic' }), group).factualityGate).toBe('deterministic');
  });

  it('defaults to off when empty/unknown', () => {
    expect(configFromDb(row({ factuality_gate: '' }), group).factualityGate).toBe('off');
  });
});
