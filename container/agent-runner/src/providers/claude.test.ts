import { test, it, expect, describe } from 'bun:test';
import { createCompactionTracker, createToolExecutionTracker, extractToolResultText, translateSdkMessage } from './claude.js';

test('extractToolResultText reads a string content block', () => {
  expect(extractToolResultText('TRC20 fee: 0.80 USDT')).toBe('TRC20 fee: 0.80 USDT');
});

test('extractToolResultText joins array text blocks', () => {
  const content = [
    { type: 'text', text: 'fee 0.80' },
    { type: 'text', text: ' net 0.1%' },
  ];
  expect(extractToolResultText(content)).toBe('fee 0.80 net 0.1%');
});

test('extractToolResultText returns empty for unknown shapes', () => {
  expect(extractToolResultText(undefined)).toBe('');
  expect(extractToolResultText(42 as unknown)).toBe('');
});

/**
 * The usage-limit notice arrives as an ORDINARY `assistant` message — same
 * shape the model's own replies use, text that reads like the agent wrote it.
 * The only thing separating "the agent said this" from "the harness said this"
 * is the `error` field beside the content (SDKAssistantMessage.error, sdk.d.ts).
 *
 * Never assert on the text: the wording is the SDK's to change, and matching it
 * is how this bug becomes unfixable. `error` is the contract.
 */
describe('translateSdkMessage — harness errors vs agent text', () => {
  /** Verbatim from logs/containers.log, jarvis rate-limited on a cron task. */
  const LIMIT_TEXT = "You've hit your limit · resets 9:50pm (Asia/Makassar)";

  function assistantMsg(content: unknown[], error?: string): unknown {
    const msg: Record<string, unknown> = {
      type: 'assistant',
      message: { content },
      parent_tool_use_id: null,
      uuid: 'u1',
      session_id: 's1',
    };
    if (error) msg.error = error;
    return msg;
  }

  it('routes a rate-limited assistant message to harness_error, not assistant_text', () => {
    const events = translateSdkMessage(assistantMsg([{ type: 'text', text: LIMIT_TEXT }], 'rate_limit'));

    expect(events).toEqual([{ type: 'harness_error', code: 'rate_limit', text: LIMIT_TEXT }]);
    // The load-bearing half: if this text escapes as assistant_text it gets
    // scratchpadded as the agent's own unwrapped output and dropped.
    expect(events.some((e) => e.type === 'assistant_text')).toBe(false);
  });

  it('carries every SDK error code through, not just rate_limit', () => {
    for (const code of ['authentication_failed', 'billing_error', 'invalid_request', 'max_output_tokens']) {
      const events = translateSdkMessage(assistantMsg([{ type: 'text', text: 'nope' }], code));
      expect(events).toEqual([{ type: 'harness_error', code, text: 'nope' }]);
    }
  });

  it('concatenates multi-part harness text so the reset time survives', () => {
    const events = translateSdkMessage(
      assistantMsg(
        [
          { type: 'text', text: "You've hit your limit" },
          { type: 'text', text: ' · resets 9:50pm' },
        ],
        'rate_limit',
      ),
    );
    expect(events).toEqual([
      { type: 'harness_error', code: 'rate_limit', text: "You've hit your limit · resets 9:50pm" },
    ]);
  });

  it('still emits harness_error when the errored message carries no text', () => {
    // Defensive: the event drives nudge suppression, so it must fire even
    // with nothing to say. poll-loop supplies fallback wording from `code`.
    expect(translateSdkMessage(assistantMsg([], 'server_error'))).toEqual([
      { type: 'harness_error', code: 'server_error', text: '' },
    ]);
  });

  it('does not emit tool_use_start from an errored message', () => {
    // An orphan tool_use_start (no pairing tool_use_end can arrive — the turn
    // failed) suppresses the poll-loop's idle watchdog.
    const events = translateSdkMessage(assistantMsg([{ type: 'tool_use', id: 'tu_1' }], 'rate_limit'));
    expect(events.some((e) => e.type === 'tool_use_start')).toBe(false);
  });

  it('REGRESSION: an assistant message with no error still yields assistant_text', () => {
    expect(translateSdkMessage(assistantMsg([{ type: 'text', text: 'Готово, отчёт собран.' }]))).toEqual([
      { type: 'assistant_text', text: 'Готово, отчёт собран.' },
    ]);
  });

  it('REGRESSION: an unerrored message still yields text + tool_use in order', () => {
    const events = translateSdkMessage(
      assistantMsg([
        { type: 'text', text: 'Проверяю…' },
        { type: 'tool_use', id: 'tu_1' },
      ]),
    );
    expect(events).toEqual([
      { type: 'assistant_text', text: 'Проверяю…' },
      { type: 'tool_use_start', id: 'tu_1' },
    ]);
  });

  it('REGRESSION: still maps the non-assistant messages the poll-loop relies on', () => {
    expect(translateSdkMessage({ type: 'system', subtype: 'init', session_id: 'sess-1' })).toEqual([
      { type: 'init', continuation: 'sess-1' },
    ]);
    expect(translateSdkMessage({ type: 'result', result: 'done' })).toEqual([{ type: 'result', text: 'done' }]);
    expect(translateSdkMessage({ type: 'system', subtype: 'rate_limit_event' })).toEqual([
      { type: 'error', message: 'Rate limit', retryable: false, classification: 'quota' },
    ]);
  });
});

