import { describe, it, expect } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AnyEnvelope, HealthUploadBody } from './v2';

const here = dirname(fileURLToPath(import.meta.url));
const fixturesDir = join(here, 'fixtures');

const envelopeFiles = readdirSync(fixturesDir).filter((f) => f.endsWith('.json'));
const healthFiles = readdirSync(join(fixturesDir, 'health')).filter((f) => f.endsWith('.json'));

describe('shared/ios-app-protocol envelope fixtures', () => {
  for (const f of envelopeFiles) {
    it(`${f} round-trips through AnyEnvelope`, () => {
      const raw = readFileSync(join(fixturesDir, f), 'utf8');
      const parsedJson = JSON.parse(raw);
      const env = AnyEnvelope.parse(parsedJson);
      const reParsed = AnyEnvelope.parse(JSON.parse(JSON.stringify(env)));
      expect(reParsed).toEqual(env);
    });
  }

  it('covers all 24 expected envelope fixtures', () => {
    expect(envelopeFiles).toHaveLength(24);
  });

  it('message_with_agent_id.json preserves agent_id through round-trip', () => {
    const raw = readFileSync(join(fixturesDir, 'message_with_agent_id.json'), 'utf8');
    const env = AnyEnvelope.parse(JSON.parse(raw));
    if (env.type !== 'message') throw new Error('expected message');
    expect(env.payload.agent_id).toBe('payne');
  });
});

describe('shared/ios-app-protocol health-upload fixtures', () => {
  for (const f of healthFiles) {
    it(`health/${f} round-trips through HealthUploadBody`, () => {
      const raw = readFileSync(join(fixturesDir, 'health', f), 'utf8');
      const parsedJson = JSON.parse(raw);
      const body = HealthUploadBody.parse(parsedJson);
      const reParsed = HealthUploadBody.parse(JSON.parse(JSON.stringify(body)));
      expect(reParsed).toEqual(body);
    });
  }

  it('upload_sensors.json preserves sleep-phase / morning-HRV / SpO2 fields', () => {
    const raw = readFileSync(join(fixturesDir, 'health', 'upload_sensors.json'), 'utf8');
    const body = HealthUploadBody.parse(JSON.parse(raw));
    const d = body.days[0];
    expect(d.deepMin).toBe(62);
    expect(d.remMin).toBe(95);
    expect(d.awakeMin).toBe(18);
    expect(d.coreMin).toBe(275);
    expect(d.sleepOnsetMin).toBe(-42);
    expect(d.hrvMorning).toBe(58);
    expect(d.spo2Avg).toBe(96.4);
    expect(d.spo2Min).toBe(91.0);
    expect(d.bodyMass).toBe(78.4);
    expect(d.height).toBe(1.82);
    expect(d.bodyFatPercentage).toBe(18.5);
    expect(d.leanBodyMass).toBe(63.9);
  });
});
