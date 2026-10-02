import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach } from 'bun:test';
import { mkdtempSync, mkdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { applyCommandData } from './command-data.js';
import { initTestSessionDb, closeSessionDb } from './db/connection.js';
import type { MessageInRow } from './db/messages-in.js';
import { formatMessages } from './formatter.js';

let agentDir: string;

beforeAll(() => {
  // realpath: on macOS tmpdir() is a /var symlink, the script's cwd reports /private/var.
  agentDir = realpathSync(mkdtempSync(join(tmpdir(), 'command-data-')));
  mkdirSync(join(agentDir, 'scripts'));
  writeFileSync(
    join(agentDir, 'scripts', 'ok.js'),
    'console.log(JSON.stringify({ readiness: 72, cwd: process.cwd() }));',
  );
  writeFileSync(join(agentDir, 'scripts', 'fail.js'), 'console.error("db locked"); process.exit(3);');
  writeFileSync(join(agentDir, 'scripts', 'big.js'), 'console.log("x".repeat(40000));');
  writeFileSync(join(agentDir, 'escape.js'), 'console.log("must never run");');
});

afterAll(() => rmSync(agentDir, { recursive: true, force: true }));

function row(content: object, kind = 'chat'): MessageInRow {
  return {
    id: `m-${Math.random().toString(36).slice(2, 8)}`,
    seq: 2,
    kind,
    timestamp: new Date().toISOString(),
    status: 'pending',
    process_after: null,
    recurrence: null,
    tries: 0,
    trigger: 1,
    platform_id: 'ios-app:dev-1',
    channel_type: 'ios-app-v2',
    thread_id: null,
    content: JSON.stringify(content),
    source_session_id: null,
  };
}

const contentOf = (r: MessageInRow): Record<string, unknown> => JSON.parse(r.content);

describe('applyCommandData', () => {
  it("runs the command's data scripts from the agent dir and attaches their output", async () => {
    const [out] = await applyCommandData(
      [row({ text: 'вывод', command: { name: 'health', data: ['scripts/ok.js'] } })],
      agentDir,
    );
    const c = contentOf(out);
    expect(c.commandData).toEqual([
      { source: 'scripts/ok.js', output: JSON.stringify({ readiness: 72, cwd: agentDir }) },
    ]);
    // Data is consumed: a second pass must not run the scripts again.
    expect(c.command).toEqual({ name: 'health' });
    const [again] = await applyCommandData([out], agentDir);
    expect(again).toBe(out);
  });

  it('attaches the failure instead of the output, so the model collects the data itself', async () => {
    const [out] = await applyCommandData(
      [row({ text: 'вывод', command: { name: 'money', data: ['scripts/fail.js', 'scripts/ok.js'] } })],
      agentDir,
    );
    const data = contentOf(out).commandData as Array<{ source: string; output?: string; error?: string }>;
    expect(data[0].source).toBe('scripts/fail.js');
    expect(data[0].error).toContain('db locked');
    expect(data[0].output).toBeUndefined();
    expect(data[1].output).toContain('"readiness":72');
  });

  it('refuses anything but scripts/<name>.js under the agent dir', async () => {
    const [out] = await applyCommandData(
      [
        row({
          text: 'x',
          command: { name: 'evil', data: ['../escape.js', 'escape.js', '/etc/passwd', 'scripts/../escape.js'] },
        }),
      ],
      agentDir,
    );
    const data = contentOf(out).commandData as Array<{ error?: string; output?: string }>;
    expect(data).toHaveLength(4);
    for (const d of data) {
      expect(d.error).toContain('refused');
      expect(d.output).toBeUndefined();
    }
  });

  it('caps a huge output', async () => {
    const [out] = await applyCommandData(
      [row({ text: 'x', command: { name: 'big', data: ['scripts/big.js'] } })],
      agentDir,
    );
    const [d] = contentOf(out).commandData as Array<{ output: string }>;
    expect(d.output.length).toBeLessThan(17_000);
    expect(d.output).toContain('обрезано');
  });

  it('leaves rows without command data untouched', async () => {
    const plain = row({ text: 'привет' });
    const nameOnly = row({ text: 'Прогноз серфинга', command: { name: 'surf' } });
    const task = row({ prompt: 'p', command: { name: 'health', data: ['scripts/ok.js'] } }, 'task');
    const out = await applyCommandData([plain, nameOnly, task], agentDir);
    expect(out[0]).toBe(plain);
    expect(out[1]).toBe(nameOnly);
    expect(out[2]).toBe(task);
  });
});

describe('formatMessages with command data', () => {
  beforeEach(() => initTestSessionDb());
  afterEach(() => closeSessionDb());

  it('renders the output raw after the message text, and a failure as an error attribute', async () => {
    const [out] = await applyCommandData(
      [row({ text: 'Дай вывод', command: { name: 'money', data: ['scripts/ok.js', 'scripts/fail.js'] } })],
      agentDir,
    );
    const prompt = formatMessages([out]);
    expect(prompt).toContain('Дай вывод');
    // Raw JSON, not XML-escaped: quotes stay quotes.
    expect(prompt).toContain(`<command_data source="scripts/ok.js">\n{"readiness":72,`);
    expect(prompt).toContain('</command_data>');
    expect(prompt).toMatch(/<command_data source="scripts\/fail\.js" error="[^"]*db locked[^"]*"\/>/);
  });
});
