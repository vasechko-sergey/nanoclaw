import { test, it, expect, describe } from 'bun:test';
import { extractToolResultText, translateSdkMessage } from './claude.js';

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
