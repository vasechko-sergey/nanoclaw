/**
 * MCP tools barrel — imports each tool module for its side-effect
 * `registerTools([...])` call, then starts the MCP server.
 *
 * Adding a new tool module: create the file, call `registerTools([...])`
 * at module scope, and append the import here. No central list.
 */
import './core.js';
import './scheduling.js';
import './interactive.js';
import './agents.js';
import './self-mod.js';
import './status.js';
import { getSessionRouting } from '../db/session-routing.js';
import { registerRequestContextTool } from './request_context.js';
import { registerTools, startMcpServer } from './server.js';
import { workoutCoach, workoutStartPlan, workoutSwap } from './workout.js';

// Channel-gated MCP tools: only register `request_context` when the session
// is wired to the ios-app channel. Non-iOS sessions never see the tool.
// Session routing is committed by the host on every container wake, so this
// runs after the routing row exists.
{
  const routing = getSessionRouting();
  registerRequestContextTool({
    session_id: process.env.NANOCLAW_SESSION_ID ?? '',
    channel_type: routing.channel_type,
    platform_id: routing.platform_id,
  });
}

// Agent-group-gated MCP tools: workout.* tools only register for Payne.
if (process.env.AGENT_GROUP_ID === 'payne') {
  registerTools([workoutStartPlan, workoutCoach, workoutSwap]);
}

function log(msg: string): void {
  console.error(`[mcp-tools] ${msg}`);
}

startMcpServer().catch((err) => {
  log(`MCP server error: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
