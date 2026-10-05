import { describe, it, expect } from 'vitest';

import { applyAgentCommand, gateCommand } from './command-gate.js';

const msg = (text: string): string => JSON.stringify({ text });

describe('gateCommand: agent commands', () => {
  it("turns an agent's own command into a direct skill prompt with its data scripts", () => {
    const gate = gateCommand(msg('/health'), null, 'ag-greg', 'greg');
    expect(gate).toEqual({
      action: 'agent_command',
      command: 'health',
      text: expect.stringContaining('analyze.js'),
      data: ['scripts/analyze.js'],
    });
  });

  it('passes the text after the command into the prompt', () => {
    const gate = gateCommand(msg('/food 2 яйца и тост'), null, 'ag-gordon', 'gordon');
    expect(gate.action).toBe('agent_command');
    if (gate.action !== 'agent_command') return;
    expect(gate.text).toContain('log-meal');
    expect(gate.text).toContain('2 яйца и тост');
    expect(gate.data).toBeUndefined();
  });

  it('hands a bare /surf to the runner script, and /surf with words to the model', () => {
    const bare = gateCommand(msg('/surf'), null, 'ag-jarvis', 'jarvis');
    expect(bare).toMatchObject({ action: 'agent_command', command: 'surf', serve: 'surf-forecast/forecast.cjs' });
    // The script can't read "в Эрисейре на субботу" — the skill-following model can.
    const worded = gateCommand(msg('/surf в Эрисейре на субботу'), null, 'ag-jarvis', 'jarvis');
    expect(worded.action).toBe('agent_command');
    if (worded.action !== 'agent_command') return;
    expect(worded.serve).toBeUndefined();
    expect(worded.text).toContain('в Эрисейре на субботу');
  });

  it('matches the command case-insensitively', () => {
    expect(gateCommand(msg('/SURF'), null, 'ag-jarvis', 'jarvis').action).toBe('agent_command');
  });

  it("passes another agent's command through untouched", () => {
    // /health belongs to greg; sent to jarvis it is just an unknown slash command.
    expect(gateCommand(msg('/health'), null, 'ag-jarvis', 'jarvis')).toEqual({ action: 'pass' });
  });

  it('passes agent commands through when the caller does not know the folder', () => {
    expect(gateCommand(msg('/health'), null, 'ag-greg')).toEqual({ action: 'pass' });
  });

  it('no longer rewrites the retired Telegram-era commands', () => {
    expect(gateCommand(msg('/people'), null, 'ag-jarvis', 'jarvis')).toEqual({ action: 'pass' });
    expect(gateCommand(msg('/find Иван'), null, 'ag-jarvis', 'jarvis')).toEqual({ action: 'pass' });
  });

  it('still resets the session on /new for every agent', () => {
    expect(gateCommand(msg('/new'), null, 'ag-greg', 'greg')).toEqual({ action: 'new_session' });
  });

  it('leaves plain messages alone', () => {
    expect(gateCommand(msg('как мой сон?'), null, 'ag-greg', 'greg')).toEqual({ action: 'pass' });
  });
});

describe('applyAgentCommand', () => {
  it('swaps the text for the prompt and keeps attachments and the iOS context', () => {
    const content = JSON.stringify({
      text: '/food',
      senderId: 'ios-app:dev-1',
      ios_context: { tz: 'Asia/Makassar' },
      attachments: [{ name: 'plate.jpg' }],
    });
    const out = JSON.parse(applyAgentCommand(content, { command: 'food', text: 'Залогируй еду' }));
    expect(out).toEqual({
      text: 'Залогируй еду',
      senderId: 'ios-app:dev-1',
      ios_context: { tz: 'Asia/Makassar' },
      attachments: [{ name: 'plate.jpg' }],
      command: { name: 'food' },
    });
  });

  it('stamps the data scripts for the runner', () => {
    const out = JSON.parse(
      applyAgentCommand(JSON.stringify({ text: '/health' }), {
        command: 'health',
        text: 'вывод',
        data: ['scripts/analyze.js'],
      }),
    );
    expect(out.command).toEqual({ name: 'health', data: ['scripts/analyze.js'] });
  });

  it('stamps the serve script for the runner', () => {
    const out = JSON.parse(
      applyAgentCommand(JSON.stringify({ text: '/surf' }), {
        command: 'surf',
        text: 'прогноз',
        serve: 'surf-forecast/forecast.cjs',
      }),
    );
    expect(out.command).toEqual({ name: 'surf', serve: 'surf-forecast/forecast.cjs' });
  });

  it('wraps plain-text content', () => {
    expect(JSON.parse(applyAgentCommand('/surf', { command: 'surf', text: 'прогноз' }))).toEqual({
      text: 'прогноз',
      command: { name: 'surf' },
    });
  });
});
