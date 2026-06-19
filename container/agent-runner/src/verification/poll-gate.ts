import { checkProvenance } from './gate.js';

const MESSAGE_BLOCK_RE = /<message\s+to="([^"]+)"\s*>([\s\S]*?)<\/message>/g;

export interface GateVerdict {
  grounded: boolean;
  /** Union of ungrounded canonical numbers across all <message> blocks. */
  ungrounded: string[];
}

/**
 * Run provenance over every <message to="...">…</message> block's body in the
 * aggregated result text, merging ungrounded numbers. Text with no blocks
 * (pure scratchpad / <internal>) is treated as grounded — the no-wrap nudge
 * handles that case, and scratchpad is never delivered.
 */
export function gateOutboundText(text: string, grounding: Set<string>): GateVerdict {
  MESSAGE_BLOCK_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  const ungrounded = new Set<string>();
  while ((match = MESSAGE_BLOCK_RE.exec(text)) !== null) {
    const r = checkProvenance(match[2], grounding);
    for (const n of r.ungrounded) ungrounded.add(n);
  }
  return { grounded: ungrounded.size === 0, ungrounded: [...ungrounded] };
}
