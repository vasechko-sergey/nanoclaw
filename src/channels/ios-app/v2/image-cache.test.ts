import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ImageCache } from './image-cache.js';

let dir: string;
let cache: ImageCache;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'img-cache-'));
  cache = new ImageCache(dir);
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe('ImageCache', () => {
  it('write then read roundtrips the bytes', () => {
    const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
    cache.write('incline-db-press', 'abc123', bytes);
    expect(cache.has('incline-db-press', 'abc123')).toBe(true);
    expect(cache.read('incline-db-press', 'abc123')?.equals(bytes)).toBe(true);
  });

  it('has() is false before write and read() returns null', () => {
    expect(cache.has('missing', 'sha')).toBe(false);
    expect(cache.read('missing', 'sha')).toBeNull();
  });

  it('write is idempotent for the same slug+sha', () => {
    const bytes = Buffer.from('hello');
    cache.write('s', 'h', bytes);
    cache.write('s', 'h', bytes);
    expect(cache.read('s', 'h')?.toString()).toBe('hello');
  });

  it('path is pinned to slug + sha (versioning by sha)', () => {
    cache.write('s', 'v1', Buffer.from('one'));
    cache.write('s', 'v2', Buffer.from('two'));
    expect(cache.read('s', 'v1')?.toString()).toBe('one');
    expect(cache.read('s', 'v2')?.toString()).toBe('two');
  });

  it('rejects path-traversal in slug (write throws, file stays inside baseDir)', () => {
    expect(() => cache.write('../../etc/passwd', 'sha', Buffer.from('x'))).toThrow();
    expect(existsSync(join(dir, '..', '..', 'etc', 'passwd'))).toBe(false);
  });

  it('rejects path-traversal in sha and slashes anywhere', () => {
    expect(() => cache.write('s', '../escape', Buffer.from('x'))).toThrow();
    expect(() => cache.write('a/b', 'sha', Buffer.from('x'))).toThrow();
    // read/has on a malformed key are safe no-ops, not throws or escapes.
    expect(cache.has('..', '..')).toBe(false);
    expect(cache.read('..', '..')).toBeNull();
  });
});
