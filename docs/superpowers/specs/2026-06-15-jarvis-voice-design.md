# Jarvis Voice — Design Spec

**Date:** 2026-06-15
**Status:** Approved (design); ready for implementation plan
**Scope:** Give the Jarvis agent a spoken voice — a self-hosted, offline-rendered clone of the Russian Iron Man J.A.R.V.I.S. dub — delivered as voice notes in Telegram and the iOS app.

---

## 1. Goal

When Jarvis replies and the user is in "voice mode", deliver the reply as a **voice note** spoken in a cloned J.A.R.V.I.S. voice, alongside the text (so the text can be read too). No cloud TTS API; rendering runs on the VDS (CPU, no GPU).

## 2. Voice (locked)

The voice was chosen and confirmed during brainstorming (variant "A · workshop").

- **Engine:** F5-TTS-RU, checkpoint `F5TTS_v1_Base_accent_tune/model_last_inference.safetensors` (HF `Misha24-10/F5-TTS_RUSSIAN`, ~1.35 GB) + vocab `F5TTS_v1_Base/vocab.txt`, model arch `F5TTS_v1_Base`.
- **Stress:** RUAccent (`turbo3.1`) marks `+` before the stressed vowel; the stressed text is fed to F5. Mandatory for natural Russian.
- **Reference (voice clone):** ~10 s of clean J.A.R.V.I.S. lines (Вячеслав Баранов dub) from a music-free workshop scene, extracted from the **untouched original** audio. The curated reference (`ref_workshop.wav`) and recipe live at `/Users/serg/jarvis-voice/` on the dev Mac and must be deployed to the VDS.
- **Hard lesson:** demucs vocal-separation ruins the reference (artefacts / "strange frequencies"). demucs is used **only as a music detector** to find music-free segments; the reference is cut from the original. The sidecar does **not** run demucs at request time.

## 3. Scope & non-goals

- **In scope:** Jarvis only. Telegram **and** iOS app.
- **Out of scope (now):** other agents (Greg/Gordon/Payne/Scrooge) — revisit after a couple of days of real use; the sidecar is built voice-parametrised so adding them later is a config change (new reference clip), not a rewrite.
- **Non-goal:** real-time / low-latency speech. Voice notes are asynchronous; multi-second-to-minute render latency on CPU is acceptable.
- **Non-goal:** GPU inference in production. CPU only (VDS gets a cheap RAM/CPU bump).

## 4. Architecture

```
  iOS app (autoSpeak + voice input)                Telegram (/voice on)
        │  respond_by_voice=true in InlineContext         │ per-chat voice flag
        ▼                                                  ▼
  host inbound ─────────────► session voice-intent flag ◄──┘
        │
   agent replies (TEXT only — unchanged) ──► outbound.db
        │
   host delivery:
     1. deliver TEXT immediately (today's path)
     2. if voice-intent: POST reply text ──► TTS sidecar ──► opus
                                                  │ (F5 + RUAccent + ref, warm in RAM, CPU)
     3. deliver voice note via adapter ◄──────────┘
        ├─ Telegram: sendVoice(opus) [text already sent]
        └─ iOS: audio attachment (kind:"audio") [app plays it; "показать текст" reveals text]
```

**Key architectural decision — host-driven rendering.** The agent stays voice-agnostic (emits text only). The host decides whether a reply becomes voice, based on a per-session/per-chat voice-intent flag set from inbound metadata. Rejected alternative: agent-driven (agent marks each reply for speech) — more flexible but requires agent-runner changes and agent cooperation; YAGNI for an on/off voice mode.

**Text-first, voice-follows.** Text is delivered immediately (unchanged). The voice note arrives when rendering finishes (seconds-to-minutes later). The text message *is* the "show text" affordance.

## 5. Components

### 5.1 TTS sidecar service (new)

