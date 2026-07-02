import { describe, it, expect, afterEach } from 'vitest';
import fs from 'fs';
import path from 'path';

import { AGENTS_DIR } from './config.js';
import { scaffoldAgentCode } from './group-init.js';

// scaffoldAgentCode seeds a NEW agent's shared CODE root (agents/<folder>/) so the
// container's shared-code mount model has CLAUDE.md + skills/ + scripts/ to mount.
// Replaces the old "write CLAUDE.md into groups/<folder> and let cpSync copy it".

const FOLDER = 'test-scaffold-agent';
const agentRoot = path.join(AGENTS_DIR, FOLDER);

afterEach(() => {
  fs.rmSync(agentRoot, { recursive: true, force: true });
});

it('scaffolds agents/<folder>/CLAUDE.md (with INSTRUCTIONS import + persona) + skills/ + scripts/', () => {
  scaffoldAgentCode({ folder: FOLDER, name: 'Testy' }, 'You are Testy, a test agent.');
  const claude = fs.readFileSync(path.join(agentRoot, 'CLAUDE.md'), 'utf-8');
  expect(claude.startsWith('@./INSTRUCTIONS.md')).toBe(true);
  expect(claude).toContain('You are Testy, a test agent.');
  expect(fs.statSync(path.join(agentRoot, 'skills')).isDirectory()).toBe(true);
  expect(fs.statSync(path.join(agentRoot, 'scripts')).isDirectory()).toBe(true);
});

it('falls back to "# <name>" persona when no instructions given', () => {
  scaffoldAgentCode({ folder: FOLDER, name: 'Testy' }, null);
  const claude = fs.readFileSync(path.join(agentRoot, 'CLAUDE.md'), 'utf-8');
  expect(claude).toBe('@./INSTRUCTIONS.md\n\n# Testy\n');
});

it('is idempotent: does not overwrite an existing CLAUDE.md (agent self-edits survive)', () => {
  fs.mkdirSync(agentRoot, { recursive: true });
  fs.writeFileSync(path.join(agentRoot, 'CLAUDE.md'), 'CUSTOM EDITED PERSONA');
  scaffoldAgentCode({ folder: FOLDER, name: 'Testy' }, 'ignored');
  expect(fs.readFileSync(path.join(agentRoot, 'CLAUDE.md'), 'utf-8')).toBe('CUSTOM EDITED PERSONA');
  // but the code dirs are still ensured
  expect(fs.existsSync(path.join(agentRoot, 'skills'))).toBe(true);
});
