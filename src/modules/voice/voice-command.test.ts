import { describe, it, expect } from 'vitest';
import { parseVoiceCommand } from './voice-command.js';

describe('parseVoiceCommand', () => {
  it('parses on/off', () => {
    expect(parseVoiceCommand('/voice on')).toEqual({ isCommand: true, enable: true });
    expect(parseVoiceCommand('/voice off')).toEqual({ isCommand: true, enable: false });
  });
  it('ignores non-commands', () => {
    expect(parseVoiceCommand('привет')).toEqual({ isCommand: false });
  });
});
