import { describe, it, expect, beforeEach, afterEach } from 'bun:test';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { resolveExerciseImagePath, buildImageManifest, IMAGE_EXTS } from './exercise-images.js';

describe('exercise-images', () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'eximg-'));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('resolves the first existing asset honoring .gif > .jpg > .png priority', () => {
    writeFileSync(join(dir, 'ex.jpg'), Buffer.from('JPG'));
    writeFileSync(join(dir, 'ex.png'), Buffer.from('PNG'));
    // no .gif yet → .jpg wins over .png
    expect(resolveExerciseImagePath('ex', dir)).toBe(join(dir, 'ex.jpg'));
    // add .gif → .gif wins (animated asset preferred, matching the responder)
    writeFileSync(join(dir, 'ex.gif'), Buffer.from('GIF'));
    expect(resolveExerciseImagePath('ex', dir)).toBe(join(dir, 'ex.gif'));
  });

  it('resolves to null for a missing asset or empty slug', () => {
    expect(resolveExerciseImagePath('nope', dir)).toBeNull();
    expect(resolveExerciseImagePath('', dir)).toBeNull();
  });

  it('exposes the same extension priority the image_blob responder uses', () => {
    expect([...IMAGE_EXTS]).toEqual(['.gif', '.jpg', '.png']);
  });

  it('builds a manifest whose sha256 matches the raw-bytes hash the responder serves', () => {
    const bytes = Buffer.from('BENCHPRESSIMAGE');
    writeFileSync(join(dir, 'zhim.jpg'), bytes);
    const manifest = buildImageManifest(['zhim'], dir);
    expect(manifest).toEqual([
      { slug: 'zhim', sha256: createHash('sha256').update(bytes).digest('hex') },
    ]);
  });

  it('skips slugs with no on-disk asset (iOS keeps its placeholder)', () => {
    writeFileSync(join(dir, 'zhim.jpg'), Buffer.from('X'));
    // 'hodba' (cardio warmup) has no image → dropped, not an empty/failed entry.
    const manifest = buildImageManifest(['hodba', 'zhim'], dir);
    expect(manifest.map((m) => m.slug)).toEqual(['zhim']);
  });

  it('de-dupes repeated slugs', () => {
    writeFileSync(join(dir, 'zhim.jpg'), Buffer.from('X'));
    const manifest = buildImageManifest(['zhim', 'zhim'], dir);
    expect(manifest).toHaveLength(1);
  });

  it('drops empty slugs without touching the filesystem', () => {
    expect(buildImageManifest(['', ''], dir)).toEqual([]);
  });
});
