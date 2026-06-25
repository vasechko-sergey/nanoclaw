# Per-agent voices + voice-only mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each of the 5 agents its own cloned TTS voice, and add a global "voice-only" mode where the reply arrives as a voice note (text held behind a Telegram-style collapsed transcript, a "записывает…" placeholder filling the render wait).

**Architecture:** Three phases. (1) Sidecar voice registry grows 1→5 keyed by agent folder; host picks voice by folder and drops the `isJarvis` gate. (2) A `voice_only` flag rides the iOS InlineContext → persisted on `sessions.voice_only` → delivery stamps the text envelope so the client hides it until the audio (correlated by the existing `reply_to_id`) lands; on render failure the host emits a `voice_failed` signal. (3) iOS adds a Settings toggle, a pending placeholder bubble, and a collapsed transcript for voice-only rows.

**Tech Stack:** Node host (vitest), Python F5-TTS sidecar (FastAPI), Swift/SwiftUI iOS app (GRDB, xcodegen), shared Zod protocol mirrored to Swift.

**Spec:** `docs/superpowers/specs/2026-06-25-per-agent-voices-and-voice-only-mode-design.md`

---

## Phase 1 — Per-agent voices (sidecar + host)

### Task 1.1: Host — `decideVoice` helper + drop the `isJarvis` gate

**Files:**
- Create: `src/modules/voice/decide-voice.ts`
- Create: `src/modules/voice/decide-voice.test.ts`
- Modify: `src/delivery.ts` (voice gate block, ~lines 420–475)

- [ ] **Step 1: Write the failing test**

`src/modules/voice/decide-voice.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { decideVoice } from './decide-voice.js';

describe('decideVoice', () => {
  it('renders the folder-named voice for a final voice reply', () => {
    const d = decideVoice({ isFinalUserReply: true, voiceIntent: true, voiceOnly: false, hasText: true, folder: 'greg' });
    expect(d).toEqual({ shouldRender: true, voice: 'greg', holdText: false });
  });
  it('holdText is true only when voiceOnly is set', () => {
    const d = decideVoice({ isFinalUserReply: true, voiceIntent: true, voiceOnly: true, hasText: true, folder: 'jarvis' });
    expect(d).toEqual({ shouldRender: true, voice: 'jarvis', holdText: true });
  });
  it('no render when not the final reply', () => {
    expect(decideVoice({ isFinalUserReply: false, voiceIntent: true, voiceOnly: true, hasText: true, folder: 'jarvis' }).shouldRender).toBe(false);
  });
  it('no render without voice intent', () => {
    expect(decideVoice({ isFinalUserReply: true, voiceIntent: false, voiceOnly: false, hasText: true, folder: 'jarvis' }).shouldRender).toBe(false);
  });
  it('no render without text', () => {
    expect(decideVoice({ isFinalUserReply: true, voiceIntent: true, voiceOnly: false, hasText: false, folder: 'jarvis' }).shouldRender).toBe(false);
  });
  it('holdText is false when nothing renders even if voiceOnly set', () => {
    expect(decideVoice({ isFinalUserReply: false, voiceIntent: true, voiceOnly: true, hasText: true, folder: 'jarvis' }).holdText).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- decide-voice`
Expected: FAIL — "Cannot find module './decide-voice.js'".

- [ ] **Step 3: Write minimal implementation**

`src/modules/voice/decide-voice.ts`:

```ts
export interface DecideVoiceInput {
  isFinalUserReply: boolean;
  voiceIntent: boolean;
  /** Hold the text behind a placeholder until the audio is ready (voice-only mode). */
  voiceOnly: boolean;
  hasText: boolean;
  /** Agent group folder. Voice name == folder (1:1); the sidecar 400s for an
   *  unregistered voice and renderVoice returns null → graceful skip. */
  folder: string;
}

export interface DecideVoiceResult {
  shouldRender: boolean;
  voice: string;
  /** True when the client should hide the text until the audio lands. */
  holdText: boolean;
}

export function decideVoice(input: DecideVoiceInput): DecideVoiceResult {
  const shouldRender = input.isFinalUserReply && input.voiceIntent && input.hasText;
  return {
    shouldRender,
    voice: input.folder,
    holdText: shouldRender && input.voiceOnly,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- decide-voice`
Expected: PASS (6 tests).

- [ ] **Step 5: Rewire `delivery.ts` to use it (remove `isJarvis`, voice-by-folder)**

In `src/delivery.ts`, add the import near the other voice import (top of file, beside `import { renderVoice } …`):

```ts
import { decideVoice } from './modules/voice/decide-voice.js';
```

Replace the voice gate block (currently `const agentGroup = getAgentGroup(...)` through the closing `}` of the `if (...)` at ~line 475). The current block reads `voiceRow` (voice_intent only), gates on `isJarvis`, and hardcodes `'jarvis'`. New block (reads `voice_only` too, picks voice by folder, stamps hold below in Task 2.4 — for now just per-agent voice + no isJarvis):

> **Ordering:** the `voice_only` column does not exist until Task 2.2's migration. At Phase 1 the gate reads **only `voice_intent`** and passes `voiceOnly: false`. Task 2.4 (Phase 2) revises this same block to read `voice_only` and thread it through. So the `holdText`/`voice_failed` branch below is inert until Phase 2 — harmless and forward-compatible.

