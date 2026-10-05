/**
 * Host-side command gate. Classifies inbound slash commands and gates
 * them before they reach the container.
 *
 * - Filtered commands: dropped silently (never reach the container)
 * - Admin commands: checked against user_roles; denied senders get a
 *   "Permission denied" response written directly to messages_out
 * - An agent's own command (src/commands.ts): swapped for its prompt
 * - Normal messages: pass through unchanged
 */
import { findAgentCommand } from './commands.js';
import { getDb, hasTable } from './db/connection.js';

export type GateResult =
  | { action: 'pass' }
  | { action: 'filter' }
  | { action: 'deny'; command: string }
  | { action: 'new_session' }
  | { action: 'agent_command'; command: string; text: string; data?: string[]; serve?: string };

const FILTERED_COMMANDS = new Set(['/help', '/login', '/logout', '/doctor', '/config', '/remote-control']);
const ADMIN_COMMANDS = new Set(['/clear', '/compact', '/context', '/cost', '/files']);
const SESSION_COMMANDS = new Set(['/new']);

/**
 * Classify a message and decide whether it should reach the container.
 * Returns 'pass' for normal messages and authorized admin commands,
 * 'filter' for silently-dropped commands, 'deny' for unauthorized
 * admin commands, 'agent_command' for a command `agentFolder` offers.
 */
export function gateCommand(
  content: string,
  userId: string | null,
  agentGroupId: string,
  agentFolder?: string,
): GateResult {
  let text: string;
  try {
    const parsed = JSON.parse(content);
    text = (parsed.text || '').trim();
  } catch {
    text = content.trim();
  }

  if (!text.startsWith('/')) return { action: 'pass' };

  const command = text.split(/\s/)[0].toLowerCase();

  if (FILTERED_COMMANDS.has(command)) return { action: 'filter' };

  if (SESSION_COMMANDS.has(command)) return { action: 'new_session' };

  const own = agentFolder ? findAgentCommand(agentFolder, command.slice(1)) : undefined;
  if (own) {
    const args = text.slice(command.length).trim();
    return {
      action: 'agent_command',
      command: own.command,
      text: own.prompt(args),
      ...(own.data ? { data: own.data } : {}),
      // A script answers only the bare command; words after it need the model.
      ...(own.serve && !args ? { serve: own.serve } : {}),
    };
  }

  if (ADMIN_COMMANDS.has(command)) {
    if (isAdmin(userId, agentGroupId)) {
      return { action: 'pass' };
    }
    return { action: 'deny', command };
  }

  // Unknown slash commands pass through (the agent/SDK handles them)
  return { action: 'pass' };
}

/**
 * The message content an agent command reaches the container as: `text` is
 * the command's prompt, `command` tells the runner which data scripts to run
 * first, or which script answers the command instead of the model. Everything else the channel put there (attachments, iOS context,
 * sender) stays — a /food photo must still reach the model.
 */
export function applyAgentCommand(
  content: string,
  gate: { command: string; text: string; data?: string[]; serve?: string },
): string {
  let parsed: Record<string, unknown>;
  try {
    const value: unknown = JSON.parse(content);
    parsed = value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
  } catch {
    parsed = {};
  }
  return JSON.stringify({
    ...parsed,
    text: gate.text,
    command: {
      name: gate.command,
      ...(gate.data ? { data: gate.data } : {}),
      ...(gate.serve ? { serve: gate.serve } : {}),
    },
  });
}

function isAdmin(userId: string | null, agentGroupId: string): boolean {
  if (!userId) return false;
  if (!hasTable(getDb(), 'user_roles')) return true; // no permissions module = allow all
  const db = getDb();
  const row = db
    .prepare(
      `SELECT 1 FROM user_roles
       WHERE user_id = ?
         AND (role = 'owner' OR role = 'admin')
         AND (agent_group_id IS NULL OR agent_group_id = ?)
       LIMIT 1`,
    )
    .get(userId, agentGroupId);
  return row != null;
}