/**
 * PreCompact fires, then the SDK goes silent for however long summarizing a
 * 165k-token context takes — no events, no tool in flight. The tracker is
 * what lets the poll-loop tell that window apart from a wedged stream.
 */
describe('compaction tracker', () => {
  it('is idle until PreCompact fires', () => {
    const t = createCompactionTracker();
    expect(t.isBusy()).toBe(false);
  });

  it('reports busy from PreCompact until the next SDK message', () => {
    const t = createCompactionTracker();
    t.onPreCompact();
    expect(t.isBusy()).toBe(true);
    t.onMessage();
    expect(t.isBusy()).toBe(false);
  });

  it('re-arms for a second compaction in the same turn', () => {
    const t = createCompactionTracker();
    t.onPreCompact();
    t.onMessage();
    t.onPreCompact();
    expect(t.isBusy()).toBe(true);
  });
});

/**
 * A tool_use block in the stream is the model asking for a tool — not the tool
 * running. On 2026-10-02 Payne's stream stalled right after such a block: the
 * message never completed, nothing ran, and the watchdog took the block for a
 * running tool. The tracker reports only what the CLI actually executes:
 * PreToolUse opens a call, PostToolUse(Failure) or its tool_result closes it.
 */
describe('tool execution tracker', () => {
  it('nothing runs until PreToolUse', () => {
    expect(createToolExecutionTracker().isRunning()).toBe(false);
  });

  it('runs from PreToolUse to PostToolUse', () => {
    const t = createToolExecutionTracker();
    t.started('t1');
    expect(t.isRunning()).toBe(true);
    t.finished('t1');
    expect(t.isRunning()).toBe(false);
  });

  it('a subagent keeps the call open while its own tools come and go', () => {
    const t = createToolExecutionTracker();
    t.started('agent-1');
    t.started('inner-1');
    t.finished('inner-1');
    expect(t.isRunning()).toBe(true);
    t.finished('agent-1');
    expect(t.isRunning()).toBe(false);
  });

  it('a tool_result closes a call whose Post hook never came', () => {
    const t = createToolExecutionTracker();
    t.started('t1');
    t.onEvent({ type: 'tool_use_end', id: 't1' });
    expect(t.isRunning()).toBe(false);
  });

  it("the turn's result clears whatever is left", () => {
    const t = createToolExecutionTracker();
    t.started('t1');
    t.started('t2');
    t.onEvent({ type: 'result', text: 'done' });
    expect(t.isRunning()).toBe(false);
  });
});
