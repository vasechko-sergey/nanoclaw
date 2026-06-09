import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import path from 'path';
import os from 'os';
import fs from 'fs';

import { regenerateSharedInstructions, ensureAgentInstructionsCopy } from './instructions-gen.js';
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

describe('ensureAgentInstructionsCopy', () => {
  it('writes the shared INSTRUCTIONS.md content into the agent dir as a regular file', () => {
    fs.writeFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'), 'SHARED CONTENT');
    const agentDir = path.join(groupsDir, 'jarvis');
    fs.mkdirSync(agentDir);
    ensureAgentInstructionsCopy('jarvis', { groupsDir });
    const targetPath = path.join(agentDir, 'INSTRUCTIONS.md');
    expect(fs.lstatSync(targetPath).isFile()).toBe(true);
    expect(fs.readFileSync(targetPath, 'utf8')).toBe('SHARED CONTENT');
  });

  it('is idempotent — second call produces byte-identical content', () => {
    fs.writeFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'), 'V1');
    const agentDir = path.join(groupsDir, 'payne');
    fs.mkdirSync(agentDir);
    ensureAgentInstructionsCopy('payne', { groupsDir });
    const first = fs.readFileSync(path.join(agentDir, 'INSTRUCTIONS.md'));
    ensureAgentInstructionsCopy('payne', { groupsDir });
    const second = fs.readFileSync(path.join(agentDir, 'INSTRUCTIONS.md'));
    expect(Buffer.compare(first, second)).toBe(0);
  });

  it('replaces a stale symlink left over from the old design', () => {
    fs.writeFileSync(path.join(groupsDir, 'INSTRUCTIONS.md'), 'SHARED');
    const agentDir = path.join(groupsDir, 'greg');
    fs.mkdirSync(agentDir);
    fs.symlinkSync('elsewhere', path.join(agentDir, 'INSTRUCTIONS.md'));
    ensureAgentInstructionsCopy('greg', { groupsDir });
    const targetPath = path.join(agentDir, 'INSTRUCTIONS.md');
    expect(fs.lstatSync(targetPath).isFile()).toBe(true);
    expect(fs.lstatSync(targetPath).isSymbolicLink()).toBe(false);
  });

  it('is a no-op when groups/INSTRUCTIONS.md does not exist yet', () => {
    const agentDir = path.join(groupsDir, 'newbie');
    fs.mkdirSync(agentDir);
    expect(() => ensureAgentInstructionsCopy('newbie', { groupsDir })).not.toThrow();
    expect(fs.existsSync(path.join(agentDir, 'INSTRUCTIONS.md'))).toBe(false);
  });
});
