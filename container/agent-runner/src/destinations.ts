/**
 * Destination map — lives in inbound.db's `destinations` table.
 *
 * The host writes this table before every container wake AND on demand
 * (e.g. when a new child agent is created mid-session). The container
 * queries the table live on every lookup, so admin changes take effect
 * immediately — no restart required.
 *
 * This table is BOTH the routing map and the container-visible ACL.
 * The host re-validates on the delivery side against the central DB,
 * so even if this table is stale the host's enforcement is authoritative.
 */
import { getInboundDb } from './db/connection.js';

export interface DestinationEntry {
  name: string;
  displayName: string;
  type: 'channel' | 'agent';
  channelType?: string;
  platformId?: string;
  agentGroupId?: string;
  /**
   * Kinds this destination's target accepts over a2a, or null when it has no
   * descriptor (gate disarmed). Host-written on every wake from the target's
   * agent.json. Unparseable JSON is treated as null — fail open, never bounce
   * everything over a corrupt row.
   */
  a2aKinds?: string[] | null;
}

interface DestRow {
  name: string;
  display_name: string | null;
  type: 'channel' | 'agent';
  channel_type: string | null;
  platform_id: string | null;
  agent_group_id: string | null;
  a2a_kinds: string | null;
}

/**
 * Raw `a2a_kinds` column → the kind list, or null when there's nothing usable.
 *
 * Every failure mode collapses to null (= gate disarmed) on purpose: a corrupt
 * or unexpected value must not bounce an agent's entire inbox. An empty array
 * is NOT null — it means "has a descriptor, declares no kinds", gate armed.
 */
function parseKinds(raw: string | null): string[] | null {
  if (!raw) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  return Array.isArray(parsed) ? parsed.filter((k): k is string => typeof k === 'string') : null;
}

function rowToEntry(row: DestRow): DestinationEntry {
  return {
    name: row.name,
    displayName: row.display_name ?? row.name,
    type: row.type,
    channelType: row.channel_type ?? undefined,
    platformId: row.platform_id ?? undefined,
    agentGroupId: row.agent_group_id ?? undefined,
    a2aKinds: parseKinds(row.a2a_kinds),
  };
}

export function getAllDestinations(): DestinationEntry[] {
  const rows = getInboundDb().prepare('SELECT * FROM destinations ORDER BY name').all() as DestRow[];
  return rows.map(rowToEntry);
}

export function findByName(name: string): DestinationEntry | undefined {
  const row = getInboundDb().prepare('SELECT * FROM destinations WHERE name = ?').get(name) as DestRow | undefined;
  return row ? rowToEntry(row) : undefined;
}

/**
 * Reverse lookup: given routing fields from an inbound message, find
 * which destination they correspond to (what does this agent call the sender?).
 */
export function findByRouting(
  channelType: string | null | undefined,
  platformId: string | null | undefined,
): DestinationEntry | undefined {
  if (!channelType || !platformId) return undefined;
  const db = getInboundDb();
  const row =
    channelType === 'agent'
      ? (db
          .prepare("SELECT * FROM destinations WHERE type = 'agent' AND agent_group_id = ?")
          .get(platformId) as DestRow | undefined)
      : (db
          .prepare("SELECT * FROM destinations WHERE type = 'channel' AND channel_type = ? AND platform_id = ?")
          .get(channelType, platformId) as DestRow | undefined);
  return row ? rowToEntry(row) : undefined;
}

/**
 * Generate the system-prompt addendum: agent identity + destination map.
 *
 * Identity is injected here (not in the shared CLAUDE.md) because it's
 * per-agent-group and changes when the operator renames an agent, while
 * the shared base is identical across all agents.
 */
export function buildSystemPromptAddendum(assistantName?: string): string {
  const sections: string[] = [];

  if (assistantName) {
    sections.push(['# You are ' + assistantName, '', `Your name is **${assistantName}**. Use it when the channel asks who you are, when introducing yourself, and when signing any message that explicitly calls for a signature.`, '', `Your persona — voice, tone, vocabulary, idioms, attitude — is defined in the group CLAUDE.md loaded into this session. Treat that persona as a hard constraint: stay in character for every user-facing message, including short acknowledgments and errors. Do not default to a neutral helpful-assistant register, do not flatten the voice for brevity, do not drop signature idioms even when answers are short.`].join('\n'));
  }

  sections.push(buildDestinationsSection());

  return sections.join('\n\n');
}

