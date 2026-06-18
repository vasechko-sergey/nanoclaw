import { describe, it, expect } from 'vitest';
import { resolveVoiceIntent } from './voice-intent.js';

// Exact stored inbound content from the ios jarvis session (2026-06-18 07:15:52),
// the message that produced voice_intent=0 in prod.
const REAL_CONTENT =
  '{"text":"Проверка звучки голосом","senderId":"ios-app-v2:default","ios_context":{"location":{"lat":-8.6526,"lon":115.1376},"timestamp":"2026-06-18T07:15:52Z","timezone":"Asia/Makassar","respond_by_voice":true},"attachments":[]}';

// Replicate the router voice-intent block from src/router.ts deliverToAgent verbatim.
function routerComputeVoiceIntent(content: string, groupVoiceMode: boolean): boolean {
  let parsedContent: { ios_context?: { respond_by_voice?: boolean } | null } = {};
  try {
    parsedContent = JSON.parse(content);
  } catch {
    /* non-JSON */
  }
  const iosContext = parsedContent.ios_context ?? null;
  return resolveVoiceIntent({ iosContext, groupVoiceMode });
}

describe('router voice-intent on the real prod message', () => {
  it('computes voice intent = true from respond_by_voice in the stored content', () => {
    expect(routerComputeVoiceIntent(REAL_CONTENT, false)).toBe(true);
  });
  it('false when ios_context absent (typed message)', () => {
    expect(routerComputeVoiceIntent('{"text":"hi","attachments":[]}', false)).toBe(false);
  });
});
