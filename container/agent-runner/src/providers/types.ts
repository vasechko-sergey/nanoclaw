export interface AgentProvider {
  /**
   * True if the provider's underlying SDK handles slash commands natively and
   * wants them passed through as raw text. When false, the poll-loop formats
   * slash commands like any other chat message.
   */
  readonly supportsNativeSlashCommands: boolean;

  /** Start a new query. Returns a handle for streaming input and output. */
  query(input: QueryInput): AgentQuery;

  /**
   * True if the given error indicates the stored continuation is invalid
   * (missing transcript, unknown session, etc.) and should be cleared.
   */
  isSessionInvalid(err: unknown): boolean;
}

/**
 * Options passed to provider constructors. Fields are common to most
 * providers; individual providers may ignore any they don't need.
 */
export interface ProviderOptions {
  assistantName?: string;
  mcpServers?: Record<string, McpServerConfig>;
  env?: Record<string, string | undefined>;
  additionalDirectories?: string[];
  /**
   * Model alias (`sonnet`, `opus`, `haiku`) or full model ID. Passed through
   * to the underlying SDK. If omitted, the SDK default is used.
   */
  model?: string;
  /**
   * Reasoning effort (`'low' | 'medium' | 'high' | 'xhigh' | 'max'`). Passed
   * through to the underlying SDK. If omitted, the SDK default is used.
   */
  effort?: string;
}

export interface QueryInput {
  /** Initial prompt (already formatted by agent-runner). */
  prompt: string;

  /**
   * Opaque continuation token from a previous query. The provider decides
   * what this means (session ID, thread ID, nothing at all).
   */
  continuation?: string;

  /** Working directory inside the container. */
  cwd: string;

  /**
   * System context to inject. Providers translate this into whatever their
   * SDK expects (preset append, full system prompt, per-turn injection…).
   */
  systemContext?: {
    instructions?: string;
  };
}

export interface McpServerConfig {
  command: string;
  args: string[];
  env: Record<string, string>;
}

export interface AgentQuery {
  /** Push a follow-up message into the active query. */
  push(message: string): void;

  /** Signal that no more input will be sent. */
  end(): void;

  /** Output event stream. */
  events: AsyncIterable<ProviderEvent>;

  /** Force-stop the query. */
  abort(): void;
}

export type ProviderEvent =
  | { type: 'init'; continuation: string }
  | { type: 'result'; text: string | null }
  | { type: 'error'; message: string; retryable: boolean; classification?: string }
  | { type: 'progress'; message: string }
  | { type: 'status_msg'; text: string; level: 'info' | 'warning' | 'error'; kind?: string }
  /**
   * The HARNESS failed, and said so in the agent's voice.
   *
   * Distinct from `error` (which the provider synthesizes from a system
   * event) and from `assistant_text` (which the model actually authored).
   * Providers MUST emit this — never `assistant_text` — when their SDK
   * reports a turn-level failure whose text is indistinguishable from
   * ordinary model output. The Claude SDK does exactly that for usage
   * limits: the notice arrives as a normal `assistant` message ("You've hit
   * your limit · resets 9:50pm"), and the ONLY discriminator is a
   * structural `error` field beside the content — never the text.
   *
   * Routing it as `assistant_text` misattributes harness output to the
   * agent: the text isn't wrapped in <message to="…">, so the poll-loop
   * scratchpads it, drops it, and then nudges the agent to "re-send it
   * wrapped" — burning a second turn against the same limit on text the
   * agent never wrote and cannot fix. The poll-loop delivers this event as
   * a system notice instead, and suppresses the nudge for the turn.
   *
   * `code` is the provider's own failure code (Claude: `rate_limit`,
   * `authentication_failed`, `billing_error`, …) — kept a plain string so
   * this contract stays provider-agnostic. `text` is whatever the harness
   * surfaced, verbatim, and MAY be empty; it carries operator-critical
   * detail (a usage limit's reset time) that exists nowhere else.
   */
  | { type: 'harness_error'; code: string; text: string }
  /**
   * Streaming assistant text. Yielded per text content-block as the model
   * produces it, BEFORE the final `result` event. Lets the poll-loop
   * dispatch <message to="..."> blocks immediately instead of waiting for
   * the turn to complete — if the stream hangs or the container dies
   * mid-turn, already-emitted messages still reach the user.
   *
   * Providers MAY emit text in chunks; the poll-loop buffers across
   * events and only dispatches blocks that are fully closed (<message>…
   * </message>). Providers that can't stream MAY skip this and rely on
   * the final `result.text` path — both routes are deduped against each
   * other by exact (toName, body) match.
   */
  | { type: 'assistant_text'; text: string }
  /**
   * Tool call started. Providers SHOULD emit this when the model issues a
   * tool_use and SHOULD pair it with a `tool_use_end` for the same `id`
   * when the tool returns. The poll-loop uses the in-flight tool set to
   * suppress the per-turn idle watchdog while at least one tool is
   * running — long Bash/MCP calls produce no SDK events between
   * `tool_use` and `tool_result`, and the 30-min host ceiling still
   * backstops a genuinely wedged tool.
   *
   * `id` is the SDK's tool_use_id; the same value MUST appear on the
   * paired `tool_use_end`. Providers that can't observe tool boundaries
   * MAY skip both events — the watchdog then falls back to the plain
   * idle timer.
   */
  | { type: 'tool_use_start'; id: string }
  /** Pair of `tool_use_start`. See that event's docs. `output` carries the
   *  tool_result text (when the provider can surface it) so the poll-loop can
   *  build a per-turn grounding set for the factuality gate. */
  | { type: 'tool_use_end'; id: string; output?: string }
  /**
   * Liveness signal. Providers MUST yield this on every underlying SDK
   * event (tool call, thinking, partial message, anything) so the
   * poll-loop's idle timer stays honest during long tool runs.
   */
  | { type: 'activity' };
