/**
 * send_status MCP tool — let the agent push a status banner to the channel.
 * Renders as a "──── icon text ────" divider on iOS (StatusBanner).
 * Not a chat message — use for system notices, cost summaries, health alerts.
 */
import { getSessionRouting } from '../db/session-routing.js';
import { writeMessageOut } from '../db/messages-out.js';
import { registerTools } from './server.js';
import type { McpToolDefinition } from './types.js';

function log(msg: string): void {
  console.error(`[mcp-tools/status] ${msg}`);
}

function generateId(): string {
  return `msg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

export const sendStatus: McpToolDefinition = {
  tool: {
    name: 'send_status',
    description:
      'Send a technical status banner to the active channel. Use for system notices, token cost summaries, health alerts — NOT for regular conversation replies.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        text: {
          type: 'string',
          description: 'Status text. Keep short (one line ideally).',
        },
        level: {
          type: 'string',
          enum: ['info', 'warning', 'error'],
          description: 'Severity level. Default: info.',
        },
        kind: {
          type: 'string',
          enum: ['system', 'cost', 'health', 'alert'],
          description: 'Category for icon selection. Default: system.',
        },
      },
      required: ['text'],
    },
  },
  handler: async (args) => {
    const text = (args.text as string | undefined) ?? '';
    const level = (args.level as string | undefined) ?? 'info';
    const kind = (args.kind as string | undefined) ?? 'system';

    if (!text.trim()) {
      return { content: [{ type: 'text' as const, text: 'Error: text is required' }], isError: true };
    }

    const session = getSessionRouting();
    if (!session.channel_type || !session.platform_id) {
      log('No session routing — cannot send status');
      return { content: [{ type: 'text' as const, text: 'Error: no active channel routing' }], isError: true };
    }

    writeMessageOut({
      id: generateId(),
      kind: 'chat',
      platform_id: session.platform_id,
      channel_type: session.channel_type,
      thread_id: session.thread_id,
      content: JSON.stringify({ type: 'status', text, level, kind }),
    });

    log(`Sent status [${level}/${kind}]: ${text}`);
    return { content: [{ type: 'text' as const, text: 'Status sent.' }] };
  },
};

registerTools([sendStatus]);
