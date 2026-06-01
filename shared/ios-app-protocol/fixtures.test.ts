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

  it('covers all 17 expected envelope fixtures', () => {
    expect(envelopeFiles).toHaveLength(17);
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
});