```ts
  const agentGroup = getAgentGroup(session.agent_group_id);
  const voiceRow = getDb()
    .prepare('SELECT voice_intent FROM sessions WHERE id = ?')
    .get(session.id) as { voice_intent: number } | undefined;
  const hasText = !!(content.text && typeof content.text === 'string' && content.text.trim());
  const voiceDecision = decideVoice({
    isFinalUserReply,
    voiceIntent: !!voiceRow?.voice_intent,
    voiceOnly: false, // wired in Task 2.4
    hasText,
    folder: agentGroup?.folder ?? '',
  });
  log.info('Voice delivery gate', {
    id: msg.id,
    sessionId: session.id,
    isFinalUserReply,
    folder: agentGroup?.folder,
    voiceIntent: voiceRow?.voice_intent ?? 0,
    shouldRender: voiceDecision.shouldRender,
    hasText,
  });
  if (voiceDecision.shouldRender) {
    const replyText = content.text as string;
    const vChannelType = msg.channel_type;
    const vPlatformId = msg.platform_id;
    const vThreadId = msg.thread_id;
    const vKind = msg.kind;
    const vAgentGroupId = session.agent_group_id;
    const vMsgId = msg.id;
    const vVoice = voiceDecision.voice;
    const vHoldText = voiceDecision.holdText;
    const isIos = vChannelType === 'ios-app-v2';
    const fmt: 'opus' | 'm4a' = isIos ? 'm4a' : 'opus';
    const fname = isIos ? 'reply.m4a' : 'reply.ogg';
    void (async () => {
      try {
        const audio = await renderVoice(replyText, vVoice, { format: fmt });
        if (audio) {
          await deliveryAdapter.deliver(
            vChannelType,
            vPlatformId,
            vThreadId,
            vKind,
            JSON.stringify({ operation: 'send_voice', reply_to_id: vMsgId }),
            [{ filename: fname, data: audio, operation: 'send_voice' as const }],
            vAgentGroupId,
          );
          log.info('Voice note delivered', { id: vMsgId, sessionId: session.id, voice: vVoice, format: fmt });
        } else if (vHoldText && isIos) {
          // Render failed in voice-only mode: tell the client to reveal the
          // text it was hiding behind the placeholder. (Task 2.4/2.5.)
          await deliveryAdapter.deliver(
            vChannelType,
            vPlatformId,
            vThreadId,
            vKind,
            JSON.stringify({ voice_failed: true, reply_to_id: vMsgId, text: '' }),
            undefined,
            vAgentGroupId,
          );
          log.info('Voice render failed — sent voice_failed', { id: vMsgId, sessionId: session.id });
        }
      } catch (err) {
        log.warn('Voice note delivery failed', { id: vMsgId, sessionId: session.id, err });
      }
    })();
  }
```

> Note: `getAgentGroup` is already imported and used earlier in the file (the duplicate `const agentGroup` at the old line ~420 is removed by this replacement — keep the earlier one at ~line 170). If TypeScript complains about a redeclared `agentGroup`, rename this local to `voiceAgentGroup`.

- [ ] **Step 6: Run the host suite + typecheck**

Run: `pnpm test -- delivery decide-voice` then `pnpm run build`
Expected: PASS; build clean.

- [ ] **Step 7: Commit**

```bash
git add src/modules/voice/decide-voice.ts src/modules/voice/decide-voice.test.ts src/delivery.ts
git commit -m "feat(voice): pick TTS voice by agent folder, drop isJarvis gate"
```

---

### Task 1.2: Sidecar — register 5 voices + source the 4 reference clips

**Files:**
- Modify: `services/jarvis-tts/config.py` (`VOICES` dict)
- Create (on the VDS, under the assets dir): `ref_<voice>.wav` + `ref_<voice>_text.txt` for greg, gordon, payne, scrooge

- [ ] **Step 1: Register all 5 voices in `config.py`**

Replace the `VOICES` dict in `services/jarvis-tts/config.py`:

```python
# Voice registry: voice name (== agent folder) -> (reference wav, reference
# transcript). Each clone is zero-shot from its ref clip, so the clip IS the
# voice — keep it clean (single speaker, ~6-12s, no music/SFX bed).
VOICES = {
    "jarvis": {  # J.A.R.V.I.S. (Iron Man RU dub)
        "ref_wav": str(ASSETS / "ref_workshop.wav"),
        "ref_text_file": str(ASSETS / "ref_workshop_text.txt"),
    },
    "greg": {  # Gregory House (Доктор Хаус RU dub)
        "ref_wav": str(ASSETS / "ref_greg.wav"),
        "ref_text_file": str(ASSETS / "ref_greg_text.txt"),
    },
    "gordon": {  # Гордон Рамзи (Адская кухня RU dub)
        "ref_wav": str(ASSETS / "ref_gordon.wav"),
        "ref_text_file": str(ASSETS / "ref_gordon_text.txt"),
    },
    "payne": {  # Майор Пейн (Major Payne RU dub)
        "ref_wav": str(ASSETS / "ref_payne.wav"),
        "ref_text_file": str(ASSETS / "ref_payne_text.txt"),
    },
    "scrooge": {  # Скрудж МакДак (DuckTales RU dub)
        "ref_wav": str(ASSETS / "ref_scrooge.wav"),
        "ref_text_file": str(ASSETS / "ref_scrooge_text.txt"),
    },
}
DEFAULT_VOICE = "jarvis"
```

