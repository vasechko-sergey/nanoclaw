/**
 * Generate the shared groups/INSTRUCTIONS.md from the preamble + every
 * container/skills/*\/instructions.md + every
 * container/agent-runner/src/mcp-tools/*.instructions.md. Each agent dir
 * gets a sibling symlink so its CLAUDE.md can reference the file with
 * `@./INSTRUCTIONS.md`.
 *
 * The function is the only writer for groups/INSTRUCTIONS.md and refuses
 * to overwrite a file that doesn't begin with the generator marker — a
 * defensive guard against the operator silently losing hand-edits.
 */
import fs from 'fs';
import path from 'path';

import { GROUPS_DIR } from './config.js';
import { GENERATOR_MARKER, PREAMBLE } from './instructions-preamble.js';
import { log } from './log.js';

const DEFAULT_SKILLS_HOST_DIR = path.join('container', 'skills');
const DEFAULT_MCP_TOOLS_HOST_DIR = path.join('container', 'agent-runner', 'src', 'mcp-tools');

export interface GenOpts {
  groupsDir?: string;
  skillsDir?: string;
  mcpDir?: string;
}

export interface SymlinkOpts {
  groupsDir?: string;
}

function listSkillSections(skillsDir: string): Array<{ name: string; body: string }> {
  if (!fs.existsSync(skillsDir)) return [];
  const sections: Array<{ name: string; body: string }> = [];
  for (const name of fs.readdirSync(skillsDir).sort()) {
    const file = path.join(skillsDir, name, 'instructions.md');
    if (!fs.existsSync(file)) continue;
    try {
      const body = fs.readFileSync(file, 'utf8').trim();
      sections.push({ name, body });
    } catch (err) {
      log.warn('instructions-gen: skill instructions unreadable', { name, err: String(err) });
    }
  }
  return sections;
}

function listMcpSections(mcpDir: string): Array<{ name: string; body: string }> {
  if (!fs.existsSync(mcpDir)) return [];
  const sections: Array<{ name: string; body: string }> = [];
  for (const entry of fs.readdirSync(mcpDir).sort()) {
    const match = entry.match(/^(.+)\.instructions\.md$/);
    if (!match) continue;
    try {
      const body = fs.readFileSync(path.join(mcpDir, entry), 'utf8').trim();
      sections.push({ name: match[1], body });
    } catch (err) {
      log.warn('instructions-gen: mcp instructions unreadable', { entry, err: String(err) });
    }
  }
  return sections;
}

function compose(skills: Array<{ name: string; body: string }>, mcp: Array<{ name: string; body: string }>): string {
  const parts: string[] = [PREAMBLE.trimEnd(), ''];
  if (skills.length > 0) {
    parts.push('## Skills', '');
    for (const s of skills) {
      parts.push(`### ${s.name}`, '', s.body, '');
    }
  }
  if (mcp.length > 0) {
    parts.push('## MCP tools', '');
    for (const m of mcp) {
      parts.push(`### ${m.name}`, '', m.body, '');
    }
  }
  return parts.join('\n');
}

export function regenerateSharedInstructions(opts: GenOpts = {}): void {
  const groupsDir = opts.groupsDir ?? GROUPS_DIR;
  const skillsDir = opts.skillsDir ?? path.join(process.cwd(), DEFAULT_SKILLS_HOST_DIR);
  const mcpDir = opts.mcpDir ?? path.join(process.cwd(), DEFAULT_MCP_TOOLS_HOST_DIR);

  fs.mkdirSync(groupsDir, { recursive: true });

  const outPath = path.join(groupsDir, 'INSTRUCTIONS.md');
  if (fs.existsSync(outPath)) {
    const existing = fs.readFileSync(outPath, 'utf8');
    if (!existing.includes(GENERATOR_MARKER)) {
      throw new Error(
        `Refusing to overwrite hand-edited ${outPath}: file does not contain the generator marker. ` +
          'Move it aside (e.g. INSTRUCTIONS.md.bak) and re-run.',
      );
    }
  }

  const composed = compose(listSkillSections(skillsDir), listMcpSections(mcpDir));

  // Atomic write to avoid half-written file on crash.
  const tmp = `${outPath}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, composed);
  fs.renameSync(tmp, outPath);
}

export function ensureAgentInstructionsSymlink(folder: string, opts: SymlinkOpts = {}): void {
  const groupsDir = opts.groupsDir ?? GROUPS_DIR;
  const agentDir = path.join(groupsDir, folder);
  if (!fs.existsSync(agentDir)) {
    fs.mkdirSync(agentDir, { recursive: true });
  }
  const linkPath = path.join(agentDir, 'INSTRUCTIONS.md');
  let currentTarget: string | null = null;
  try {
    currentTarget = fs.readlinkSync(linkPath);
  } catch {
    /* missing or regular file */
  }
  if (currentTarget === '../INSTRUCTIONS.md') return;
  try {
    fs.unlinkSync(linkPath);
  } catch {
    /* missing */
  }
  fs.symlinkSync('../INSTRUCTIONS.md', linkPath);
}
