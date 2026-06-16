export interface IntentInput {
  iosContext: { respond_by_voice?: boolean } | null;
  groupVoiceMode: boolean;
}
export function resolveVoiceIntent(input: IntentInput): boolean {
  if (input.iosContext?.respond_by_voice === true) return true;
  return input.groupVoiceMode === true;
}
