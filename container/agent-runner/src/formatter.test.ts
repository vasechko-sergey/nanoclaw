/**
 * v1-parity tests for formatter behavior.
 *
 * Port of src/v1/formatting.test.ts (at commit 27c5220, parent of the v1
 * deletion commit 86becf8). Covers: context timezone header, reply_to +
 * quoted_message rendering, XML escaping, and stripInternalTags.
 *
 * Timestamp-format assertions use `formatLocalTime()` output format, which
 * is host locale-dependent for decorators (month abbr, "," separator) but
 * stable for the numeric parts we assert on (hour, minute, year).
 */
import { describe, it, expect, beforeEach, afterEach } from 'bun:test';

import { initTestSessionDb, closeSessionDb, getInboundDb } from './db/connection.js';
import { getPendingMessages } from './db/messages-in.js';
import { formatMessages, stripInternalTags } from './formatter.js';
import { TIMEZONE } from './timezone.js';

beforeEach(() => {
  initTestSessionDb();
});

afterEach(() => {
  closeSessionDb();
});

function insertMessage(
  id: string,
  kind: string,
  content: object,
  opts?: { timestamp?: string },
) {
  const timestamp = opts?.timestamp ?? new Date().toISOString();
  getInboundDb()
    .prepare(
      `INSERT INTO messages_in (id, kind, timestamp, status, content)
       VALUES (?, ?, ?, 'pending', ?)`,
    )
    .run(id, kind, timestamp, JSON.stringify(content));
}

