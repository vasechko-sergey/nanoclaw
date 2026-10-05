import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach } from 'bun:test';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { serveAgentCommands, servedNotesBlock } from './command-serve.js';
import { initTestSessionDb, closeSessionDb, getOutboundDb } from './db/connection.js';
import type { MessageInRow } from './db/messages-in.js';

let root: string;
let skillsDir: string;
let outboxDir: string;
let photo: string;

beforeAll(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), 'command-serve-')));
  skillsDir = join(root, 'skills');
  outboxDir = join(root, 'outbox');
  mkdirSync(join(skillsDir, 'surf-forecast'), { recursive: true });
  photo = join(root, 'surf.jpg');
  writeFileSync(photo, 'jpeg-bytes');
  const skill = (name: string, body: string) => writeFileSync(join(skillsDir, 'surf-forecast', name), body);
  skill(
    'ok.cjs',
    `console.log(JSON.stringify({ photo: ${JSON.stringify(photo)}, summary: 'Кангу, окно 06:00–09:00' }));`,
  );
  skill('fail.cjs', 'console.error("tides: HTTP 503"); process.exit(1);');
  skill('nothing.cjs', 'console.log(JSON.stringify({ summary: "no picture" }));');
  skill(
    'where.cjs',
    `console.log(JSON.stringify({ photo: ${JSON.stringify(photo)}, summary: 'at ' + process.env.DEVICE_LAT + ',' + process.env.DEVICE_LON }));`,
  );
  writeFileSync(join(root, 'escape.cjs'), 'require("fs").writeFileSync(process.argv[1] + ".ran", "x");');
});

afterAll(() => rmSync(root, { recursive: true, force: true }));
beforeEach(() => initTestSessionDb());
afterEach(() => closeSessionDb());

function row(content: object, id = `m-${Math.random().toString(36).slice(2, 8)}`): MessageInRow {
  return {
    id,
    seq: 2,
    kind: 'chat',
    timestamp: new Date().toISOString(),
    status: 'pending',
    process_after: null,
    recurrence: null,
    tries: 0,
    trigger: 1,
    platform_id: 'ios-app-v2:default',
    channel_type: 'ios-app-v2',
    thread_id: null,
    content: JSON.stringify(content),
    source_session_id: null,
  };
}

const surf = (serve: string) => ({
  text: 'Прогноз серфинга — сразу скилл surf-forecast.',
  command: { name: 'surf', serve },
});
const outbound = () =>
  getOutboundDb().prepare('SELECT id, kind, platform_id, channel_type, content FROM messages_out').all() as Array<{
    id: string;
    kind: string;
    platform_id: string;
    channel_type: string;
    content: string;
  }>;
const ackOf = (id: string) =>
  (
    getOutboundDb().prepare('SELECT status FROM processing_ack WHERE message_id = ?').get(id) as {
      status: string;
    } | null
  )?.status;

describe('serveAgentCommands', () => {
  it('runs the command script and sends its photo without a model turn', async () => {
    const r = row(surf('surf-forecast/ok.cjs'));
    const left = await serveAgentCommands([r], { skillsDir, outboxDir, cwd: root });
    expect(left).toEqual([]);
    expect(ackOf(r.id)).toBe('completed');

    const [sent] = outbound();
    expect(sent.kind).toBe('chat');
    expect(sent.platform_id).toBe('ios-app-v2:default'); // back where the command came from
    expect(JSON.parse(sent.content)).toEqual({ operation: 'send_photo', caption: '', files: ['surf.jpg'] });
    expect(readFileSync(join(outboxDir, sent.id, 'surf.jpg'), 'utf8')).toBe('jpeg-bytes');
  });

  it('tells the next model turn what went out, once', async () => {
    await serveAgentCommands([row(surf('surf-forecast/ok.cjs'))], { skillsDir, outboxDir, cwd: root });
    const block = servedNotesBlock();
    expect(block).toContain('<served command="/surf"');
    expect(block).toContain('Кангу, окно 06:00–09:00');
    expect(servedNotesBlock()).toBe('');
  });

  it("passes the phone's position from the command message to the script", async () => {
    const r = row({
      ...surf('surf-forecast/where.cjs'),
      ios_context: { location: { lat: -8.667, lon: 115.1394 }, locality: 'Canggu' },
    });
    await serveAgentCommands([r], { skillsDir, outboxDir, cwd: root });
    expect(servedNotesBlock()).toContain('at -8.667,115.1394');
    // No position in the message → none in the environment either.
    await serveAgentCommands([row(surf('surf-forecast/where.cjs'))], { skillsDir, outboxDir, cwd: root });
    expect(servedNotesBlock()).toContain('at undefined,undefined');
  });

  it('hands the row to the model when the script fails', async () => {
    const r = row(surf('surf-forecast/fail.cjs'));
    const left = await serveAgentCommands([r], { skillsDir, outboxDir, cwd: root });
    expect(left).toEqual([r]);
    expect(outbound()).toEqual([]);
    expect(ackOf(r.id)).toBeUndefined();
  });

  it('hands the row to the model when the script makes no picture or text', async () => {
    const r = row(surf('surf-forecast/nothing.cjs'));
    expect(await serveAgentCommands([r], { skillsDir, outboxDir, cwd: root })).toEqual([r]);
    expect(outbound()).toEqual([]);
  });

  it('runs only <skill>/<name>.cjs inside the skills dir', async () => {
    const rows = ['../escape.cjs', '/etc/passwd', 'surf-forecast/../../escape.cjs', 'surf-forecast/ok.js'].map((s) =>
      row(surf(s)),
    );
    expect(await serveAgentCommands(rows, { skillsDir, outboxDir, cwd: root })).toEqual(rows);
    expect(existsSync(join(root, 'escape.cjs.ran'))).toBe(false);
    expect(outbound()).toEqual([]);
  });

  it('leaves everything else alone', async () => {
    const plain = row({ text: 'привет' });
    const dataOnly = row({ text: 'вывод', command: { name: 'health', data: ['scripts/analyze.js'] } });
    const left = await serveAgentCommands([plain, dataOnly], { skillsDir, outboxDir, cwd: root });
    expect(left[0]).toBe(plain);
    expect(left[1]).toBe(dataOnly);
  });
});