- [ ] **Step 2: Source each reference clip (per-voice, on the VDS where the assets dir lives)**

For each of greg / gordon / payne / scrooge, obtain a clean single-speaker RU-dub clip and produce `ref_<voice>.wav` (mono) + `ref_<voice>_text.txt` (exact words). One-time tooling on the box:

```bash
# on VDS as the nanoclaw user
pipx install yt-dlp || pip install --user yt-dlp
# (faster-whisper for transcription, or transcribe by ear for a ~8s clip)
pip install --user faster-whisper
```

Per voice (example shape — pick the actual source + in/out timestamps by ear):

```bash
ASSETS=/opt/jarvis-tts/assets   # = JARVIS_TTS_ASSETS
V=greg                          # greg|gordon|payne|scrooge
SRC_URL="<youtube url of a clean RU-dub line>"
yt-dlp -x --audio-format wav -o /tmp/$V-src.wav "$SRC_URL"
# trim a clean ~8s mono window (no music/laughter/overlap); adjust -ss/-t:
ffmpeg -y -i /tmp/$V-src.wav -ss 00:00:12.0 -t 8.0 -ac 1 -ar 24000 "$ASSETS/ref_$V.wav"
# transcribe the EXACT words in that window:
python3 -c "from faster_whisper import WhisperModel as M; \
seg,_=M('small').transcribe('$ASSETS/ref_$V.wav', language='ru'); \
print(' '.join(s.text.strip() for s in seg))" > "$ASSETS/ref_${V}_text.txt"
cat "$ASSETS/ref_${V}_text.txt"   # eyeball: fix any mis-hears by hand
```

Candidate sources (search, then pick a clean mono line):
- **greg** — Доктор Хаус, RU dub monologue (e.g. "Все врут" scenes).
- **gordon** — Адская кухня / Кошмары на кухне RU dub (a calm-ish instructive line, not screaming — screaming clones badly).
- **payne** — Майор Пейн RU dub (a measured command line, not yelled).
- **scrooge** — DuckTales (Утиные истории) RU dub, Скрудж lines.

Quality bar per clip: one speaker, no background music, minimal reverb, ends on a complete word. A bad ref = a bad voice; re-trim until it's clean.

- [ ] **Step 3: Restart the sidecar and verify all 5 voices register**

```bash
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user restart jarvis-tts
curl -s http://127.0.0.1:8099/health
# expect: {"status":"ok","voices":["jarvis","greg","gordon","payne","scrooge"]}
```

- [ ] **Step 4: Smoke-render each new voice (m4a, like iOS)**

```bash
for V in greg gordon payne scrooge; do
  curl -s -X POST http://127.0.0.1:8099/tts -H 'content-type: application/json' \
    -d "{\"text\":\"Проверка голоса. Раз, два, три.\",\"voice\":\"$V\",\"fmt\":\"m4a\"}" \
    -o /tmp/voice-$V.m4a
  ffprobe -v error -show_entries stream=codec_name -of default=nk=1:nw=1 /tmp/voice-$V.m4a
done
# each should print: aac. Pull the files and LISTEN (subjective — Сергей signs off).
```

- [ ] **Step 5: Commit the config (asset binaries are NOT committed — they live on the box, mirroring the Jarvis ref)**

```bash
git add services/jarvis-tts/config.py
git commit -m "feat(tts): register greg/gordon/payne/scrooge voices"
```

> **Gate:** voice quality is subjective — Сергей A/B-listens each before Phase 2/3 ship. Phase 1's host change (Task 1.1) is already safe with partial voices (unregistered → graceful text fallback).

---

## Phase 2 — voice-only plumbing (protocol + host)

### Task 2.1: Protocol — add `voice_only` (InlineContext + Message) and `voice_failed` (Message)

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts` (InlineContext ~line 23; Message payload ~line 97)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` (InlineContext ~line 164; Message ~line 116)

- [ ] **Step 1: TS — extend the schemas**

In `shared/ios-app-protocol/v2.ts`, add to `InlineContext` (after `respond_by_voice`):

```ts
  respond_by_voice: z.boolean().optional(),
  // Voice-only mode: deliver the reply as a voice note with the text held back
  // (shown only after the audio is ready, transcript collapsed). Implies voice.
  voice_only: z.boolean().optional(),
```

In the `Message` payload, after `reply_to_id`:

```ts
      reply_to_id: z.string().min(1).optional(),
      // Set on the TEXT reply when the session is voice-only: the client hides
      // the text and shows a "записывает…" placeholder until the audio (a later
      // message with this id as reply_to_id) attaches.
      voice_only: z.boolean().optional(),
      // Set on a signal message (with reply_to_id) when voice render failed:
      // the client reveals the text it was hiding for that row.
      voice_failed: z.boolean().optional(),
```

- [ ] **Step 2: Swift — mirror the fields**

In `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`, `InlineContext` (after `respond_by_voice`):

```swift
        var respond_by_voice: Bool?
        /// Voice-only mode: reply as a voice note, text held until audio ready.
        var voice_only: Bool?
```

In `struct Message`, add the two fields + init params (the struct is `Codable` — synthesized; just add stored props and thread them through `init`):

