export interface RenderOpts {
  endpoint?: string; // default from env JARVIS_TTS_URL
  timeoutMs?: number; // default 240000 (CPU render is slow)
  fetchImpl?: typeof fetch;
  /** Output codec/container. 'opus' (ogg, Telegram voice notes) is the default;
   *  'm4a' (aac) for iOS — AVAudioPlayer can't decode OGG/Opus but plays AAC. */
  format?: 'opus' | 'm4a';
}

export async function renderVoice(text: string, voice = 'jarvis', opts: RenderOpts = {}): Promise<Buffer | null> {
  const endpoint = opts.endpoint ?? process.env.JARVIS_TTS_URL ?? 'http://127.0.0.1:8099/tts';
  const timeoutMs = opts.timeoutMs ?? 240_000;
  const doFetch = opts.fetchImpl ?? fetch;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await doFetch(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text, voice, fmt: opts.format ?? 'opus' }),
      signal: ctrl.signal,
    });
    if (!res.ok) {
      console.error(`[voice] tts ${res.status}`);
      return null;
    }
    return Buffer.from(await res.arrayBuffer());
  } catch (e) {
    console.error('[voice] tts call failed', e);
    return null;
  } finally {
    clearTimeout(timer);
  }
}
