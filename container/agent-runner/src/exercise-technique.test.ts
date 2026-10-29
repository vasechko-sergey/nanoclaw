import { describe, it, expect, beforeEach, afterEach } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readTechnique } from './exercise-technique.js';

describe('readTechnique', () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'technique-')); });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('reads steps and warnings from the card', () => {
    writeFileSync(join(dir, 'zhim.json'), JSON.stringify({
      rules: [{ text: 'Жим', description: 'На выдохе.' }, { text: ' ', description: '' }],
      warnings: [{ text: 'Колени не блокировать.' }],
    }));
    expect(readTechnique(dir, 'zhim')).toEqual({
      steps: [{ title: 'Жим', text: 'На выдохе.' }],
      warnings: ['Колени не блокировать.'],
    });
  });

  it('is undefined for no card, a broken card, or an empty one', () => {
    expect(readTechnique(dir, 'missing')).toBeUndefined();
    writeFileSync(join(dir, 'broken.json'), '{');
    expect(readTechnique(dir, 'broken')).toBeUndefined();
    writeFileSync(join(dir, 'empty.json'), JSON.stringify({ rules: [], warnings: [] }));
    expect(readTechnique(dir, 'empty')).toBeUndefined();
  });

  it('refuses a slug that walks out of the directory', () => {
    expect(readTechnique(dir, '../etc/passwd')).toBeUndefined();
  });
});