```swift
        let reply_to_id: String?
        /// Set on the text reply in voice-only mode → client hides text + shows placeholder.
        let voice_only: Bool?
        /// Set on a signal (with reply_to_id) when render failed → client reveals text.
        let voice_failed: Bool?
        let actions: [Action]?
        init(thread_id: String, text: String, attachments: [Attachment]? = nil, context: InlineContext? = nil, agent_id: String? = nil, reply_to_id: String? = nil, voice_only: Bool? = nil, voice_failed: Bool? = nil, actions: [Action]? = nil) {
            self.thread_id = thread_id
            self.text = text
            self.attachments = attachments
            self.context = context
            self.agent_id = agent_id
            self.reply_to_id = reply_to_id
            self.voice_only = voice_only
            self.voice_failed = voice_failed
            self.actions = actions
        }
```

- [ ] **Step 3: Verify the protocol contract test still passes (optional fields → old fixtures still decode)**

Run: `pnpm test -- ios-app-protocol` (or the fixtures/contract test name).
Expected: PASS. If a fixture test enumerates fields strictly, add the optional fields as absent — no change needed for optional `.optional()` Zod fields.

- [ ] **Step 4: Commit**

```bash
git add shared/ios-app-protocol/v2.ts ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift
git commit -m "feat(protocol): voice_only on InlineContext+Message, voice_failed signal"
```

---

### Task 2.2: Host migration 021 — `sessions.voice_only`

**Files:**
- Create: `src/db/migrations/021-voice-only.ts`
- Modify: `src/db/migrations/index.ts`

- [ ] **Step 1: Write the migration**

`src/db/migrations/021-voice-only.ts`:

```ts
import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration021: Migration = {
  version: 21,
  name: 'voice-only',
  up(db: Database.Database) {
    // voice_only: when 1, delivery holds the text behind a placeholder and
    // delivers it together with the rendered voice note (iOS voice-only mode).
    // Persisted per-session like voice_intent because delivery (outbound) can't
    // see the inbound ios_context that sets it.
    db.prepare('ALTER TABLE sessions ADD COLUMN voice_only INTEGER NOT NULL DEFAULT 0').run();
  },
};
```

- [ ] **Step 2: Register it in the barrel**

In `src/db/migrations/index.ts`: add the import after `migration020`:

```ts
import { migration020 } from './020-factuality-level.js';
import { migration021 } from './021-voice-only.js';
```

and add `migration021,` to the `migrations` array after `migration020,`.

- [ ] **Step 3: Run the migration test + build**

Run: `pnpm test -- db-v2` then `pnpm run build`
Expected: PASS; build clean. (Migrations run on a fresh test DB in the db suite.)

- [ ] **Step 4: Commit**

```bash
git add src/db/migrations/021-voice-only.ts src/db/migrations/index.ts
git commit -m "feat(db): migration 021 sessions.voice_only"
```

---

### Task 2.3: Host — compute + persist `voice_only`

**Files:**
- Modify: `src/modules/voice/voice-intent.ts`
- Create test: `src/modules/voice/voice-intent.test.ts` (extend existing)
- Modify: `src/modules/voice/persist-intent.ts`

- [ ] **Step 1: Write the failing test**

Append to `src/modules/voice/voice-intent.test.ts`:

```ts
import { resolveVoiceOnly } from './voice-intent.js';

describe('resolveVoiceOnly', () => {
  it('true only when ios_context.voice_only is true', () => {
    expect(resolveVoiceOnly({ voice_only: true })).toBe(true);
  });
  it('false when absent or false or no context', () => {
    expect(resolveVoiceOnly({ voice_only: false })).toBe(false);
    expect(resolveVoiceOnly({})).toBe(false);
    expect(resolveVoiceOnly(null)).toBe(false);
  });
});
```

- [ ] **Step 2: Run it — fails (no export)**

Run: `pnpm test -- voice-intent`
Expected: FAIL — `resolveVoiceOnly is not a function`.

- [ ] **Step 3: Implement**

In `src/modules/voice/voice-intent.ts`, add:

```ts
export function resolveVoiceOnly(iosContext: { voice_only?: boolean } | null): boolean {
  return iosContext?.voice_only === true;
}
```

- [ ] **Step 4: Wire it into `persist-intent.ts`**

In `src/modules/voice/persist-intent.ts`:

Change the import:

```ts
import { resolveVoiceIntent, resolveVoiceOnly } from './voice-intent.js';
```

Widen the parsed type and `PersistVoiceIntentResult`:

```ts
export interface PersistVoiceIntentResult {
  voiceIntent: boolean;
  voiceOnly: boolean;
  hasIosContext: boolean;
  respondByVoice: boolean | null;
  groupVoiceMode: boolean;
}
```

```ts
  let parsed: { ios_context?: { respond_by_voice?: boolean; voice_only?: boolean } | null } = {};
```

Replace the persist + return tail:

```ts
  const voiceIntent = resolveVoiceIntent({ iosContext, groupVoiceMode });
  const voiceOnly = resolveVoiceOnly(iosContext);
  getDb()
    .prepare('UPDATE sessions SET voice_intent = ?, voice_only = ? WHERE id = ?')
    .run(voiceIntent ? 1 : 0, voiceOnly ? 1 : 0, input.sessionId);
  return {
    voiceIntent,
    voiceOnly,
    hasIosContext: !!iosContext,
    respondByVoice: iosContext?.respond_by_voice ?? null,
    groupVoiceMode,
  };
```

- [ ] **Step 5: Run tests + build**

