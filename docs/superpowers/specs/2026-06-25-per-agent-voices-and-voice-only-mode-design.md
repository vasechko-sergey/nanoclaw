# Per-agent voices + voice-only mode

**Date:** 2026-06-25
**Status:** Approved (design)

## Problem

Today only Jarvis has a TTS voice, and voice delivery is always text-first
(text lands instantly, the rendered voice note follows minutes later and
attaches to its text row by `reply_to_id`). Two gaps:

1. The other four agents (Greg, Gordon, Payne, Scrooge) have written personas
   based on recognizable characters but speak only as text.
2. There is no way to say "answer me by voice only" — where the text is *not*
   shown before the audio is ready, and the transcript is tucked away like a
   Telegram voice note.

## Goals

- Each agent gets its own cloned voice, matched to its persona's source
  character.
- A global app toggle "Отвечать только голосом". When on: the agent's reply is
  delivered as a voice note with the text held back (shown only after the audio
  is ready), with a "записывает голосовое…" placeholder filling the render wait,
  and the transcript collapsed by default (expand on tap).

## Non-goals

- No Telegram-side voice-only behavior. The toggle rides the iOS InlineContext,
  which Telegram sessions never send, so voice-only is inherently iOS-only.
- No per-agent / per-conversation toggle. One global switch (chosen for
  simplicity; per-agent was considered and rejected as premature).
- No change to the existing orb / text-first voice path (`respond_by_voice`
  without voice-only) — it keeps delivering text immediately with a *visible*
  transcript.

## Persona → voice mapping

Confirmed from the group persona files (`groups/<agent>/CLAUDE.md`):

| Agent  | Folder   | Persona source        | Reference clip to source (RU dub) |
|--------|----------|-----------------------|-----------------------------------|
| Jarvis | `jarvis` | J.A.R.V.I.S.          | already have (`ref_workshop.wav`) |
| Greg   | `greg`   | Gregory House         | Доктор Хаус                       |
| Gordon | `gordon` | Гордон Рамзи          | Адская кухня / Кошмары на кухне    |
| Payne  | `payne`  | Майор Пейн            | Major Payne                       |
| Scrooge| `scrooge`| Скрудж МакДак (+Эбенизер) | DuckTales                     |

Voice name == agent folder (1:1, no separate map table).

## Design

### Phase 1 — Per-agent voices (sidecar + host)

**Sidecar (`services/jarvis-tts/`)**
- `config.py` `VOICES` grows 1 → 5 entries keyed by folder name, each
  `{ref_wav, ref_text_file}` under the assets dir. `DEFAULT_VOICE` stays
  `jarvis`.
- Sourcing pipeline per new voice (same as Jarvis):
  1. Obtain a clean ~6–12s single-speaker RU-dub clip (no music/SFX bed). Pick
     an already-clean clip; do **not** run source separation to make the ref
     (memory: demucs is a music *detector* only — separated audio produces
     "странные частоты").
  2. ffmpeg → wav (mono).
  3. Transcribe the exact spoken words → `ref_<voice>_text.txt`.
  4. Drop wav + text into assets, add a `VOICES` entry, restart `jarvis-tts`.
- `/health` already returns `list(VOICES.keys())` — used to eyeball which voices
  are live.

**Host (`src/delivery.ts`)**
- Remove the `isJarvis` gate. Select voice by folder:
  `renderVoice(text, agentGroup.folder, { format })`.
- Graceful degradation: if a folder has no registered voice yet, the sidecar
  returns 400 → `renderVoice` returns null → voice note is skipped. In
  non-voice-only mode the text was already delivered, so nothing breaks. This
  makes the Phase 1 host change safe to ship before all four refs exist.
- Extract a pure helper `decideVoice({ isFinalUserReply, voiceIntent, folder,
  hasText })` → `{ shouldRender, voice }` so the selection logic is unit-tested
  (the fire-and-forget render closure itself is not).

### Phase 2 — Voice-only plumbing (protocol + host)

**Mechanism: "send text flagged, client hides it" (approach A).**
Rejected alternative B (withhold text entirely + separate placeholder message +
text carried inside the voice payload) — more new surface, diverges from the
current text-first path, more failure modes. A reuses the id-correlation
plumbing already built (text row id == voice `reply_to_id`).

Flow when voice-only is on:
1. Agent produces its final text reply.
2. Host delivers that text message as today (so it is `markDelivered` and never
   re-sent), but stamps the envelope `voice_only: true, voice_pending: true`.
3. Client receives it, **hides the text**, and renders a "записывает
   голосовое…" placeholder for that row.
4. Host renders the voice (fire-and-forget) and delivers the audio with
   `reply_to_id` = the text row id (existing path).
5. Client attaches the audio by id, clears `voice_pending` → the row becomes a
   voice note with a **collapsed** transcript.

The text bytes reach the device early (step 2) but are never *displayed* before
the audio (step 5) — honoring "текст не раньше звука" in the only sense the user
perceives.

