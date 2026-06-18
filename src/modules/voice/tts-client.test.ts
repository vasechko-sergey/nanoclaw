import { describe, it, expect, vi } from 'vitest';
import { renderVoice } from './tts-client.js';

describe('renderVoice', () => {
  it('returns a Buffer of opus bytes on 200', async () => {
    const fetchMock = vi.fn(async () => new Response(new Blob([new Uint8Array([79, 103, 103, 83])]), { status: 200 }));
    const buf = await renderVoice('Привет', 'jarvis', {
      endpoint: 'http://x/tts',
      fetchImpl: fetchMock as any,
      timeoutMs: 1000,
    });
    expect(buf?.subarray(0, 4).toString('binary')).toBe('OggS');
  });

  it('returns null on non-200 (never throws into delivery)', async () => {
    const fetchMock = vi.fn(async () => new Response('boom', { status: 500 }));
    const buf = await renderVoice('x', 'jarvis', {
      endpoint: 'http://x/tts',
      fetchImpl: fetchMock as any,
      timeoutMs: 1000,
    });
    expect(buf).toBeNull();
  });

  it('returns null on timeout/throw', async () => {
    const fetchMock = vi.fn(async () => {
      throw new Error('network');
    });
    const buf = await renderVoice('x', 'jarvis', {
      endpoint: 'http://x/tts',
      fetchImpl: fetchMock as any,
      timeoutMs: 1000,
    });
    expect(buf).toBeNull();
  });
});