Run: `pnpm test -- voice-intent persist` then `pnpm run build`
Expected: PASS; build clean. (If `adapter-route.test.ts` / `router.test.ts` assert the `persistVoiceIntent` return shape, add `voiceOnly: false` to their expectations.)

- [ ] **Step 6: Commit**

```bash
git add src/modules/voice/voice-intent.ts src/modules/voice/voice-intent.test.ts src/modules/voice/persist-intent.ts
git commit -m "feat(voice): persist voice_only on the session"
```

---

### Task 2.4: Host — stamp the text envelope when holding for voice-only

**Files:**
- Modify: `src/delivery.ts` (the iOS `deliverContent` stamp, ~lines 383–392)

The voice render closure already emits `voice_failed` on null (Task 1.1, Step 5). This task makes the *text* envelope carry `voice_only: true` so the client hides it. The hold decision is `voiceDecision.holdText` — but `voiceDecision` is computed *after* the text is delivered. Compute the session voice row once, *before* the `deliverContent` block, and reuse it below.

- [ ] **Step 1: Hoist the session voice read above the text delivery**

In `src/delivery.ts`, immediately before the `const deliverContent =` block (~line 389), insert:

```ts
  // Voice flags for this session (read once; reused by the gate below). Stamping
  // voice_only on the iOS text envelope makes the client hide the text and show
  // a placeholder until the rendered audio attaches by reply_to_id.
  const sessVoice = getDb()
    .prepare('SELECT voice_intent, voice_only FROM sessions WHERE id = ?')
    .get(session.id) as { voice_intent: number; voice_only: number } | undefined;
  const willHoldForVoice =
    msg.channel_type === 'ios-app-v2' &&
    isFinalUserReply &&
    !!sessVoice?.voice_intent &&
    !!sessVoice?.voice_only &&
    !!(content.text && typeof content.text === 'string' && content.text.trim());
```

- [ ] **Step 2: Stamp `voice_only` into the iOS text envelope**

Replace the `deliverContent` ternary:

```ts
  const deliverContent =
    msg.channel_type === 'ios-app-v2'
      ? JSON.stringify({
          ...(content as Record<string, unknown>),
          id: (content as { id?: string }).id ?? msg.id,
          ...(willHoldForVoice ? { voice_only: true } : {}),
        })
      : msg.content;
```

- [ ] **Step 3: Reuse `sessVoice` in the voice gate (avoid the duplicate read)**

In the voice gate block from Task 1.1 Step 5, replace the `const voiceRow = getDb()…` read with a reuse of `sessVoice`:

```ts
  const agentGroup = getAgentGroup(session.agent_group_id);
  const hasText = !!(content.text && typeof content.text === 'string' && content.text.trim());
  const voiceDecision = decideVoice({
    isFinalUserReply,
    voiceIntent: !!sessVoice?.voice_intent,
    voiceOnly: !!sessVoice?.voice_only,
    hasText,
    folder: agentGroup?.folder ?? '',
  });
```

(Delete the now-unused `voiceRow` declaration. The `log.info('Voice delivery gate', …)` should reference `sessVoice?.voice_intent` / `sessVoice?.voice_only`.)

- [ ] **Step 4: Build + run delivery tests**

Run: `pnpm test -- delivery` then `pnpm run build`
Expected: PASS; build clean.

- [ ] **Step 5: Commit**

```bash
git add src/delivery.ts
git commit -m "feat(voice): hold+stamp iOS text envelope for voice-only mode"
```

---

### Task 2.5: Host — iOS adapter passes `voice_only` / `voice_failed` through

**Files:**
- Modify: `src/channels/ios-app/v2/index.ts` (envelope build, ~lines 690–702)

- [ ] **Step 1: Read the flags from content and add them to the payload**

In `src/channels/ios-app/v2/index.ts`, after the `replyToId` line (~690):

```ts
      const replyToId = typeof content.reply_to_id === 'string' ? content.reply_to_id : undefined;
      const voiceOnly = content.voice_only === true;
      const voiceFailed = content.voice_failed === true;
```

In the `payload` object literal, after the `reply_to_id` spread:

```ts
          ...(replyToId ? { reply_to_id: replyToId } : {}),
          ...(voiceOnly ? { voice_only: true } : {}),
          ...(voiceFailed ? { voice_failed: true } : {}),
```

- [ ] **Step 2: Build**

Run: `pnpm run build`
Expected: clean. (If `content` is typed `Record<string, unknown>`, the `=== true` comparisons are fine.)

- [ ] **Step 3: Commit**

```bash
git add src/channels/ios-app/v2/index.ts
git commit -m "feat(ios-adapter): forward voice_only/voice_failed to device"
```

---

## Phase 3 — iOS voice-only UX

### Task 3.1: iOS storage — `voice_only` column, StoredMessage field, insert + clear

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift` (add migration after v9, ~line 150)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift` (StoredMessage ~line 27; mapRow ~line 440; insertInbound ~line 200; new clearVoiceOnly)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/MessageTimeline.swift` (seed mapper ~line 37)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/VoiceOnlyStoreTests.swift` (new)

- [ ] **Step 1: Schema migration**

In `Schema.swift`, after the `v9-message-edited` migration block (before `try m.migrate(writer)`):

```swift
        m.registerMigration("v10-voice-only") { db in
            // Voice-only rows: text hidden behind a placeholder until the
            // rendered voice note attaches. 1 = voice-only; cleared to 0 on
            // render failure (text revealed).
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN voice_only INTEGER NOT NULL DEFAULT 0;")
        }
```

