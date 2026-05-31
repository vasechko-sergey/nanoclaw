// Renders InlineContext as a one-line prefix that gets prepended to the
// agent's view of an inbound iOS message. The host adapter passes the parsed
// context through; this helper produces a stable, scan-friendly header that
// the agent can reason about without parsing JSON.
//
// Format:
//   [iOS context — <timestamp> <timezone>[, near "<locality>"]
//    loc=<lat>,<lon>[ ±<accuracy>m]]
//   <original text>
//
// Timestamp millis are stripped to keep the header compact; the canonical
// envelope still carries the full precision.
import type { InlineContext } from '@shared/ios-app-protocol/index.js';

export function formatIosInbound(text: string, ctx: InlineContext | undefined): string {
  if (!ctx) return text;
  let header = `[iOS context — ${ctx.timestamp.replace(/\.\d{3}Z$/, 'Z')} ${ctx.timezone}`;
  if (ctx.locality) header += `, near "${ctx.locality}"`;
  if (ctx.location) {
    const acc = ctx.location.accuracy != null ? ` ±${ctx.location.accuracy}m` : '';
    header += `\n loc=${ctx.location.lat},${ctx.location.lon}${acc}`;
  }
  header += ']';
  return `${header}\n${text}`;
}
