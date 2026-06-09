import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import path from 'path';
import os from 'os';
import fs from 'fs';

import { regenerateSharedInstructions, ensureAgentInstructionsSymlink } from './instructions-gen.js';
import { GENERATOR_MARKER } from './instructions-preamble.js';

let tmp: string;
let groupsDir: string;
let skillsDir: string;
let mcpDir: string;

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'instr-gen-'));
  groupsDir = path.join(tmp, 'groups');
  skillsDir = path.join(tmp, 'container', 'skills');
  mcpDir = path.join(tmp, 'container', 'agent-runner', 'src', 'mcp-tools');
  fs.mkdirSync(groupsDir, { recursive: true });
  fs.mkdirSync(skillsDir, { recursive: true });
  fs.mkdirSync(mcpDir, { recursive: true });
});

afterEach(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
});

describe('regenerateSharedInstructions', () => {
  it('writes a file that contains the generator marker', () => {
    regenerateSharedInstructions({ groupsDir, skillsDir, mcpDir });
    const out = fs.readFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'), 'utf8');
    expect(out).toContain(GENERATOR_MARKER);
  });

  it('includes a section for each skill that ships instructions.md', () => {
    fs.mkdirSync(path.join(skillsDir, 'welcome'));
    fs.writeFileSync(path.join(skillsDir, 'welcome', 'instructions.md'), 'welcome-body');
    fs.mkdirSync(path.join(skillsDir, 'slack-formatting'));
    fs.writeFileSync(path.join(skillsDir, 'slack-formatting', 'instructions.md'), 'slack-body');

    regenerateSharedInstructions({ groupsDir, skillsDir, mcpDir });
    const out = fs.readFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'), 'utf8');
    expect(out).toContain('### welcome');
    expect(out).toContain('welcome-body');
    expect(out).toContain('### slack-formatting');
    expect(out).toContain('slack-body');
  });

  it('includes a section for each MCP tool module that ships *.instructions.md', () => {
    fs.writeFileSync(path.join(mcpDir, 'workout.instructions.md'), 'workout-body');
    fs.writeFileSync(path.join(mcpDir, 'scheduling.instructions.md'), 'sched-body');

    regenerateSharedInstructions({ groupsDir, skillsDir, mcpDir });
    const out = fs.readFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'), 'utf8');
    expect(out).toContain('### workout');
    expect(out).toContain('workout-body');
    expect(out).toContain('### scheduling');
    expect(out).toContain('sched-body');
  });

  it('skips skills that ship no instructions.md', () => {
    fs.mkdirSync(path.join(skillsDir, 'no-instructions'));
    regenerateSharedInstructions({ groupsDir, skillsDir, mcpDir });
    const out = fs.readFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'), 'utf8');
    expect(out).not.toContain('### no-instructions');
  });

  it('produces deterministic output on repeated calls (byte-identical)', () => {
    fs.writeFileSync(path.join(mcpDir, 'workout.instructions.md'), 'workout-body');
    regenerateSharedInstructions({ groupsDir, skillsDir, mcpDir });
    const first = fs.readFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'));
    regenerateSharedInstructions({ groupsDir, skillsDir, mcpDir });
    const second = fs.readFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'));
    expect(Buffer.compare(first, second)).toBe(0);
  });

  it('refuses to overwrite an INSTRUCTIONS.md without the generator marker', () => {
    fs.writeFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'), 'hand-edited content');
    expect(() => regenerateSharedInstructions({ groupsDir, skillsDir, mcpDir })).toThrow(/hand-edited/);
    const out = fs.readFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'), 'utf8');
    expect(out).toBe('hand-edited content');
  });
});

describe('ensureAgentInstructionsSymlink', () => {
  it('creates a symlink to ../INSTRUCTIONS.md in the agent dir', () => {
    const agentDir = path.join(groupsDir, 'jarvis');
    fs.mkdirSync(agentDir);
    ensureAgentInstructionsSymlink('jarvis', { groupsDir });
    const linkPath = path.join(agentDir, 'INSTRUCTIONS.md');
    const target = fs.readlinkSync(linkPath);
    expect(target).toBe('../INSTRUCTIONS.md');
  });

  it('is idempotent — second call leaves the symlink unchanged', () => {
    const agentDir = path.join(groupsDir, 'payne');
    fs.mkdirSync(agentDir);
    ensureAgentInstructionsSymlink('payne', { groupsDir });
    const before = fs.lstatSync(path.join(agentDir, 'INSTRUCTIONS.md')).mtimeMs;
    ensureAgentInstructionsSymlink('payne', { groupsDir });
    const after = fs.lstatSync(path.join(agentDir, 'INSTRUCTIONS.md')).mtimeMs;
    expect(after).toBe(before);
  });

  it('replaces a stale symlink pointing somewhere else', () => {
    const agentDir = path.join(groupsDir, 'greg');
    fs.mkdirSync(agentDir);
    fs.symlinkSync('elsewhere', path.join(agentDir, 'INSTRUCTIONS.md'));
    ensureAgentInstructionsSymlink('greg', { groupsDir });
    expect(fs.readlinkSync(path.join(agentDir, 'INSTRUCTIONS.md'))).toBe('../INSTRUCTIONS.md');
  });
});