- [ ] **Step 2: StoredMessage field**

In `ConversationStoreV2.swift`, add to `struct StoredMessage` (after `edited`):

```swift
    var edited: Bool = false
    var voiceOnly: Bool = false
```

- [ ] **Step 3: Decode it in the shared mapper + the timeline seed**

`ConversationStoreV2.swift` `mapRow` (~line 456), after `edited:`:

```swift
            edited: row["edited"] ?? false,
            voiceOnly: row["voice_only"] ?? false
```

`MessageTimeline.swift` seed mapper (~line 50), after `edited:`:

```swift
                    edited: row["edited"] ?? false,
                    voiceOnly: row["voice_only"] ?? false
```

- [ ] **Step 4: Persist on insert + add `clearVoiceOnly`**

`ConversationStoreV2.swift` `insertInbound` — extend the column list, the placeholders, and the args:

```swift
            try db.execute(sql: """
                INSERT INTO messages
                  (id, dir, seq, text, attachments_json, actions_json, status, ts, created_at, agent_id, voice_only)
                VALUES (?, 'in', ?, ?, ?, ?, 'new', ?, ?, ?, ?)
            """, arguments: [envelope.id, envelope.seq, message.text, attachmentsJSON, actionsJSON, now, now, agentId, (message.voice_only ?? false)])
```

Add near `markActionAnswered`:

```swift
    /// Clear the voice-only flag on a row (render failed → reveal its text).
    /// Returns whether a row changed.
    @discardableResult
    func clearVoiceOnly(rowId: String) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET voice_only=0 WHERE id=?", arguments: [rowId])
            return db.changesCount > 0
        }
    }
```

- [ ] **Step 5: Write the store unit test**

`ios/JarvisApp/Sources/JarvisAppTests/VoiceOnlyStoreTests.swift`:

```swift
import XCTest
import GRDB
@testable import Jarvis

final class VoiceOnlyStoreTests: XCTestCase {
    private func makeStore() throws -> ConversationStoreV2 {
        let q = try DatabaseQueue()
        try Schema.migrate(q)
        return ConversationStoreV2(writer: q)
    }

    private func inboundEnvelope(id: String, text: String, voiceOnly: Bool) -> (V2.Envelope, V2.Message) {
        let msg = V2.Message(thread_id: "t", text: text, voice_only: voiceOnly)
        let env = V2.Envelope(v: V2.protocolVersion, kind: .data, type: .message,
                              id: id, seq: 1, ts: "2026-06-25T00:00:00Z",
                              payload: .message(msg))
        return (env, msg)
    }

    func testInsertPersistsVoiceOnly() throws {
        let store = try makeStore()
        let (env, msg) = inboundEnvelope(id: "m1", text: "hi", voiceOnly: true)
        try store.insertInbound(envelope: env, message: msg, agentId: "jarvis")
        let rows = try ConversationStoreV2.windowedRows(store.writer.read { $0 }, perAgent: 10)
        XCTAssertEqual(rows.first { $0.id == "m1" }?.voiceOnly, true)
    }

    func testClearVoiceOnlyRevealsText() throws {
        let store = try makeStore()
        let (env, msg) = inboundEnvelope(id: "m2", text: "hi", voiceOnly: true)
        try store.insertInbound(envelope: env, message: msg, agentId: "jarvis")
        let changed = try store.clearVoiceOnly(rowId: "m2")
        XCTAssertTrue(changed)
    }
}
```

> If `windowedRows(_:perAgent:)` can't take a `Database` pulled out of `read` like that, replace the fetch with `try store.writer.read { try ConversationStoreV2.windowedRows($0, perAgent: 10) }`. Mirror however existing store tests open a DB — check `Sources/JarvisAppTests` for a precedent and match it.

- [ ] **Step 6: Build the app for sim (compile gate)**

Run (XcodeBuildMCP, after `session_show_defaults`): `build_sim`
Expected: BUILD SUCCEEDED. (Run the unit tests via `test_sim` if the test target builds; otherwise the build gate + on-device check per memory.)

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift \
        ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift \
        ios/JarvisApp/Sources/JarvisApp/Storage/MessageTimeline.swift \
        ios/JarvisApp/Sources/JarvisAppTests/VoiceOnlyStoreTests.swift
git commit -m "feat(ios): persist voice_only on messages + clearVoiceOnly"
```

---

### Task 3.2: iOS model — `ChatMessage.voiceOnly` propagated from rows

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/Message.swift` (ChatMessage ~line 76)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift` (`toChatMessage` ~line 569 combined branch + the plain-text branch below ~line 590)

- [ ] **Step 1: Add the field to ChatMessage**

`Message.swift`, after `var edited: Bool = false`:

```swift
    var edited: Bool = false
    /// True when this row is a voice-only reply: pending → placeholder, ready →
    /// voice note with a collapsed transcript. Drives MessageRow's branch.
    var voiceOnly: Bool = false
```

- [ ] **Step 2: Set it in the combined-audio branch**

`WebSocketClientV2.swift` `toChatMessage`, in the audio branch (after `combined.edited = row.edited`, ~line 573):

```swift
                combined.edited = row.edited
                combined.voiceOnly = row.voiceOnly