describe('context timezone header', () => {
  it('prepends <context timezone="..."/> to formatted output', () => {
    insertMessage('m1', 'chat', { sender: 'Alice', text: 'hello' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain(`<context timezone="${TIMEZONE}"`);
  });

  it('includes the header even when the message list is empty', () => {
    const result = formatMessages([]);
    expect(result).toContain(`<context timezone="${TIMEZONE}"`);
  });

  it('header comes before the <messages> block', () => {
    insertMessage('m1', 'chat', { sender: 'Alice', text: 'one' });
    insertMessage('m2', 'chat', { sender: 'Bob', text: 'two' });
    const result = formatMessages(getPendingMessages());
    const ctxIdx = result.indexOf('<context');
    const msgsIdx = result.indexOf('<messages>');
    expect(ctxIdx).toBeGreaterThanOrEqual(0);
    expect(msgsIdx).toBeGreaterThan(ctxIdx);
  });
});

describe('iOS context attributes on header', () => {
  it('lifts timezone/ts/lat/lon/accuracy/locality from ios_context onto <context>', () => {
    insertMessage('m1', 'chat', {
      sender: 'Alice',
      text: 'hello',
      ios_context: {
        location: { lat: -8.6485, lon: 115.1315, accuracy: 25 },
        timestamp: '2026-05-31T13:53:53.000Z',
        timezone: 'Asia/Makassar',
        locality: 'Canggu',
      },
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('timezone="Asia/Makassar"');
    expect(result).toContain('ts="2026-05-31T13:53:53.000Z"');
    expect(result).toContain('lat="-8.6485"');
    expect(result).toContain('lon="115.1315"');
    expect(result).toContain('accuracy="25"');
    expect(result).toContain('locality="Canggu"');
    // Body must be raw text — no [iOS context — ...] prefix anymore.
    expect(result).not.toContain('[iOS context');
    expect(result).toContain('>hello</message>');
  });

  it('omits accuracy and locality when not present', () => {
    insertMessage('m1', 'chat', {
      sender: 'Alice',
      text: 'hi',
      ios_context: {
        location: { lat: 1, lon: 2 },
        timestamp: '2026-05-31T12:00:00.000Z',
        timezone: 'UTC',
      },
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('lat="1"');
    expect(result).toContain('lon="2"');
    expect(result).not.toContain('accuracy=');
    expect(result).not.toContain('locality=');
  });

  it('omits location attrs entirely when ios_context has no location', () => {
    insertMessage('m1', 'chat', {
      sender: 'Alice',
      text: 'hi',
      ios_context: {
        timestamp: '2026-05-31T12:00:00.000Z',
        timezone: 'Asia/Tokyo',
        locality: 'Shibuya',
      },
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('timezone="Asia/Tokyo"');
    expect(result).toContain('ts="2026-05-31T12:00:00.000Z"');
    expect(result).toContain('locality="Shibuya"');
    expect(result).not.toContain('lat=');
    expect(result).not.toContain('lon=');
    expect(result).not.toContain('accuracy=');
  });

  it('falls back to container TIMEZONE when no ios_context', () => {
    insertMessage('m1', 'chat', { sender: 'Alice', text: 'plain' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain(`timezone="${TIMEZONE}"`);
    expect(result).not.toContain('ts=');
    expect(result).not.toContain('lat=');
    expect(result).not.toContain('locality=');
  });

  it('XML-escapes string attributes from ios_context', () => {
    insertMessage('m1', 'chat', {
      sender: 'Alice',
      text: 'hi',
      ios_context: {
        timestamp: '2026-05-31T12:00:00.000Z',
        timezone: 'UTC',
        locality: 'A & B <Café>',
      },
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('locality="A &amp; B &lt;Café&gt;"');
  });
});

describe('timestamp formatting', () => {
  it('renders time via formatLocalTime (user TZ)', () => {
    // 2026-06-15T12:00:00Z — timezone-agnostic assertions (year is stable)
    insertMessage('m1', 'chat', { sender: 'Alice', text: 'hi' }, { timestamp: '2026-06-15T12:00:00.000Z' });
    const result = formatMessages(getPendingMessages());
    // formatLocalTime's format in en-US contains the year and a month abbrev
    expect(result).toContain('2026');
    expect(result).toMatch(/Jun/);
  });

  it('uses 12-hour AM/PM format', () => {
    // 15:30 UTC — some hour will show with AM or PM depending on TZ
    insertMessage('m1', 'chat', { sender: 'Alice', text: 'hi' }, { timestamp: '2026-06-15T15:30:00.000Z' });
    const result = formatMessages(getPendingMessages());
    expect(result).toMatch(/(AM|PM)/);
  });
});

describe('reply_to + quoted_message rendering', () => {
  it('renders reply_to attribute and quoted_message when all fields present', () => {
    insertMessage('m1', 'chat', {
      sender: 'Alice',
      text: 'Yes, on my way!',
      replyTo: { id: '42', sender: 'Bob', text: 'Are you coming tonight?' },
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('reply_to="42"');
    expect(result).toContain('<quoted_message from="Bob">Are you coming tonight?</quoted_message>');
    expect(result).toContain('Yes, on my way!</message>');
  });

  it('omits reply_to and quoted_message when no reply context', () => {
    insertMessage('m1', 'chat', { sender: 'Alice', text: 'plain' });
    const result = formatMessages(getPendingMessages());
    expect(result).not.toContain('reply_to');
    expect(result).not.toContain('quoted_message');
  });

  it('renders reply_to but omits quoted_message when original content is missing', () => {
    insertMessage('m1', 'chat', {
      sender: 'Alice',
      text: 'ack',
      replyTo: { id: '42', sender: 'Bob' }, // no text
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('reply_to="42"');
    expect(result).not.toContain('quoted_message');
  });

  it('XML-escapes reply context', () => {
    insertMessage('m1', 'chat', {
      sender: 'Alice',
      text: 'reply',
      replyTo: { id: '1', sender: 'A & B', text: '<script>alert("xss")</script>' },
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('from="A &amp; B"');
    expect(result).toContain('&lt;script&gt;');
    expect(result).toContain('&quot;xss&quot;');
  });
});

describe('XML escaping', () => {
  it('escapes <, >, &, " in sender and body', () => {
    insertMessage('m1', 'chat', {
      sender: 'A & B <Co>',
      text: '<script>alert("xss")</script>',
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('sender="A &amp; B &lt;Co&gt;"');
    expect(result).toContain('&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;');
  });
});

describe('stripInternalTags', () => {
  it('strips single-line internal tags and trims', () => {
    expect(stripInternalTags('hello <internal>secret</internal> world')).toBe('hello  world');
  });

  it('strips multi-line internal tags', () => {
    expect(stripInternalTags('hello <internal>\nsecret\nstuff\n</internal> world')).toBe(
      'hello  world',
    );
  });

  it('strips multiple internal tag blocks', () => {
    expect(stripInternalTags('<internal>a</internal>hello<internal>b</internal>')).toBe('hello');
  });

  it('returns empty string when input is only internal tags', () => {
    expect(stripInternalTags('<internal>only this</internal>')).toBe('');
  });

  it('returns input unchanged when there are no internal tags', () => {
    expect(stripInternalTags('hello world')).toBe('hello world');
  });

  it('preserves content that surrounds internal tags', () => {
    expect(stripInternalTags('<internal>thinking</internal>The answer is 42')).toBe(
      'The answer is 42',
    );
  });
});

describe('workout_event system rows', () => {
  const base = {
    id: 'wk1',
    seq: 7,
    kind: 'system',
    timestamp: '2026-06-26T03:34:00Z',
    status: 'pending',
    process_after: null,
    recurrence: null,
    tries: 0,
    trigger: 1,
    platform_id: null,
    channel_type: null,
    thread_id: null,
    source_session_id: null,
  };

  it('renders a typed <workout_event> tag carrying event + payload, not <system_response>', () => {
    const row = {
      ...base,
      content: JSON.stringify({
        subtype: 'workout_event',
        event: 'workout_complete',
        payload: { workout_id: '2026-06-26', full_session_json: { exercises: [] } },
      }),
    };
    const result = formatMessages([row as Parameters<typeof formatMessages>[0][number]]);
    expect(result).toContain('<workout_event');
    expect(result).toContain('event="workout_complete"');
    expect(result).toContain('"workout_id":"2026-06-26"');
    expect(result).not.toContain('<system_response');
  });

  it('still renders non-workout system rows as <system_response>', () => {
    const row = {
      ...base,
      id: 'sys1',
      content: JSON.stringify({ action: 'schedule', status: 'ok', result: null }),
    };
    const result = formatMessages([row as Parameters<typeof formatMessages>[0][number]]);
    expect(result).toContain('<system_response');
    expect(result).not.toContain('<workout_event');
  });
});

// task-3b: once a late question_response row reaches the agent (see
// poll-loop.ts's isUnclaimedQuestionResponse), it must render legibly. The
// generic <system_response> branch prints action="unknown" status="unknown"
// and JSON.stringify(content.result || null) — this row carries none of
// those fields, so without a dedicated branch the agent would see
// <system_response action="unknown" status="unknown">null</system_response>,
// telling it nothing about which question was answered or how.
describe('question_response system rows', () => {
  const base = {
    id: 'qr1',
    seq: 9,
    kind: 'system',
    timestamp: '2026-06-26T03:34:00Z',
    status: 'pending',
    process_after: null,
    recurrence: null,
    tries: 0,
    trigger: 1,
    platform_id: null,
    channel_type: null,
    thread_id: null,
    source_session_id: null,
  };

  it('renders a typed <question_response> tag carrying title + answer, not <system_response>', () => {
    const row = {
      ...base,
      content: JSON.stringify({
        type: 'question_response',
        questionId: 'q-1',
        selectedOption: 'ok',
        userId: 'u1',
        title: 'Как проснулся?',
      }),
    };
    const result = formatMessages([row as Parameters<typeof formatMessages>[0][number]]);
    expect(result).toContain('<question_response');
    expect(result).toContain('title="Как проснулся?"');
    expect(result).toContain('answer="ok"');
    expect(result).not.toContain('<system_response');
  });

  it('still renders non-question system rows as <system_response>', () => {
    const row = {
      ...base,
      content: JSON.stringify({ action: 'schedule', status: 'ok', result: null }),
    };
    const result = formatMessages([row as Parameters<typeof formatMessages>[0][number]]);
    expect(result).toContain('<system_response');
    expect(result).not.toContain('<question_response');
  });
});

describe('a2a sender identity', () => {
  function insertA2a(id: string, content: object) {
    getInboundDb()
      .prepare(
        `INSERT INTO messages_in (id, kind, timestamp, status, channel_type, platform_id, content)
         VALUES (?, 'chat', ?, 'pending', 'agent', 'payne', ?)`,
      )
      .run(id, new Date().toISOString(), JSON.stringify(content));
  }

  it('renders the stamped agent name and id on an a2a row', () => {
    insertA2a('a1', {
      sender: 'Майор Пейн',
      senderId: 'payne',
      text: '{"action":"workout_done","type":"Ноги"}',
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('sender="Майор Пейн"');
    expect(result).toContain('agent="payne"');
  });

  it('does not emit agent= for non-agent (human) messages', () => {
    insertMessage('m1', 'chat', { sender: 'Alice', senderId: 'telegram:1', text: 'hi' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('sender="Alice"');
    expect(result).not.toContain('agent=');
  });
});

describe('a2a kind attribute', () => {
  function insertA2a(id: string, content: object) {
    getInboundDb()
      .prepare(
        `INSERT INTO messages_in (id, kind, timestamp, status, channel_type, platform_id, content)
         VALUES (?, 'chat', ?, 'pending', 'agent', 'payne', ?)`,
      )
      .run(id, new Date().toISOString(), JSON.stringify(content));
  }

  it('renders kind= for a structured a2a message', () => {
    insertA2a('a1', { sender: 'Майор Пейн', senderId: 'payne', a2a_kind: 'set_log', text: '{"reps":8}' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('kind="set_log"');
  });

  it('omits kind= for the implicit text default', () => {
    // `text` is the 55% freeform majority — printing it would be pure noise.
    insertA2a('a1', { sender: 'Майор Пейн', senderId: 'payne', a2a_kind: 'text', text: 'норм' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('норм');
    expect(result).not.toContain('kind=');
  });

  it('omits kind= when the envelope carries none (pre-migration row)', () => {
    insertA2a('a1', { sender: 'Майор Пейн', senderId: 'payne', text: 'норм' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('норм');
    expect(result).not.toContain('kind=');
  });

  it('never renders kind= on a non-agent message even when content carries one', () => {
    // kind is an a2a concept. A human message whose content happens to have an
    // `a2a_kind` key must not sprout the attribute — same gate as agent=.
    // (Keyed on a2a_kind, not kind, so deleting the channel_type gate still
    // fails this test rather than passing vacuously.)
    insertMessage('m1', 'chat', { sender: 'Alice', a2a_kind: 'set_log', text: 'hi' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('sender="Alice"');
    expect(result).not.toContain('kind=');
  });

  it('never renders kind= off a status row `kind` — that is a status category', () => {
    // REGRESSION / ship-inert. poll-loop.ts writes status rows as
    // `{type:'status', text, level, kind}` stamped with the batch's
    // channel_type — 'agent' whenever the turn was woken by an a2a inbound. Its
    // `kind` ('system') predates the envelope and is not an a2a kind. Reading
    // the attribute off `content.kind` made a forwarded status render
    // kind="system": a wire change on a branch that must ship inert.
    insertA2a('a1', {
      sender: 'Джарвис',
      senderId: 'jarvis',
      type: 'status',
      level: 'info',
      kind: 'system',
      text: 'Context compacted',
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('Context compacted');
    expect(result).not.toContain('kind=');
  });

  it('escapes a kind containing markup', () => {
    insertA2a('a1', { sender: 'Майор Пейн', senderId: 'payne', a2a_kind: '<script>', text: 'x' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('kind="&lt;script&gt;"');
    expect(result).not.toContain('kind="<script>"');
  });

  it('renders kind= alongside the agent id, not instead of it', () => {
    insertA2a('a1', { sender: 'Майор Пейн', senderId: 'payne', a2a_kind: 'ack', text: 'ок' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('agent="payne"');
    expect(result).toContain('kind="ack"');
    expect(result).toContain('sender="Майор Пейн"');
  });
});

// The clock the agent reads must be the OWNER's, not the container's.
//
// Live bug: the container ran TZ=Asia/Makassar (+8) while the owner's phone
// reported Asia/Colombo (+5:30). `buildContextHeader` lifted the iOS zone
// correctly, but every message stamp was still rendered against the container
// zone — one prompt carrying `<context timezone="Asia/Colombo">` next to a
// message stamped 2.5h ahead of the owner's real wall clock. Past ~21:30
// Colombo that gap rolls the stamped DATE onto tomorrow, and the agent starts
// naming the wrong day.
describe('message stamps follow the owner timezone', () => {
  const savedOwner = process.env.OWNER_TZ;
  const savedTz = process.env.TZ;
  beforeEach(() => {
    process.env.TZ = 'Asia/Makassar'; // +8, what the host runs
    process.env.OWNER_TZ = 'Asia/Colombo'; // +5:30, where the owner is
  });
  afterEach(() => {
    if (savedOwner === undefined) delete process.env.OWNER_TZ;
    else process.env.OWNER_TZ = savedOwner;
    if (savedTz === undefined) delete process.env.TZ;
    else process.env.TZ = savedTz;
  });

  it('renders a chat stamp in OWNER_TZ, not the container TZ', () => {
    insertMessage('m1', 'chat', { sender: 'Alice', text: 'hi' }, { timestamp: '2026-08-03T12:42:38Z' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('6:12 PM'); // Colombo
    expect(result).not.toContain('8:42 PM'); // Makassar
  });

  it('falls back to OWNER_TZ in the context header when no ios_context', () => {
    insertMessage('m1', 'chat', { sender: 'Alice', text: 'hi' });
    expect(formatMessages(getPendingMessages())).toContain('timezone="Asia/Colombo"');
  });

  it('a naive host timestamp still lands on the owner clock', () => {
    // SQLite datetime('now') form — UTC without the Z.
    insertMessage('m1', 'task', { prompt: 'run' }, { timestamp: '2026-08-18 03:16:44' });
    expect(formatMessages(getPendingMessages())).toContain('8:46 AM'); // Colombo
  });
});
