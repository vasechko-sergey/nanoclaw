export type VoiceCommand = { isCommand: true; enable: boolean } | { isCommand: false };

export function parseVoiceCommand(text: string): VoiceCommand {
  const m = text.trim().match(/^\/voice\s+(on|off)\b/i);
  if (!m) return { isCommand: false };
  return { isCommand: true, enable: m[1].toLowerCase() === 'on' };
}
