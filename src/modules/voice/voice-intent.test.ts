import { describe, it, expect } from 'vitest';
import { resolveVoiceIntent } from './voice-intent';

describe('resolveVoiceIntent', () => {
  it('true when iOS context requests voice', () => {
    expect(resolveVoiceIntent({ iosContext: { respond_by_voice: true }, groupVoiceMode: false })).toBe(true);
  });
  it('true when group voice_mode on (e.g. Telegram /voice)', () => {
    expect(resolveVoiceIntent({ iosContext: null, groupVoiceMode: true })).toBe(true);
  });
  it('false by default (never spam voice)', () => {
    expect(resolveVoiceIntent({ iosContext: { respond_by_voice: false }, groupVoiceMode: false })).toBe(false);
    expect(resolveVoiceIntent({ iosContext: null, groupVoiceMode: false })).toBe(false);
  });
});