/**
 * The ` — kind: a, b` tail on a destination's line, or '' when there is nothing
 * to teach.
 *
 * This is the point of the whole normalization: the kind list the agent READS is
 * rendered from `a2aKinds` — the same descriptor projection the gate ENFORCES —
 * so the contract cannot drift from what the wire accepts. The moment this list
 * is instead hand-written into CLAUDE.md prose, it is a copy, and copies rot.
 *
 * Silent in three cases, each for its own reason:
 * - channels: `kind` is an a2a concept and never applies (the host writes NULL
 *   here anyway; the type check is what keeps a future projection change from
 *   teaching kinds to a human-facing channel).
 * - `null`: no descriptor → gate disarmed → nothing is enforced, so there is
 *   nothing to teach. This is what makes the feature ship inert.
 * - `[]`: a descriptor that declares no kinds (gate armed, text-only). There is
 *   no list to print, and an empty ` — kind: ` would be worse than silence.
 */
function kindSuffix(d: DestinationEntry): string {
  if (d.type !== 'agent' || !d.a2aKinds || d.a2aKinds.length === 0) return '';
  return ` — kind: ${d.a2aKinds.join(', ')}`;
}

function buildDestinationsSection(): string {
  const all = getAllDestinations();

  if (all.length === 0) {
    return [
      '## Sending messages',
      '',
      'You currently have no configured destinations. You cannot send messages until an admin wires one up.',
    ].join('\n');
  }

  const lines = ['## Sending messages', ''];
  if (all.length === 1) {
    const d = all[0];
    const label = d.displayName && d.displayName !== d.name ? ` (${d.displayName})` : '';
    lines.push(`Your destination is \`${d.name}\`${label}${kindSuffix(d)}.`);
  } else {
    lines.push('You can send messages to the following destinations:', '');
    for (const d of all) {
      const label = d.displayName && d.displayName !== d.name ? ` (${d.displayName})` : '';
      lines.push(`- \`${d.name}\`${label}${kindSuffix(d)}`);
    }
  }
  lines.push('');
  lines.push(
    'Wrap each delivered message in a `<message to="name">…</message>` block; include several blocks in one response to address several destinations. `<internal>…</internal>` marks thinking you don\'t want sent.',
  );

  // Guarded: with zero descriptors every gate is disarmed, and a format rule for
  // a gate that cannot fire is prose that teaches a contract nothing checks —
  // precisely what this project removes. Silent until something is armed, so the
  // pre-rollout prompt stays byte-identical to the one agents read today.
  const anyKinds = all.some((d) => d.type === 'agent' && d.a2aKinds && d.a2aKinds.length > 0);
  if (anyKinds) {
    lines.push('');
    lines.push(
      'Для агентов-адресатов, у которых указаны `kind`, структурные сообщения помечай атрибутом: ' +
        '`<message to="имя" kind="вид">{…}</message>`. Обычный текст шлётся без `kind`. ' +
        'Непомеченное сообщение с JSON-телом и незнакомый `kind` не доставляются — ты получишь ' +
        '`<system>` с причиной и списком допустимых `kind`.',
    );
  }

  lines.push('');
  lines.push(
    'When replying to an incoming message, default to addressing the destination it came `from` (every inbound `<message>` tag carries a `from="name"` attribute). Pick a different destination when the request asks for it (e.g., "tell Laura that…").',
  );
  lines.push('');
  lines.push(
    'The `send_message` MCP tool is available mid-turn for a quick acknowledgment ("on it") before a slow tool call. If you use `send_message` for a piece of content, do NOT repeat that same content in a final `<message>` block — it will be delivered twice. Use one or the other for any given message.',
  );
  return lines.join('\n');
}