Failure / timeout:
- If `renderVoice` returns null (sidecar down, unknown voice, etc.), the host
  delivers a `voice_failed` signal for that id → client reveals the text as a
  normal message.
- Client also keeps a ~5 min backstop timer per pending row → reveal text if no
  audio and no failure signal arrived (covers a host/delivery drop).

Additions:
- `shared/ios-app-protocol/v2.ts`: InlineContext gains `voice_only?: boolean`;
  outbound Message payload gains `voice_only?: boolean` and `voice_pending?:
  boolean`; a `voice_failed` operation (or a `voice_failed?: boolean` flag on the
  envelope carrying the original `reply_to_id`).
- `sessions.voice_only` column (central DB migration). `voice_intent` is already
  persisted to the session at inbound time because delivery (outbound) cannot
  see the inbound `iosContext`; `voice_only` follows the same pattern.
- `src/modules/voice/persist-intent.ts`: also compute and persist `voice_only`
  (from `iosContext.voice_only`). `delivery.ts` reads it alongside
  `voice_intent`.
- `src/modules/voice/voice-intent.ts`: unchanged (voice_intent still gates
  whether to render at all; voice_only is an independent flag for *how* to
  deliver).

### Phase 3 — iOS voice-only UX

**Settings**
- One global `@AppStorage("voiceOnlyMode")` toggle, "Отвечать только голосом".
- In `AppCoordinator.sendMessage`, the InlineContext gets:
  - `respond_by_voice = voiceOnlyMode || orbWantedVoice`
  - `voice_only = voiceOnlyMode`
- With the toggle off, behavior is exactly as today (typed → text; orb →
  text-first voice). With it on, every send (typed or orb) is voice-only.

**Placeholder**
- `ChatMessage` gains `voiceOnly: Bool` and a pending state (e.g. `voicePending:
  Bool`, or an enum `pending / ready / failed`).
- `MessageRow`: `voicePending && no audio` → "записывает голосовое…" bubble with
  a pulsing mic; the text is not shown.

**Collapsed transcript**
- Applies **only** to `voiceOnly` rows. Waveform + a "..." disclosure control;
  tap to expand the transcript.
- Non-voice-only voice notes (orb / text-first) keep the transcript visible —
  the text was already read before the audio attached, so collapsing it after
  the fact would be jarring.

## Data flow (voice-only, happy path)

```
iOS send (voiceOnlyMode on)
  └─ InlineContext { respond_by_voice:true, voice_only:true }
       └─ host inbound: persist-intent → sessions.voice_intent=1, voice_only=1
            └─ container agent → final text reply (outbound.db)
                 └─ delivery.ts: voice_intent && voice_only
                      ├─ deliver text msg  { voice_only:true, voice_pending:true, id:M }
                      │     └─ iOS: hide text, show "записывает…" placeholder for row M
                      └─ renderVoice(text, folder) ──(async)──┐
                            ├─ ok  → deliver audio { reply_to_id:M }
                            │          └─ iOS: attach audio to M, clear pending → voice note + collapsed transcript
                            └─ null → deliver { voice_failed, reply_to_id:M }
                                       └─ iOS: reveal text on row M
```

## Testing

- **Host:** unit-test `decideVoice` (folder → voice, gating); unit-test
  `persist-intent` persists `voice_only`. Delivery's render closure is
  fire-and-forget → not unit-tested; covered by the helper + manual.
- **Sidecar:** `/health` lists all 5 voices once refs are registered; per-voice
  A/B listen is manual (Сергей) — voice quality is subjective.
- **iOS:** `build_sim` clean; behavioral verification (placeholder → swap,
  collapse/expand, failure reveal) on-device by Сергей. Bump
  `CURRENT_PROJECT_VERSION` + `xcodegen generate` + commit pbxproj on every iOS
  change.

## Deploy

- Sidecar: VDS `git pull` of repo copy + drop assets + `systemctl --user restart
  jarvis-tts`. Asset wavs/texts live on the VDS under the assets dir; large
  binaries are not committed (mirror the existing Jarvis ref handling).
- Host: VDS `git pull && pnpm run build && systemctl --user restart nanoclaw`.
  Agent-runner is host-mounted (no image rebuild). The `sessions.voice_only`
  migration runs on host start.
- iOS: rebuild + install by Сергей.

## Sequencing

Phase 1 is independent and shippable on its own (just adds voices, no UX
change). Phase 2 must precede Phase 3 (protocol + host before client). Sourcing
the four reference clips is the long pole of Phase 1 and gates voice quality for
everything downstream.

## Open risks

- Render latency (~2–3 min CPU per short line) is unchanged. Voice-only makes
  the wait user-visible as a placeholder; if it feels too long in practice, a
  future lever is a faster NFE/step setting or a GPU box, out of scope here.
- Reference-clip quality drives clone quality. A noisy or music-bedded clip
  yields a bad voice; budget iteration per character.
