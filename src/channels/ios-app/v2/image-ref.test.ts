import { describe, it, expect, beforeEach, afterEach, vi, type Mock } from 'vitest';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ImageCache } from './image-cache.js';
import { convertImageBlobToRef } from './image-ref.js';

let dir: string;
let cache: ImageCache;
let warn: Mock<(msg: string, ctx?: Record<string, unknown>) => void>;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'img-ref-'));
  cache = new ImageCache(dir);
  warn = vi.fn<(msg: string, ctx?: Record<string, unknown>) => void>();
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const blob = (over: Record<string, unknown> = {}) => ({
  id: 'env-1',
  kind: 'control',
  type: 'image_blob',
  payload: {
    slug: 'incline-db-press',
    sha256: 'abc123',
    base64: Buffer.from('PNGDATA').toString('base64'),
    agent_id: 'payne',
    ...over,
  },
});

describe('convertImageBlobToRef', () => {
  it('ref-capable device: rewrites to image_ready and caches the bytes', () => {
    const out = convertImageBlobToRef(blob(), true, cache, warn);
    expect(out.type).toBe('image_ready');
    expect(out.id).toBe('env-1'); // id preserved so device dedup is stable
    expect(out.payload).toEqual({ slug: 'incline-db-press', sha256: 'abc123', agent_id: 'payne' });
    expect((out.payload as Record<string, unknown>).base64).toBeUndefined();
    expect(cache.read('incline-db-press', 'abc123')?.toString()).toBe('PNGDATA');
    expect(warn).not.toHaveBeenCalled();
  });

  it('omits agent_id when the blob had none', () => {
    const out = convertImageBlobToRef(blob({ agent_id: undefined }), true, cache, warn);
    expect(out.type).toBe('image_ready');
    expect((out.payload as Record<string, unknown>).agent_id).toBeUndefined();
  });

  it('non-ref-capable device: leaves the image_blob untouched (old path)', () => {
    const input = blob();
    const out = convertImageBlobToRef(input, false, cache, warn);
    expect(out).toBe(input);
    expect(out.type).toBe('image_blob');
    expect(cache.has('incline-db-press', 'abc123')).toBe(false);
  });

  it('non-image envelope: returned unchanged even for ref-capable device', () => {
    const msg = { id: 'm', kind: 'data', type: 'message', payload: { text: 'hi' } };
    expect(convertImageBlobToRef(msg, true, cache, warn)).toBe(msg);
  });

  it('malformed base64 / missing fields: falls back to the original blob and warns', () => {
    const bad = { id: 'b', kind: 'control', type: 'image_blob', payload: { slug: 's', sha256: 'h' } };
    const out = convertImageBlobToRef(bad, true, cache, warn);
    expect(out).toBe(bad); // unchanged → device still gets the blob path
    expect(cache.has('s', 'h')).toBe(false);
    expect(warn).toHaveBeenCalled();
  });
});
