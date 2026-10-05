import { describe, it, expect } from 'vitest';

import { AGENT_COMMANDS, appCommands, findAgentCommand } from './commands.js';

describe('agent command catalogue', () => {
  it('gives every agent /new plus exactly one command of its own', () => {
    const forAgent = (agent: string): string[] =>
      appCommands()
        .filter((c) => c.agent_id === undefined || c.agent_id === agent)
        .map((c) => c.command);
    expect(forAgent('jarvis')).toEqual(['/new', '/surf']);
    expect(forAgent('payne')).toEqual(['/new', '/workout']);
    expect(forAgent('gordon')).toEqual(['/new', '/food']);
    expect(forAgent('greg')).toEqual(['/new', '/health']);
    expect(forAgent('scrooge')).toEqual(['/new', '/money']);
  });

  it('tells the app which commands it answers itself or leaves for the user to finish', () => {
    const byName = new Map(appCommands().map((c) => [c.command, c]));
    expect(byName.get('/workout')).toMatchObject({ agent_id: 'payne', action: 'today_plan' });
    expect(byName.get('/food')).toMatchObject({ agent_id: 'gordon', input: 'compose' });
    expect(byName.get('/new')).toEqual({ command: '/new', description: 'Начать новый разговор' });
  });

  it('names data scripts the runner will accept (scripts/<name>.js under the agent dir)', () => {
    // Mirrors container/agent-runner/src/command-data.ts SCRIPT_RE.
    for (const c of AGENT_COMMANDS) {
      for (const script of c.data ?? []) expect(script).toMatch(/^scripts\/[A-Za-z0-9_-]+\.(js|cjs|mjs)$/);
    }
  });

  it('names serve scripts the runner will run (<skill>/<name>.cjs under the skills mount)', () => {
    // Mirrors container/agent-runner/src/command-serve.ts SERVE_RE.
    const served = AGENT_COMMANDS.filter((c) => c.serve);
    expect(served.map((c) => c.command)).toEqual(['surf']);
    for (const c of served) expect(c.serve).toMatch(/^[a-z0-9-]+\/[a-z0-9-]+\.cjs$/);
  });

  it('finds a command only for the agent that offers it', () => {
    expect(findAgentCommand('greg', 'health')?.data).toEqual(['scripts/analyze.js']);
    expect(findAgentCommand('jarvis', 'health')).toBeUndefined();
  });
});
