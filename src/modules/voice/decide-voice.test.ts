import { describe, it, expect } from 'vitest';
import { decideVoice } from './decide-voice.js';

describe('decideVoice', () => {
  it('renders the folder-named voice for a final voice reply', () => {
    const d = decideVoice({
      isFinalUserReply: true,
      voiceIntent: true,
      voiceOnly: false,
      hasText: true,
      folder: 'greg',
    });
    expect(d).toEqual({ shouldRender: true, voice: 'greg', holdText: false });
  });
  it('holdText is true only when voiceOnly is set', () => {
    const d = decideVoice({
      isFinalUserReply: true,
      voiceIntent: true,
      voiceOnly: true,
      hasText: true,
      folder: 'jarvis',
    });
    expect(d).toEqual({ shouldRender: true, voice: 'jarvis', holdText: true });
  });
  it('no render when not the final reply', () => {
    expect(
      decideVoice({ isFinalUserReply: false, voiceIntent: true, voiceOnly: true, hasText: true, folder: 'jarvis' })
        .shouldRender,
    ).toBe(false);
  });
  it('no render without voice intent', () => {
    expect(
      decideVoice({ isFinalUserReply: true, voiceIntent: false, voiceOnly: false, hasText: true, folder: 'jarvis' })
        .shouldRender,
    ).toBe(false);
  });
  it('no render without text', () => {
    expect(
      decideVoice({ isFinalUserReply: true, voiceIntent: true, voiceOnly: false, hasText: false, folder: 'jarvis' })
        .shouldRender,
    ).toBe(false);
  });
  it('holdText is false when nothing renders even if voiceOnly set', () => {
    expect(
      decideVoice({ isFinalUserReply: false, voiceIntent: true, voiceOnly: true, hasText: true, folder: 'jarvis' })
        .holdText,
    ).toBe(false);
  });
});
