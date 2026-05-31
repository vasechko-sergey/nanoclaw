import { describe, it, expect } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AnyEnvelope } from './v2';

const here = dirname(fileURLToPath(import.meta.url));
const fixturesDir = join(here, 'fixtures');

const files = readdirSync(fixturesDir).filter(f => f.endsWith('.json'));

describe('shared/ios-app-protocol fixtures', () => {
  for (const f of files) {
    it(`${f} round-trips through AnyEnvelope`, () => {
      const raw = readFileSync(join(fixturesDir, f), 'utf8');
      const parsedJson = JSON.parse(raw);
      const env = AnyEnvelope.parse(parsedJson);
      const reParsed = AnyEnvelope.parse(JSON.parse(JSON.stringify(env)));
      expect(reParsed).toEqual(env);
    });
  }

  it('covers all 16 expected fixtures', () => {
    expect(files).toHaveLength(16);
  });
});
