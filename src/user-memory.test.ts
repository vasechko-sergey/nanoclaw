import fs from 'fs';
import path from 'path';
import { describe, it, expect, afterEach } from 'vitest';
import { DATA_DIR } from './config.js';
import { userMemoryRoot, userGlobalRoot, initUserMemory } from './user-memory.js';

const KEY = 'test-person-xyz';

afterEach(() => {
  fs.rmSync(path.join(DATA_DIR, 'user-memory', KEY), { recursive: true, force: true });
});

describe('user-memory layout', () => {
  it('userMemoryRoot is data/user-memory/<key>/<folder>', () => {
    expect(userMemoryRoot(KEY, 'jarvis')).toBe(path.join(DATA_DIR, 'user-memory', KEY, 'jarvis'));
  });

  it('userGlobalRoot is data/user-memory/<key>/global', () => {
    expect(userGlobalRoot(KEY)).toBe(path.join(DATA_DIR, 'user-memory', KEY, 'global'));
  });

  it('initUserMemory creates memory subdirs, .claude, and global', () => {
    initUserMemory(KEY, 'jarvis');
    const root = userMemoryRoot(KEY, 'jarvis');
    for (const sub of ['memories', 'conversations', 'health', 'scratch', '.claude', '.claude/skills']) {
      expect(fs.existsSync(path.join(root, sub))).toBe(true);
    }
    expect(fs.existsSync(path.join(root, '.claude', 'settings.json'))).toBe(true);
    expect(fs.existsSync(path.join(userGlobalRoot(KEY), 'profiles'))).toBe(true);
  });

  it('initUserMemory is idempotent', () => {
    initUserMemory(KEY, 'jarvis');
    expect(() => initUserMemory(KEY, 'jarvis')).not.toThrow();
  });
});
