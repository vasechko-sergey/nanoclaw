export interface IntentInput {
  iosContext: { respond_by_voice?: boolean } | null;
  groupVoiceMode: boolean;
}
export function resolveVoiceIntent(input: IntentInput): boolean {
  if (input.iosContext?.respond_by_voice === true) return true;
  return input.groupVoiceMode === true;
}

export function resolveVoiceOnly(iosContext: { voice_only?: boolean } | null): boolean {
  return iosContext?.voice_only === true;
}
