export interface DecideVoiceInput {
  isFinalUserReply: boolean;
  voiceIntent: boolean;
  /** Hold the text behind a placeholder until the audio is ready (voice-only mode). */
  voiceOnly: boolean;
  hasText: boolean;
  /** Agent group folder. Voice name == folder (1:1); the sidecar 400s for an
   *  unregistered voice and renderVoice returns null → graceful skip. */
  folder: string;
}

export interface DecideVoiceResult {
  shouldRender: boolean;
  voice: string;
  /** True when the client should hide the text until the audio lands. */
  holdText: boolean;
}

export function decideVoice(input: DecideVoiceInput): DecideVoiceResult {
  const shouldRender = input.isFinalUserReply && input.voiceIntent && input.hasText;
  return {
    shouldRender,
    voice: input.folder,
    holdText: shouldRender && input.voiceOnly,
  };
}
