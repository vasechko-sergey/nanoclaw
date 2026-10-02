import fs from 'fs';
import os from 'os';
import path from 'path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { persistHealthSignal } from './health-signal-file.js';

let root: string;
const file = () => path.join(root, 'health', 'signal.json');
const a2a = (signal: unknown, kind = 'health_signal') =>
  JSON.stringify({
    text: typeof signal === 'string' ? signal : JSON.stringify(signal),
    a2a_kind: kind,
    sender: 'Greg',
    senderId: 'greg',
  });

beforeEach(() => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'shared-'));
});
afterEach(() => {
  fs.rmSync(root, { recursive: true, force: true });
});

describe('persistHealthSignal', () => {
  it("keeps Greg's signal as structured JSON, stamped with when and from whom", () => {
    const at = new Date('2026-10-02T01:16:00.000Z');
    const wrote = persistHealthSignal(
      a2a({ date: '2026-10-02', level: 'yellow', readiness: 55, factors: ['low_hrv'], recommendation: 'полегче' }),
      root,
      at,
    );
    expect(wrote).toBe(true);
    expect(JSON.parse(fs.readFileSync(file(), 'utf8'))).toEqual({
      date: '2026-10-02',
      level: 'yellow',
      readiness: 55,
      factors: ['low_hrv'],
      recommendation: 'полегче',
      received_at: '2026-10-02T01:16:00.000Z',
      from: 'greg',
    });
  });

  it('a later signal replaces the earlier one (Greg retracts a yellow → green)', () => {
    persistHealthSignal(a2a({ date: '2026-09-18', level: 'yellow', readiness: 61 }), root);
    persistHealthSignal(a2a({ date: '2026-09-18', level: 'green', readiness: 74 }), root);
    expect(JSON.parse(fs.readFileSync(file(), 'utf8'))).toMatchObject({ level: 'green', readiness: 74 });
  });

  it('ignores every other a2a kind', () => {
    expect(persistHealthSignal(a2a({ date: '2026-10-02', level: 'red' }, 'workout_summary'), root)).toBe(false);
    expect(fs.existsSync(file())).toBe(false);
  });

  it('a malformed signal never overwrites the last good one', () => {
    persistHealthSignal(a2a({ date: '2026-10-02', level: 'yellow', readiness: 55 }), root);
    expect(persistHealthSignal(a2a('not json'), root)).toBe(false);
    expect(persistHealthSignal(a2a({ date: '2 Oct', level: 'yellow' }), root)).toBe(false);
    expect(persistHealthSignal(a2a({ date: '2026-10-02', level: 'orange' }), root)).toBe(false);
    expect(JSON.parse(fs.readFileSync(file(), 'utf8'))).toMatchObject({ level: 'yellow', readiness: 55 });
  });

  it('non-JSON content is not a signal', () => {
    expect(persistHealthSignal('plain text', root)).toBe(false);
  });
});