```

- [ ] **Step 3: Set it on the plain-text row(s)**

In the same function, find where a plain `.text` `ChatMessage` is built for a row with no attachment (the path a *pending* voice-only row takes — it has no audio yet). Set `voiceOnly` there too. For the standalone text message built near the end of `toChatMessage` (the `ChatMessage(id: row.id, role:, content: .text(row.text) …)` or `ChatMessage.text(...)` construction), add:

```swift
            m.voiceOnly = row.voiceOnly
```

(Apply to each `ChatMessage` the text path returns for a bare row. Caption bubbles attached to image/file rows don't need it — voice-only never has image attachments.)

- [ ] **Step 4: Build for sim**

Run: `build_sim`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/Message.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift
git commit -m "feat(ios): carry voiceOnly onto ChatMessage rows"
```

---

### Task 3.3: iOS MessageRow — placeholder + collapsed transcript

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift` (`textRow` ~line 51; add `VoicePendingView` + a collapsed-transcript wrapper)

- [ ] **Step 1: Branch `textRow` on voice-only state**

Replace the body of `textRow(_:)` content `VStack` inner block (the part from `metaRow` through the text `Group`) so it picks one of three renderings. Replace lines ~56–74 with:

```swift
                    metaRow
                    if message.voiceOnly && message.attachedAudio == nil {
                        // Pending: render is in flight, hide text behind a placeholder.
                        VoicePendingView()
                    } else if message.voiceOnly, let audio = message.attachedAudio {
                        // Ready: voice note + collapsed (tap-to-expand) transcript.
                        AudioNoteView(info: audio, messageId: message.id, player: audioPlayer)
                        if !text.isEmpty {
                            CollapsibleTranscript(text: text, isUser: isUser)
                        }
                    } else {
                        // Normal: voice note (if any) above always-visible text.
                        if let audio = message.attachedAudio {
                            AudioNoteView(info: audio, messageId: message.id, player: audioPlayer)
                        }
                        if !(text.isEmpty && message.attachedAudio != nil) {
                            Group {
                                if isUser {
                                    Text(text).font(.system(size: 14))
                                } else {
                                    MarkdownText(text, fontSize: 14)
                                }
                            }
                            .foregroundStyle(isUser ? .white : Theme.assistantText)
                            .lineSpacing(2)
                            .contextMenu {
                                contextMenuButtons(text)
                            }
                        }
                    }
```

- [ ] **Step 2: Add `VoicePendingView` (pulsing mic + "записывает…")**

At the end of `MessageRow.swift` (file scope, beside `AudioNoteView`):

```swift
/// Placeholder shown for a voice-only reply while the server renders the audio.
/// The text is withheld until the voice note lands; this fills the wait.
private struct VoicePendingView: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accent)
                .opacity(pulse ? 1.0 : 0.35)
            Text("записывает голосовое…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.assistantText.opacity(0.7))
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("Записывается голосовое сообщение")
    }
}
```

- [ ] **Step 3: Add `CollapsibleTranscript` (Telegram-style "..." disclosure)**

Also at file scope in `MessageRow.swift`:

```swift
/// Voice-only transcript: collapsed behind a "Показать текст" control, expands
/// in place. Mirrors Telegram hiding the transcription under the voice note.
private struct CollapsibleTranscript: View {
    let text: String
    let isUser: Bool
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.up" : "text.bubble")
                        .font(.system(size: 11, weight: .semibold))
                    Text(expanded ? "Скрыть текст" : "Показать текст")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            if expanded {
                Group {
                    if isUser { Text(text).font(.system(size: 14)) }
                    else { MarkdownText(text, fontSize: 14) }
                }
                .foregroundStyle(isUser ? .white : Theme.assistantText)
                .lineSpacing(2)
                .transition(.opacity)
            }
        }
    }
}
```

- [ ] **Step 4: Build for sim**

Run: `build_sim`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift
git commit -m "feat(ios): voice-only placeholder + collapsible transcript"
```

---

### Task 3.4: iOS — Settings toggle + send wiring

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift` (~line 16)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift` (Voice section ~line 70)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift` (`send` ~line 258; `makeInlineContext` ~line 643)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift` (`sendMessage` ~line 209)

- [ ] **Step 1: Add the persisted setting**

`AppSettings.swift`, after `autoSpeak` (~line 16):

```swift
    @ObservationIgnored @AppStorage("autoSpeak")     var autoSpeak    = false
    /// Global voice-only mode: every reply comes back as a voice note (text held
    /// until the audio is ready, transcript collapsed).
    @ObservationIgnored @AppStorage("voiceOnlyMode") var voiceOnlyMode = false
```

- [ ] **Step 2: Add the toggle to the Voice section**

`SettingsView.swift`, in the `settingsSection(title: "Голос")` block (after the `autoSpeak` toggle, ~line 71):

```swift
                    settingsSection(title: "Голос") {
                        settingsToggle(icon: "speaker.wave.2", label: "Озвучивать ответы на голос", isOn: $settings.autoSpeak)
                        settingsToggle(icon: "waveform", label: "Отвечать только голосом", isOn: $settings.voiceOnlyMode)
                    }
```

(Match the exact surrounding structure — keep whatever wrapping the section already has; only the second `settingsToggle` line is new.)

- [ ] **Step 3: Thread `voiceOnly` through `ws.send` + InlineContext**

