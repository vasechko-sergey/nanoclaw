import fs from 'fs';
import path from 'path';
import { describe, it, expect, afterEach } from 'vitest';
import { DATA_DIR } from './config.js';
import { userMemoryRoot, userGlobalRoot, userSharedRoot, initUserMemory } from './user-memory.js';

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

  it('userSharedRoot is data/user-memory/<key>/shared', () => {
    expect(userSharedRoot(KEY)).toBe(path.join(DATA_DIR, 'user-memory', KEY, 'shared'));
  });

  it('initUserMemory scaffolds the shared wiki: blocks, README, log', () => {
    initUserMemory(KEY, 'jarvis');
    const shared = userSharedRoot(KEY);
    for (const block of ['nutrition', 'training', 'health', 'finance', 'general']) {
      expect(fs.existsSync(path.join(shared, block))).toBe(true);
    }
    expect(fs.existsSync(path.join(shared, 'README.md'))).toBe(true);
    expect(fs.existsSync(path.join(shared, 'log.md'))).toBe(true);
  });

  it('initUserMemory never clobbers an existing shared log.md', () => {
    initUserMemory(KEY, 'jarvis');
    const log = path.join(userSharedRoot(KEY), 'log.md');
    fs.appendFileSync(log, '## [2026-06-26] greg health | test entry\n');
    initUserMemory(KEY, 'gordon'); // second agent, same person → re-scaffold
    expect(fs.readFileSync(log, 'utf8')).toContain('test entry');
  });

  it('initUserMemory never clobbers an existing shared README.md', () => {
    initUserMemory(KEY, 'jarvis');
    const readme = path.join(userSharedRoot(KEY), 'README.md');
    fs.writeFileSync(readme, '# custom block map\n');
    initUserMemory(KEY, 'gordon'); // re-scaffold must preserve a hand-edited README
    expect(fs.readFileSync(readme, 'utf8')).toBe('# custom block map\n');
  });
});