- Standalone Python process on the VDS. Loads F5 + accent_tune checkpoint + RUAccent + the Jarvis reference **once**, kept warm in RAM.
- HTTP endpoint: `POST /tts { text, voice?="jarvis" } → audio/ogg (opus)`. Returns Telegram-ready opus; also expose raw wav if iOS needs a different container.
- Pipeline per request: strip markdown / normalise → RUAccent stress → F5 infer (reference cached per voice) → encode opus (mono, ~24 kHz source). Cap input length; split long replies into chunks and concatenate.
- Runs as a managed service (systemd on the Linux VDS; the repo's launchd story is macOS-only — match the VDS init system). Health endpoint for the host to check readiness.
- **Voice registry:** `voice → {reference wav, reference text}`. Jarvis is the only entry now; adding an agent later = one entry.

### 5.2 Host TTS-delivery integration (new module)

- A module the delivery path calls when a reply has voice-intent. Reads the reply text, calls the sidecar, hands the returned audio to the adapter as a voice payload.
- **Voice-intent tracking:** a per-session (or per-messaging-group) flag, set/refreshed from inbound metadata (§5.4 / §5.5), consumed when the matching reply is delivered. Stale-safe: the flag reflects "this conversation is currently in voice mode"; it resets when a non-voice inbound arrives (iOS) or on `/voice off` (Telegram).
- Delivery interface already passes files to adapters (`src/delivery.ts` `deliver(...)`, `readOutboxFiles`); extend with a voice operation rather than overloading photo/file.
- Failure handling: if the sidecar errors or times out, the text reply still stands (already delivered); log and skip the voice note. Never block text on TTS.

### 5.3 Telegram adapter (extend `src/channels/telegram.ts`)

- Add a `send_voice` operation → `POST https://api.telegram.org/bot<token>/sendVoice` with the opus buffer (mirrors the existing `send_photo` handler at `telegram.ts:254`).
- Add a **`/voice on|off`** command handler → sets the per-chat voice-intent flag (persisted; there is no Telegram voice mode today). Default off.

### 5.4 iOS protocol (`shared/ios-app-protocol/v2.ts`)

- **Inbound:** add `respond_by_voice: boolean` to `InlineContext` (lines 23–33). It already flows client → host → agent header (`index.ts:239` serialises `ios_context`), so the host sees it with no new plumbing.
- **Outbound:** add `'audio'` to the attachment `kind` enum (currently `z.enum(['image','file'])` at v2.ts:80; Message payload lines 72–90), and teach the host's `mimeFromFilename` (`src/channels/ios-app/v2/index.ts:50`) to map `.ogg/.opus/.m4a/.wav` → `audio/*` so outbound attachments are tagged `kind:'audio'` (the `mime.startsWith('image/') ? 'image' : 'file'` logic at index.ts:533–546).

### 5.5 iOS app (`ios/JarvisApp/`)

- **Send the flag:** when the iOS client builds its `InlineContext` (`WebSocketClientV2.swift`, in its `makeInlineContext` site — confirm during implementation), set `respond_by_voice = settings.autoSpeak && lastSendWasVoice` (existing trigger: guard at `AppCoordinator.swift:236`; `lastSendWasVoice` declared `:46`, set from `viaVoice` at `:158`), and `true` in fullscreen Glass/Orb mode (`OrbVoiceView.swift:194`). Reuses the existing `autoSpeak` toggle (`AppSettings.swift:16`, `SettingsView.swift:73`) — no new setting.
- **Play server audio:** when a reply arrives with an `audio` attachment, play that (the F5 Jarvis voice) instead of on-device Apple TTS. Add an `.audio(...)` case to the message content enum (`Models/Message.swift:63`) and wire playback.
- **Settings cleanup (voice is backend now):** remove the voice **picker** (`voiceId`) and the **rate/pitch** controls from `SettingsView.swift`, and the corresponding `AppSettings` fields (`voiceId`, `voiceRate`, `voicePitch`). They configured the on-device Apple TTS and are obsolete now that the voice is rendered on the backend. **Keep** the `autoSpeak` toggle ("Озвучивать ответы на голос") — it is reused as the voice trigger. `SpeechSynthesizer.speak(...)` loses its per-setting params and uses fixed internal defaults (only reachable via the fallback below). Update the call sites (`AppCoordinator.swift:238`, `OrbVoiceView.swift:199`).
- **Fallback:** if no audio attachment arrives (sidecar slow/failed) and voice mode is on, on-device Apple TTS may speak the text with a **fixed default** Russian voice (no longer user-configurable). This is a generic system voice, **not** the Jarvis clone — keep it only as a rare-degradation safety net; acceptable to disable it entirely (text is already delivered) if an off-character voice is worse than silence. Decide during implementation.
- **"Показать текст":** in Glass/Orb fullscreen, add a toggle to reveal the reply text (in the normal chat view the text bubble is already present).

## 6. Latency & UX

- F5 on CPU: ~35 s for ~14 s of audio on Apple-Silicon MPS; on a 2–4 vCPU x86 VDS without GPU expect **~1–3 min per voice note**. Acceptable because delivery is async and text precedes voice.
- The user reads the text immediately; the voice note lands shortly after. No spinner-blocking.

## 7. One-time setup / operational

- **VDS upgrade:** F5 needs ~4 GB RAM resident; current VDS is 3.8 GB total / ~1 GB free and swapping. Bump RAM/CPU (user agreed — cheap) before enabling.
- **Asset deployment:** F5 checkpoint (~1.35 GB), RUAccent models, vocab, and the Jarvis reference wav to the VDS. Document download/placement; pin versions (no `minimumReleaseAge` policy covers this Python tree — pin deliberately).
- **Service:** install/enable the sidecar; host points at its local endpoint.

## 8. Error handling

| Failure | Behaviour |
|---|---|
| Sidecar down / timeout | Text reply already delivered; log, skip voice note. iOS may fall back to Apple TTS. |
| Reply too long | Sidecar chunks + concatenates; host may cap very long replies (voice of a wall of text is poor UX). |
| Markdown/code in reply | Sidecar strips formatting before synthesis. |
| Voice-intent ambiguous | Default to **no** voice (text only) — never spam voice notes. |

## 9. Testing

- **Sidecar:** unit test the text→opus pipeline on fixed inputs; assert non-empty opus, sane duration vs input length (guards the MOSS-style "rambling" failure mode).
- **Telegram:** integration test `send_voice` against a throwaway chat; `/voice on|off` toggles state.
- **iOS:** protocol round-trip (respond_by_voice in, audio attachment out); manual device test of playback + fallback + "показать текст". (iOS rebuild on-device by Sergei is the usual gate — see project memory.)
- **End-to-end:** voice input → text-first reply → voice note in the cloned voice, both channels.

## 10. Open risks

- F5 CPU latency may feel long for chatty use; mitigation is the text-first model and (later) evaluating a lighter engine. MOSS-TTS-Nano does CPU cloning fast but its Russian is currently too raw (rejected this round; revisit if it improves).
- Voice-intent flag staleness across long sessions / mixed input — keep the reset rules simple and conservative (default off).
- Reference licensing: movie-dub clone for a private, non-redistributed personal assistant. Personal use only.

## 11. References (integration anchors)

*(line numbers verified against on-disk code 2026-06-15)*

- Trigger/toggle (keep `autoSpeak`): `AppSettings.swift:16` (`autoSpeak`), `SettingsView.swift:73` (toggle), `AppCoordinator.swift:236` (guard) / `:238` (speak call) / `:46`,`:158` (`lastSendWasVoice`), `OrbVoiceView.swift:194` (handler) / `:199-202` (speak call).
- Voice settings to **remove** (`voiceId`/`voiceRate`/`voicePitch`): `AppSettings.swift:17-19`, `SettingsView.swift:74-91` (voice picker + rate/pitch sliders), `SpeechSynthesizer.swift:43` (speak signature).
- Add `.audio` case: `Models/Message.swift:63-69` (Content enum: text/image/file/action/status).
- Protocol: `shared/ios-app-protocol/v2.ts:23-33` (InlineContext), `:72-90` (Message), `:80` (attachment `kind` enum = `['image','file']`).
- iOS host adapter: `src/channels/ios-app/v2/index.ts:50` (`mimeFromFilename`, no audio types), `:239` (inbound `routeToAgent`, serialises `ios_context`), `:533-546` (outbound attachment kind).
- Telegram: `src/channels/telegram.ts:254` (`send_photo` → add `send_voice` + `/voice`; no voice/audio handler today).
- Delivery: `src/delivery.ts:52-66` (`deliver`, `files?: OutboundFile[]` at `:59`), `:357` (`readOutboxFiles`).
- Agent outbox: `container/agent-runner/src/mcp-tools/core.ts:175-177` (`send_file` copies into outbox).
- Voice recipe + reference assets: `/Users/serg/jarvis-voice/` (dev Mac); memory `project-jarvis-voice`.