`WebSocketClientV2.swift` `send(...)` signature — add a param:

```swift
        agentId: String = "jarvis",
        respondByVoice: Bool = false,
        voiceOnly: Bool = false
    ) {
```

and pass it into `makeInlineContext`:

```swift
        let inline = makeInlineContext(timezone: timezone, status: status, raw: context,
                                       respondByVoice: respondByVoice ? true : nil,
                                       voiceOnly: voiceOnly ? true : nil)
```

`makeInlineContext(...)` — add the param + field:

```swift
    private func makeInlineContext(timezone: String, status: String?, raw: [String: Any]?,
                                   respondByVoice: Bool? = nil, voiceOnly: Bool? = nil) -> V2.InlineContext? {
```

```swift
        return V2.InlineContext(
            location: location,
            timestamp: now,
            timezone: timezone,
            locality: locality,
            respond_by_voice: respondByVoice,
            voice_only: voiceOnly
        )
```

- [ ] **Step 4: Set it from `AppCoordinator.sendMessage`**

`AppCoordinator.swift` `sendMessage`, replace the `wantVoiceReply` lines + the `ws.send` call (~209–219):

```swift
        // Voice-only mode forces a server voice reply for every send (typed or
        // dictated). Otherwise the orb / autoSpeak path decides as before.
        let voiceOnly = settings.voiceOnlyMode
        let wantVoiceReply = voiceOnly || forceVoice || (settings.autoSpeak && lastSendWasVoice)
        lastSendWantedServerVoice = wantVoiceReply
        ws.send(
            text: text,
            timezone: TimeZone.current.identifier,
            status: emoji.isEmpty ? nil : emoji,
            attachments: attachments,
            context: ctx,
            agentId: agentId,
            respondByVoice: wantVoiceReply,
            voiceOnly: voiceOnly
        )
```

- [ ] **Step 5: Build for sim**

Run: `build_sim`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift
git commit -m "feat(ios): global voice-only toggle wired into send"
```

---

### Task 3.5: iOS — handle the `voice_failed` signal (reveal text)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` (`routeInboundMessage` ~line 283)

- [ ] **Step 1: Short-circuit a voice_failed signal to clearVoiceOnly**

In `routeInboundMessage`, right after the dedup block (after `try store.recordDedup(...)`, before the voice-note merge `if let replyTo = message.reply_to_id, let audio …`):

```swift
        // Voice-only render failed: reveal the text that was held behind the
        // placeholder for that row. Carries reply_to_id + voice_failed, no audio.
        if message.voice_failed == true, let target = message.reply_to_id {
            _ = try? store.clearVoiceOnly(rowId: target)
            try await sendAck(id: envelope.id, seq: envelope.seq ?? 0)
            try await sendStatus(.delivered, ids: [envelope.id])
            if let seq = envelope.seq {
                let current = try store.cursor(.lastSeenInbound)
                if seq > current { try store.setCursor(.lastSeenInbound, seq) }
            }
            return
        }
```

- [ ] **Step 2: Build for sim**

Run: `build_sim`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift
git commit -m "feat(ios): reveal text on voice_failed signal"
```

---

### Task 3.6: iOS — version bump + xcodegen + final build

**Files:**
- Modify: `ios/JarvisApp/project.yml` (~lines 74–75)

- [ ] **Step 1: Bump versions**

`project.yml`: `MARKETING_VERSION: "1.8.0"` (new feature), `CURRENT_PROJECT_VERSION: "33"`.

- [ ] **Step 2: Regenerate the project**

Run (from `ios/JarvisApp/`): `xcodegen generate`
Expected: "Created project at …".

- [ ] **Step 3: Clean build for sim**

Run: `build_sim`
Expected: BUILD SUCCEEDED, 0 warnings.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "chore(ios): bump to 1.8.0 build 33 (per-agent voices + voice-only)"
```

---

## Deploy (after all tasks land + Сергей signs off on voice quality)

- [ ] **Host + sidecar (VDS):**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -lc "cd ~/nanoclaw && git pull && pnpm run build && \
  XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user restart nanoclaw && \
  XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user restart jarvis-tts"'
```

(Reference clip wavs/texts are placed under the assets dir on the box in Task 1.2 — they are not in git.)

- [ ] **iOS:** Сергей rebuilds + installs build 33 on the iPhone.

- [ ] **Verify e2e (on device):**
  1. Settings → Голос → "Отвечать только голосом" ON.
  2. Send a typed message → "записывает голосовое…" placeholder appears, no text.
  3. Audio lands (~2-3 min) → placeholder becomes a voice note; "Показать текст" reveals/collapses the transcript; play + progress work.
  4. Toggle OFF → normal text replies; orb voice still text-first with visible transcript.
  5. Talk to a different agent (e.g. Greg) → its own voice plays.

---

## Notes / risks

- **Render latency** (~2-3 min CPU) is unchanged — voice-only just makes the wait visible as a placeholder. Host `voice_failed` fires within the 240s `renderVoice` timeout on failure, so a stuck placeholder self-heals without a client timer. (A client backstop timer was considered and dropped as redundant given the host signal; revisit if a delivery drop ever strands a placeholder.)
- **Voice quality is the long pole** — bad ref clip = bad clone. Budget iteration per character in Task 1.2; gate ship on Сергей's listen.
- **`build_sim` is truth** for iOS; SourceKit "No such module" diagnostics in the editor are false.
