# Jarvis Voice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver Jarvis replies as voice notes spoken in a self-hosted clone of the Russian Iron Man J.A.R.V.I.S. dub — rendered on the VDS (CPU, no GPU), in Telegram and the iOS app, reusing the existing `autoSpeak` toggle.

**Architecture:** A standalone Python **TTS sidecar** (F5-TTS-RU + RUAccent + a cached reference clip, model warm in RAM) exposes `POST /tts → opus`. The Node host stays the orchestrator: it tracks a per-conversation "voice intent" flag, and after delivering the reply text it calls the sidecar and delivers the audio as a voice note (Telegram `sendVoice`; iOS `audio` attachment). The agent is unchanged (emits text only — **host-driven**). Text is delivered first; voice follows when rendering finishes (~1–3 min on CPU, async).

**Tech Stack:** Python 3.10 + FastAPI/uvicorn + `f5-tts` + `ruaccent` + ffmpeg (sidecar); Node + TypeScript + better-sqlite3 (host); Telegram Bot API; Zod (iOS protocol, `shared/`); Swift/SwiftUI + AVFoundation (iOS app).

**Spec:** `docs/superpowers/specs/2026-06-15-jarvis-voice-design.md`. Voice recipe + reference assets: `/Users/serg/jarvis-voice/` and memory `project-jarvis-voice`.

**Phasing (each phase ships testable software):**
- **Phase 1 — TTS sidecar.** Standalone service; verified with `curl` → playable opus. No host changes.
- **Phase 2 — Host + Telegram.** Voice-intent plumbing + `sendVoice` + `/voice` command → end-to-end voice note in Telegram.
- **Phase 3 — iOS.** Protocol `respond_by_voice` + `audio` attachment + app playback/fallback/settings-cleanup → voice note in the iOS app.

**Conventions:** Host tests = `pnpm test` (vitest). Sidecar tests = `pytest`. Commit after every task. `src/channels/telegram.ts` is skill-installed in this deploy — edits here are local (mirror to the `channels` branch later if upstreaming).

---

## Phase 1 — TTS Sidecar

**File Structure (new dir `services/jarvis-tts/`):**
- Create `services/jarvis-tts/app.py` — FastAPI app: `/health`, `POST /tts`.
- Create `services/jarvis-tts/synth.py` — synthesis pipeline: markdown-strip → RUAccent stress → F5 infer → opus. Holds warm model.
- Create `services/jarvis-tts/textprep.py` — markdown/normalisation helpers (pure functions, unit-tested).
- Create `services/jarvis-tts/requirements.txt` — pinned deps.
- Create `services/jarvis-tts/config.py` — paths (ckpt, vocab, ref wav, ref text) from env vars.
- Create `services/jarvis-tts/tests/test_textprep.py` — unit tests for text prep.
- Create `services/jarvis-tts/tests/test_synth_smoke.py` — heavy smoke test (skipped unless `JARVIS_TTS_SMOKE=1`).
- Create `services/jarvis-tts/README.md` — deploy + asset placement.
- Reference assets (NOT committed): `ref_workshop.wav`, `ref_workshop_text.txt`, `accent_tune.safetensors`, `vocab.txt` — placed under `$JARVIS_TTS_ASSETS` on the VDS (copied from `/Users/serg/jarvis-voice/`).

### Task 1.1: Scaffold sidecar package + config

**Files:**
- Create: `services/jarvis-tts/config.py`
- Create: `services/jarvis-tts/requirements.txt`

- [ ] **Step 1: Write `requirements.txt`**

```
f5-tts==1.1.7
ruaccent==1.5.8.3
fastapi==0.115.6
uvicorn==0.34.0
soundfile==0.12.1
certifi
```
> Pin to versions confirmed working in `/Users/serg/jarvis-voice/`. No `minimumReleaseAge` policy covers this Python tree — versions chosen deliberately. `ffmpeg` must be on PATH (system package).

- [ ] **Step 2: Write `config.py`**

```python
import os
from pathlib import Path

ASSETS = Path(os.environ.get("JARVIS_TTS_ASSETS", "/opt/jarvis-tts/assets"))
CKPT_FILE = str(ASSETS / "accent_tune.safetensors")
VOCAB_FILE = str(ASSETS / "vocab.txt")
MODEL_NAME = "F5TTS_v1_Base"

# Voice registry: voice name -> (reference wav, reference transcript).
VOICES = {
    "jarvis": {
        "ref_wav": str(ASSETS / "ref_workshop.wav"),
        "ref_text_file": str(ASSETS / "ref_workshop_text.txt"),
    },
}
DEFAULT_VOICE = "jarvis"

HOST = os.environ.get("JARVIS_TTS_HOST", "127.0.0.1")
PORT = int(os.environ.get("JARVIS_TTS_PORT", "8099"))
CPU_THREADS = int(os.environ.get("JARVIS_TTS_THREADS", "4"))
MAX_CHARS = int(os.environ.get("JARVIS_TTS_MAX_CHARS", "1200"))
```

- [ ] **Step 3: Commit**

```bash
git add services/jarvis-tts/config.py services/jarvis-tts/requirements.txt
git commit -m "feat(tts): scaffold jarvis-tts sidecar config + deps"
```

### Task 1.2: Text preparation (markdown strip + chunking) — TDD

**Files:**
- Create: `services/jarvis-tts/textprep.py`
- Test: `services/jarvis-tts/tests/test_textprep.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_textprep.py
from textprep import strip_markdown, chunk_text

def test_strip_markdown_removes_formatting():
    assert strip_markdown("**Готово**, см. `файл.py`") == "Готово, см. файл.py"

def test_strip_markdown_drops_code_fences():
    assert strip_markdown("Вот:\n```py\nx=1\n```\nготово") == "Вот: готово"

def test_strip_markdown_links_keep_text():
    assert strip_markdown("[отчёт](http://x/y)") == "отчёт"

def test_chunk_text_splits_on_sentence_under_limit():
    text = "Первое предложение. Второе предложение. Третье."
    chunks = chunk_text(text, max_chars=25)
    assert all(len(c) <= 25 for c in chunks)
    assert "".join(chunks).replace(" ", "") == text.replace(" ", "")

def test_chunk_text_single_when_short():
    assert chunk_text("Коротко.", max_chars=100) == ["Коротко."]
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd services/jarvis-tts && python -m pytest tests/test_textprep.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'textprep'`.

- [ ] **Step 3: Implement `textprep.py`**

```python
import re

_CODE_FENCE = re.compile(r"```.*?```", re.DOTALL)
_INLINE_CODE = re.compile(r"`([^`]*)`")
_LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_BOLD_IT = re.compile(r"(\*\*|\*|__|_)")
_HEADING = re.compile(r"^#{1,6}\s*", re.MULTILINE)
_WS = re.compile(r"\s+")

def strip_markdown(text: str) -> str:
    text = _CODE_FENCE.sub(" ", text)
    text = _LINK.sub(r"\1", text)
    text = _INLINE_CODE.sub(r"\1", text)
    text = _HEADING.sub("", text)
    text = _BOLD_IT.sub("", text)
    return _WS.sub(" ", text).strip()

def chunk_text(text: str, max_chars: int) -> list[str]:
    text = text.strip()
    if len(text) <= max_chars:
        return [text]
    parts = re.split(r"(?<=[.!?])\s+", text)
    chunks, cur = [], ""
    for p in parts:
        if cur and len(cur) + 1 + len(p) > max_chars:
            chunks.append(cur)
            cur = p
        else:
            cur = f"{cur} {p}".strip()
    if cur:
        chunks.append(cur)
    return chunks
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_textprep.py -v`
Expected: PASS (5 passed).

- [ ] **Step 5: Commit**

```bash
git add services/jarvis-tts/textprep.py services/jarvis-tts/tests/test_textprep.py
git commit -m "feat(tts): markdown-strip + sentence chunking with tests"
```

### Task 1.3: Synthesis pipeline (warm F5 + RUAccent → opus)

**Files:**
- Create: `services/jarvis-tts/synth.py`

> F5 + RUAccent are heavy and not unit-testable cheaply; this task is exercised by the smoke test (Task 1.5) and the `/tts` endpoint test (Task 1.4 via a monkeypatched synth). Keep the model warm in a module-level singleton.

- [ ] **Step 1: Implement `synth.py`**

```python
import logging, os, subprocess, tempfile
import soundfile as sf
from config import CKPT_FILE, VOCAB_FILE, MODEL_NAME, VOICES, CPU_THREADS
from textprep import strip_markdown, chunk_text

log = logging.getLogger("jarvis-tts")
_model = None
_accent = None
_ref_cache: dict[str, tuple[str, str]] = {}

def _lazy_init():
    global _model, _accent
    if _model is None:
        import torch
        torch.set_num_threads(CPU_THREADS)
        from f5_tts.api import F5TTS
        log.info("loading F5 model (warm)…")
        _model = F5TTS(model=MODEL_NAME, ckpt_file=CKPT_FILE, vocab_file=VOCAB_FILE, device="cpu")
    if _accent is None:
        from ruaccent import RUAccent
        _accent = RUAccent()
        _accent.load(omograph_model_size="turbo3.1", use_dictionary=True)

def _ref(voice: str) -> tuple[str, str]:
    if voice not in _ref_cache:
        v = VOICES[voice]
        ref_text = open(v["ref_text_file"], encoding="utf-8").read().strip()
        _ref_cache[voice] = (v["ref_wav"], _accent.process_all(ref_text))
    return _ref_cache[voice]

def synth_to_opus(text: str, voice: str, max_chars: int) -> bytes:
    """Render text -> opus (ogg) bytes. Raises on failure."""
    _lazy_init()
    if voice not in VOICES:
        raise ValueError(f"unknown voice {voice!r}")
    clean = strip_markdown(text)
    if not clean:
        raise ValueError("empty text after markdown strip")
    ref_wav, ref_text = _ref(voice)
    with tempfile.TemporaryDirectory() as td:
        wav_path = os.path.join(td, "out.wav")
        segments = []
        sr_out = 24000
        for chunk in chunk_text(clean, max_chars):
            gen = _accent.process_all(chunk)
            wav, sr, _ = _model.infer(ref_file=ref_wav, ref_text=ref_text, gen_text=gen)
            sr_out = sr
            segments.append(wav)
        import numpy as np
        full = np.concatenate(segments) if len(segments) > 1 else segments[0]
        sf.write(wav_path, full, sr_out)
        opus_path = os.path.join(td, "out.ogg")
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path,
             "-af", "loudnorm=I=-16:TP=-2", "-c:a", "libopus", "-b:a", "32k", opus_path],
            check=True,
        )
        with open(opus_path, "rb") as f:
            return f.read()
```

- [ ] **Step 2: Smoke-import (no model load)**

Run: `cd services/jarvis-tts && python -c "import synth; print('import OK')"`
Expected: `import OK` (model loads lazily, so import is cheap).

- [ ] **Step 3: Commit**

```bash
git add services/jarvis-tts/synth.py
git commit -m "feat(tts): warm F5 + RUAccent synthesis pipeline to opus"
```

### Task 1.4: FastAPI app + endpoint test (synth monkeypatched)

**Files:**
- Create: `services/jarvis-tts/app.py`
- Test: `services/jarvis-tts/tests/test_app.py`

- [ ] **Step 1: Implement `app.py`**

```python
import logging
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel
import config, synth

logging.basicConfig(level=logging.INFO)
app = FastAPI()

class TtsRequest(BaseModel):
    text: str
    voice: str = config.DEFAULT_VOICE

@app.get("/health")
def health():
    return {"status": "ok", "voices": list(config.VOICES.keys())}

@app.post("/tts")
def tts(req: TtsRequest):
    try:
        audio = synth.synth_to_opus(req.text, req.voice, config.MAX_CHARS)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logging.exception("synthesis failed")
        raise HTTPException(status_code=500, detail=str(e))
    return Response(content=audio, media_type="audio/ogg")
```

- [ ] **Step 2: Write the endpoint test**

```python
# tests/test_app.py
from fastapi.testclient import TestClient
import synth, app as appmod

def test_health():
    c = TestClient(appmod.app)
    r = c.get("/health")
    assert r.status_code == 200 and r.json()["status"] == "ok"

def test_tts_returns_ogg(monkeypatch):
    monkeypatch.setattr(synth, "synth_to_opus", lambda text, voice, mx: b"OggS-fake")
    c = TestClient(appmod.app)
    r = c.post("/tts", json={"text": "Привет"})
    assert r.status_code == 200
    assert r.headers["content-type"] == "audio/ogg"
    assert r.content == b"OggS-fake"

def test_tts_empty_text_400(monkeypatch):
    def boom(*a, **k):
        raise ValueError("empty text after markdown strip")
    monkeypatch.setattr(synth, "synth_to_opus", boom)
    c = TestClient(appmod.app)
    r = c.post("/tts", json={"text": "``` ```"})
    assert r.status_code == 400
```

- [ ] **Step 3: Run tests, verify pass**

Run: `cd services/jarvis-tts && python -m pytest tests/test_app.py -v`
Expected: PASS (3 passed). (Install test dep first: `pip install httpx pytest`.)

- [ ] **Step 4: Commit**

```bash
git add services/jarvis-tts/app.py services/jarvis-tts/tests/test_app.py
git commit -m "feat(tts): FastAPI /tts + /health with endpoint tests"
```

### Task 1.5: Smoke test + README (real F5 render, gated)

**Files:**
- Create: `services/jarvis-tts/tests/test_synth_smoke.py`
- Create: `services/jarvis-tts/README.md`

- [ ] **Step 1: Write the gated smoke test**

```python
# tests/test_synth_smoke.py
import os, io, wave, subprocess, tempfile, pytest
import synth

pytestmark = pytest.mark.skipif(os.environ.get("JARVIS_TTS_SMOKE") != "1",
                                reason="set JARVIS_TTS_SMOKE=1 to run heavy F5 render")

def _ogg_duration_sec(data: bytes) -> float:
    with tempfile.NamedTemporaryFile(suffix=".ogg") as f:
        f.write(data); f.flush()
        out = subprocess.check_output(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", f.name])
    return float(out.strip())

def test_render_jarvis_sane_duration():
    text = "Доброе утро, Сергей. Всё готово, можешь проверить."
    audio = synth.synth_to_opus(text, "jarvis", 1200)
    assert audio[:4] == b"OggS"
    dur = _ogg_duration_sec(audio)
    # ~3.5s of speech; guard against the MOSS-style "rambling" failure mode
    assert 2.0 < dur < 9.0, f"unexpected duration {dur}s"
```

- [ ] **Step 2: Run the smoke test against real assets (manual, on a box with the assets)**

Run:
```bash
cd services/jarvis-tts
export JARVIS_TTS_ASSETS=/Users/serg/jarvis-voice/models/f5   # dev Mac: holds accent_tune.safetensors, vocab.txt
# place ref_workshop.wav + ref_workshop_text.txt alongside (copy from /Users/serg/jarvis-voice/)
JARVIS_TTS_SMOKE=1 python -m pytest tests/test_synth_smoke.py -v
```
Expected: PASS; first run loads model (slow). If duration assertion fails, the synth is mis-rendering — stop and inspect before proceeding.

- [ ] **Step 3: Write `README.md`** (deploy + assets)

````markdown
# jarvis-tts sidecar

Self-hosted F5-TTS-RU clone of the Jarvis voice. CPU-only. `POST /tts {text,voice?} -> audio/ogg (opus)`.

## Assets (NOT in git) — place under `$JARVIS_TTS_ASSETS`
- `accent_tune.safetensors` — HF `Misha24-10/F5-TTS_RUSSIAN`, file `F5TTS_v1_Base_accent_tune/model_last_inference.safetensors`
- `vocab.txt` — HF same repo, `F5TTS_v1_Base/vocab.txt`
- `ref_workshop.wav` + `ref_workshop_text.txt` — curated Jarvis reference (from /Users/serg/jarvis-voice/)

## Run
```bash
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
export JARVIS_TTS_ASSETS=/opt/jarvis-tts/assets
uvicorn app:app --host 127.0.0.1 --port 8099
```

## VDS service (systemd) — see Phase 1 Task 1.6.
## Requires: ffmpeg, ffprobe on PATH; ~4 GB RAM resident.
````

- [ ] **Step 4: Commit**

```bash
git add services/jarvis-tts/tests/test_synth_smoke.py services/jarvis-tts/README.md
git commit -m "test(tts): gated F5 render smoke test + deploy README"
```

### Task 1.6: VDS deployment (systemd unit + asset placement)

**Files:**
- Create: `services/jarvis-tts/jarvis-tts.service` (systemd template)

> Manual/ops task. The VDS must first be upgraded to ~4 GB+ free RAM (currently 3.8 GB total, ~1 GB free). Do not enable until RAM is bumped.

- [ ] **Step 1: Write the systemd unit**

```ini
# jarvis-tts.service — install to /etc/systemd/system/ (Linux VDS)
[Unit]
Description=Jarvis TTS sidecar
After=network.target

[Service]
Type=simple
User=nanoclaw
Environment=JARVIS_TTS_ASSETS=/opt/jarvis-tts/assets
Environment=JARVIS_TTS_PORT=8099
WorkingDirectory=/opt/jarvis-tts/app
ExecStart=/opt/jarvis-tts/app/.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8099
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

- [ ] **Step 2: Deploy (manual)**

```bash
# on VDS (after RAM upgrade):
sudo mkdir -p /opt/jarvis-tts/app /opt/jarvis-tts/assets
# copy services/jarvis-tts/* -> /opt/jarvis-tts/app ; copy assets -> /opt/jarvis-tts/assets
cd /opt/jarvis-tts/app && python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
sudo cp jarvis-tts.service /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl enable --now jarvis-tts
curl -s localhost:8099/health    # {"status":"ok",...}
```

- [ ] **Step 3: End-to-end render check**

```bash
curl -s -X POST localhost:8099/tts -H 'content-type: application/json' \
  -d '{"text":"Доброе утро, Сергей. Всё готово."}' -o /tmp/v.ogg
ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/v.ogg   # ~3-5s
```
Expected: a playable opus, sane duration. **Note render latency** (seconds-to-minutes) for Phase 2 timeout tuning.

- [ ] **Step 4: Commit**

```bash
git add services/jarvis-tts/jarvis-tts.service
git commit -m "ops(tts): systemd unit for jarvis-tts sidecar"
```

**Phase 1 done:** sidecar renders the Jarvis voice on demand, verified by curl.

---

## Phase 2 — Host Voice Delivery + Telegram

**File Structure:**
- Create `src/db/migrations/NNN_voice_intent.ts` — add `sessions.voice_intent`, `messaging_groups.voice_mode`.
- Create `src/modules/voice/tts-client.ts` — calls the sidecar (`renderVoice(text, voice) -> Buffer | null`).
- Create `src/modules/voice/voice-intent.ts` — resolve/set per-session voice intent.
- Modify `src/router.ts` — set `sessions.voice_intent` from inbound (iOS `respond_by_voice` or Telegram `voice_mode`).
- Modify `src/delivery.ts` — after delivering text, if voice intent, render + deliver voice note.
- Modify `src/channels/adapter.ts` — extend delivery to carry a voice operation (or reuse files + an op flag).
- Modify `src/channels/telegram.ts` — `send_voice` op + `/voice on|off` command.
- Tests: `src/modules/voice/*.test.ts`, `src/channels/telegram.test.ts` (or existing test file).

> Inspect the actual migration runner format in `src/db/migrations/` and copy the latest migration's shape before writing Task 2.1 (numbering, export signature). The code below assumes a migration exports `up(db)`.

### Task 2.1: DB migration — voice flags

**Files:**
- Create: `src/db/migrations/<next-number>_voice_intent.ts`

- [ ] **Step 1: Confirm migration format**

Run: `ls src/db/migrations/ && sed -n '1,40p' "$(ls src/db/migrations/*.ts | tail -1)"`
Expected: see the export signature + numbering of the latest migration. Match it.

- [ ] **Step 2: Write the migration** (adapt to the observed format)

```typescript
// src/db/migrations/<next>_voice_intent.ts
import type { Database } from 'better-sqlite3';

export function up(db: Database): void {
  db.exec(`ALTER TABLE sessions ADD COLUMN voice_intent INTEGER NOT NULL DEFAULT 0;`);
  db.exec(`ALTER TABLE messaging_groups ADD COLUMN voice_mode INTEGER NOT NULL DEFAULT 0;`);
}
```

- [ ] **Step 3: Run migrations + verify columns**

Run:
```bash
pnpm run build
pnpm exec tsx scripts/q.ts data/v2.db "PRAGMA table_info(sessions)" | grep voice_intent
pnpm exec tsx scripts/q.ts data/v2.db "PRAGMA table_info(messaging_groups)" | grep voice_mode
```
Expected: both columns listed. (Migrations run on host startup; if there's a manual migrate command in `package.json`, use it instead.)

- [ ] **Step 4: Commit**

```bash
git add src/db/migrations/
git commit -m "feat(voice): migration — sessions.voice_intent, messaging_groups.voice_mode"
```

### Task 2.2: TTS client (host → sidecar) — TDD

**Files:**
- Create: `src/modules/voice/tts-client.ts`
- Test: `src/modules/voice/tts-client.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect, vi } from 'vitest';
import { renderVoice } from './tts-client';

describe('renderVoice', () => {
  it('returns a Buffer of opus bytes on 200', async () => {
    const fetchMock = vi.fn(async () => new Response(new Blob([new Uint8Array([79,103,103,83])]), { status: 200 }));
    const buf = await renderVoice('Привет', 'jarvis', { endpoint: 'http://x/tts', fetchImpl: fetchMock as any, timeoutMs: 1000 });
    expect(buf?.subarray(0, 4).toString('binary')).toBe('OggS');
  });

  it('returns null on non-200 (never throws into delivery)', async () => {
    const fetchMock = vi.fn(async () => new Response('boom', { status: 500 }));
    const buf = await renderVoice('x', 'jarvis', { endpoint: 'http://x/tts', fetchImpl: fetchMock as any, timeoutMs: 1000 });
    expect(buf).toBeNull();
  });

  it('returns null on timeout/throw', async () => {
    const fetchMock = vi.fn(async () => { throw new Error('network'); });
    const buf = await renderVoice('x', 'jarvis', { endpoint: 'http://x/tts', fetchImpl: fetchMock as any, timeoutMs: 1000 });
    expect(buf).toBeNull();
  });
});
```

- [ ] **Step 2: Run test, verify fail**

Run: `pnpm test src/modules/voice/tts-client.test.ts`
Expected: FAIL — cannot find `./tts-client`.

- [ ] **Step 3: Implement `tts-client.ts`**

```typescript
export interface RenderOpts {
  endpoint?: string;       // default from env JARVIS_TTS_URL
  timeoutMs?: number;      // default 240000 (CPU render is slow)
  fetchImpl?: typeof fetch;
}

export async function renderVoice(text: string, voice = 'jarvis', opts: RenderOpts = {}): Promise<Buffer | null> {
  const endpoint = opts.endpoint ?? process.env.JARVIS_TTS_URL ?? 'http://127.0.0.1:8099/tts';
  const timeoutMs = opts.timeoutMs ?? 240_000;
  const doFetch = opts.fetchImpl ?? fetch;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await doFetch(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text, voice }),
      signal: ctrl.signal,
    });
    if (!res.ok) { console.error(`[voice] tts ${res.status}`); return null; }
    return Buffer.from(await res.arrayBuffer());
  } catch (e) {
    console.error('[voice] tts call failed', e);
    return null;
  } finally {
    clearTimeout(timer);
  }
}
```

- [ ] **Step 4: Run test, verify pass**

Run: `pnpm test src/modules/voice/tts-client.test.ts`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add src/modules/voice/tts-client.ts src/modules/voice/tts-client.test.ts
git commit -m "feat(voice): host TTS client (fail-soft, returns null on error)"
```

### Task 2.3: Voice-intent resolution — TDD

**Files:**
- Create: `src/modules/voice/voice-intent.ts`
- Test: `src/modules/voice/voice-intent.test.ts`

> `resolveVoiceIntent` decides if an inbound implies a voiced reply. iOS: `ios_context.respond_by_voice === true`. Telegram (and others): the messaging group's persistent `voice_mode`.

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from 'vitest';
import { resolveVoiceIntent } from './voice-intent';

describe('resolveVoiceIntent', () => {
  it('true when iOS context requests voice', () => {
    expect(resolveVoiceIntent({ iosContext: { respond_by_voice: true }, groupVoiceMode: false })).toBe(true);
  });
  it('true when group voice_mode on (e.g. Telegram /voice)', () => {
    expect(resolveVoiceIntent({ iosContext: null, groupVoiceMode: true })).toBe(true);
  });
  it('false by default (never spam voice)', () => {
    expect(resolveVoiceIntent({ iosContext: { respond_by_voice: false }, groupVoiceMode: false })).toBe(false);
    expect(resolveVoiceIntent({ iosContext: null, groupVoiceMode: false })).toBe(false);
  });
});
```

- [ ] **Step 2: Run, verify fail.** `pnpm test src/modules/voice/voice-intent.test.ts` → FAIL.

- [ ] **Step 3: Implement `voice-intent.ts`**

```typescript
export interface IntentInput {
  iosContext: { respond_by_voice?: boolean } | null;
  groupVoiceMode: boolean;
}
export function resolveVoiceIntent(input: IntentInput): boolean {
  if (input.iosContext?.respond_by_voice === true) return true;
  return input.groupVoiceMode === true;
}
```

- [ ] **Step 4: Run, verify pass.** Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add src/modules/voice/voice-intent.ts src/modules/voice/voice-intent.test.ts
git commit -m "feat(voice): resolveVoiceIntent (iOS per-msg + group voice_mode)"
```

### Task 2.4: Router sets `sessions.voice_intent`

**Files:**
- Modify: `src/router.ts` (where it resolves the session + writes the inbound message)

> Read `src/router.ts` first to find where the session is resolved and the messaging-group row is in scope. The message content for iOS carries `ios_context` (see `src/channels/ios-app/v2/index.ts:239`).

- [ ] **Step 1: Wire it in** (place after session resolution, before/after writing the inbound)

```typescript
import { resolveVoiceIntent } from './modules/voice/voice-intent';
// ... inside the inbound routing, with `session`, `messagingGroup`, and parsed `content` in scope:
const iosContext = (content as any).ios_context ?? null;
const voiceIntent = resolveVoiceIntent({
  iosContext,
  groupVoiceMode: !!messagingGroup.voice_mode,
});
db.prepare('UPDATE sessions SET voice_intent = ? WHERE id = ?').run(voiceIntent ? 1 : 0, session.id);
```

- [ ] **Step 2: Build + typecheck**

Run: `pnpm run build`
Expected: no type errors.

- [ ] **Step 3: Commit**

```bash
git add src/router.ts
git commit -m "feat(voice): router records per-session voice intent from inbound"
```

### Task 2.5: Adapter interface — add a voice delivery operation

**Files:**
- Modify: `src/channels/adapter.ts` (the `OutboundFile` / deliver contract, ~lines 52-94)

> The delivery already passes `files?: OutboundFile[]`. Add an optional `operation` discriminator so an adapter knows a file is a voice note rather than a generic attachment. Read the current `deliver` signature first.

- [ ] **Step 1: Extend the outbound file/op type**

```typescript
// add to the OutboundFile interface (or a sibling field on deliver's content)
export interface OutboundFile {
  filename: string;
  data: Buffer;
  operation?: 'send_voice';   // NEW — when set, deliver as a platform voice note
}
```

- [ ] **Step 2: Build.** `pnpm run build` → no errors (field is optional/back-compat).

- [ ] **Step 3: Commit**

```bash
git add src/channels/adapter.ts
git commit -m "feat(voice): OutboundFile.operation='send_voice' for voice notes"
```

### Task 2.6: Delivery renders + sends the voice note

**Files:**
- Modify: `src/delivery.ts` (after the existing text delivery + `readOutboxFiles`, ~lines 352-368)

> After the text reply is delivered, if the session has `voice_intent`, render the reply text to opus and deliver it as a second payload tagged `send_voice`. Never block or fail text on TTS.

- [ ] **Step 1: Add voice rendering after text delivery**

```typescript
import { renderVoice } from './modules/voice/tts-client';
// after the existing deliver(...) for the text reply, with `session`, `msg`, `content` in scope:
if (session.voice_intent && content.text && content.text.trim()) {
  const opus = await renderVoice(content.text, 'jarvis');
  if (opus) {
    await deliveryAdapter.deliver(
      msg.channel_type, msg.platform_id, msg.thread_id, msg.kind,
      JSON.stringify({ operation: 'send_voice' }),
      [{ filename: 'reply.ogg', data: opus, operation: 'send_voice' }],
      session.agent_group_id,
    );
  } // null -> sidecar slow/down; text already delivered, skip silently
}
```

- [ ] **Step 2: Build + run host tests**

Run: `pnpm run build && pnpm test`
Expected: build clean; existing tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/delivery.ts
git commit -m "feat(voice): delivery renders reply to voice note when intent set"
```

### Task 2.7: Telegram `send_voice` handler — TDD

**Files:**
- Modify: `src/channels/telegram.ts` (mirror `send_photo` at ~line 254)
- Test: `src/channels/telegram.voice.test.ts`

- [ ] **Step 1: Write the failing test** (form-building, fetch mocked)

```typescript
import { describe, it, expect, vi } from 'vitest';
import { sendVoice } from './telegram';   // export a small helper for testability

describe('sendVoice', () => {
  it('POSTs multipart to sendVoice with chat_id + voice', async () => {
    const calls: any[] = [];
    const fetchMock = vi.fn(async (url: string, init: any) => { calls.push({ url, init }); return new Response('{"ok":true,"result":{"message_id":5}}', { status: 200 }); });
    const id = await sendVoice('TOKEN', '123', Buffer.from('OggS'), { fetchImpl: fetchMock as any });
    expect(calls[0].url).toContain('/botTOKEN/sendVoice');
    expect(id).toBe('5');
  });
});
```

- [ ] **Step 2: Run, verify fail.** `pnpm test src/channels/telegram.voice.test.ts` → FAIL (no `sendVoice` export).

- [ ] **Step 3: Implement** — add `sendVoice` helper + wire the `send_voice` operation in the adapter's deliver path (mirror the `send_photo` block at `telegram.ts:254`)

```typescript
export async function sendVoice(token: string, chatId: string, voice: Buffer,
  opts: { caption?: string; fetchImpl?: typeof fetch } = {}): Promise<string | undefined> {
  const doFetch = opts.fetchImpl ?? fetch;
  const form = new FormData();
  form.append('chat_id', chatId);
  form.append('voice', new Blob([voice], { type: 'audio/ogg' }), 'reply.ogg');
  if (opts.caption) form.append('caption', opts.caption);
  const res = await doFetch(`https://api.telegram.org/bot${token}/sendVoice`, { method: 'POST', body: form });
  const json: any = await res.json();
  return json?.result?.message_id != null ? String(json.result.message_id) : undefined;
}
```
Then in the adapter's `deliver` (where `send_photo` is handled): if `content.operation === 'send_voice'` or `message.files?.[0]?.operation === 'send_voice'`, call `sendVoice(token, chatId, message.files[0].data)`.

- [ ] **Step 4: Run, verify pass.** Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/channels/telegram.ts src/channels/telegram.voice.test.ts
git commit -m "feat(telegram): sendVoice handler for voice notes"
```

### Task 2.8: Telegram `/voice on|off` command — TDD

**Files:**
- Modify: `src/channels/telegram.ts` (inbound handling) or `src/command-gate.ts` if commands route there
- Test: `src/modules/voice/voice-command.test.ts`

> Read how inbound Telegram text is handled and whether commands route through `src/command-gate.ts`. `/voice on|off` flips `messaging_groups.voice_mode` for the chat's messaging group. Implement a pure parser first.

- [ ] **Step 1: Write the failing parser test**

```typescript
import { describe, it, expect } from 'vitest';
import { parseVoiceCommand } from './voice-command';

describe('parseVoiceCommand', () => {
  it('parses on/off', () => {
    expect(parseVoiceCommand('/voice on')).toEqual({ isCommand: true, enable: true });
    expect(parseVoiceCommand('/voice off')).toEqual({ isCommand: true, enable: false });
  });
  it('ignores non-commands', () => {
    expect(parseVoiceCommand('привет')).toEqual({ isCommand: false });
  });
});
```

- [ ] **Step 2: Run, verify fail.** → FAIL.

- [ ] **Step 3: Implement `src/modules/voice/voice-command.ts`**

```typescript
export type VoiceCommand = { isCommand: true; enable: boolean } | { isCommand: false };
export function parseVoiceCommand(text: string): VoiceCommand {
  const m = text.trim().match(/^\/voice\s+(on|off)\b/i);
  if (!m) return { isCommand: false };
  return { isCommand: true, enable: m[1].toLowerCase() === 'on' };
}
```

- [ ] **Step 4: Run, verify pass.** Expected: PASS.

- [ ] **Step 5: Wire into Telegram inbound** — before routing a Telegram text message, parse it; if a voice command, `UPDATE messaging_groups SET voice_mode=? WHERE id=?` for the chat's messaging group, reply with a confirmation, and do not route to the agent. Build: `pnpm run build`.

- [ ] **Step 6: Commit**

```bash
git add src/modules/voice/voice-command.ts src/modules/voice/voice-command.test.ts src/channels/telegram.ts
git commit -m "feat(telegram): /voice on|off toggles per-chat voice_mode"
```

### Task 2.9: End-to-end Telegram verification (manual)

- [ ] **Step 1: Point host at the sidecar + restart**

Ensure `.env` has `JARVIS_TTS_URL=http://127.0.0.1:8099/tts` (or the VDS-local address). Restart host (`launchctl kickstart -k gui/$(id -u)/com.nanoclaw` / `systemctl --user restart nanoclaw`).

- [ ] **Step 2: Toggle + talk to Jarvis on Telegram**

In the Jarvis Telegram DM: send `/voice on` → expect confirmation. Send a normal message → expect the **text reply first**, then a **voice note** in the cloned Jarvis voice ~seconds-to-minutes later. Send `/voice off` → replies are text-only again.

- [ ] **Step 3: Failure-mode check**

Stop the sidecar (`systemctl stop jarvis-tts`), send a message with `/voice on` → text reply still arrives, no voice note, host logs `[voice] tts call failed`. Restart sidecar.

**Phase 2 done:** end-to-end Jarvis voice notes in Telegram, fail-soft.

---

## Phase 3 — iOS Voice

**File Structure:**
- Modify `shared/ios-app-protocol/v2.ts` — `InlineContext.respond_by_voice` (in), attachment `kind` += `'audio'` (out).
- Modify `src/channels/ios-app/v2/index.ts` — audio MIME mapping (`:50`), outbound kind (`:533-546`).
- Modify `ios/.../Services/WebSocketClientV2.swift` — send `respond_by_voice`.
- Modify `ios/.../Models/Message.swift` — `.audio` content case (`:63-69`).
- Modify `ios/.../Models/AppSettings.swift` — remove `voiceId/voiceRate/voicePitch` (`:17-19`).
- Modify `ios/.../Views/SettingsView.swift` — remove voice picker + sliders (`:74-91`).
- Modify `ios/.../Services/SpeechSynthesizer.swift` — drop params, fixed defaults (`:43`).
- Modify `ios/.../Services/AppCoordinator.swift` — play audio attachment; fallback (`:236-238`).
- Modify `ios/.../Views/OrbVoiceView.swift` — play audio; "показать текст" (`:194-202`).

> iOS is built/tested on-device by Sergei (the usual gate — see memory `project-ios-app`). Steps below are concrete edits + a manual device verification.

### Task 3.1: Protocol — `respond_by_voice` + `audio` kind

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts` (InlineContext `:23-33`; Message attachments kind `:80`)
- Test: `shared/ios-app-protocol/v2.test.ts` (or the existing protocol test)

- [ ] **Step 1: Write the failing schema test**

```typescript
import { describe, it, expect } from 'vitest';
import { InlineContext, Message } from './v2';

describe('v2 voice fields', () => {
  it('InlineContext accepts respond_by_voice', () => {
    const r = InlineContext.safeParse({ timestamp: new Date().toISOString(), timezone: 'Asia/Makassar', respond_by_voice: true });
    expect(r.success).toBe(true);
  });
  it('attachment kind accepts audio', () => {
    const r = Message.safeParse({ v: 1, kind: 'data', type: 'message', id: 'x',
      payload: { thread_id: 't', text: '', attachments: [{ id: '00000000-0000-0000-0000-000000000000', kind: 'audio', name: 'reply.ogg', mime_type: 'audio/ogg', byte_size: 1 }] } });
    expect(r.success).toBe(true);
  });
});
```
> Verify the exact `Message` envelope shape/fields (`v`, `id`) against `v2.ts` before finalizing the test fixture.

- [ ] **Step 2: Run, verify fail.** `pnpm test shared/ios-app-protocol/v2.test.ts` → FAIL.

- [ ] **Step 3: Edit `v2.ts`**
- In `InlineContext` (`:23-33`) add: `respond_by_voice: z.boolean().optional(),`
- In the attachment `kind` enum (`:80`) change `z.enum(['image', 'file'])` → `z.enum(['image', 'file', 'audio'])`.

- [ ] **Step 4: Run, verify pass.** Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts
git commit -m "feat(ios-proto): respond_by_voice + audio attachment kind"
```

### Task 3.2: Host iOS adapter — audio MIME + outbound kind

**Files:**
- Modify: `src/channels/ios-app/v2/index.ts` (`mimeFromFilename` `:50`; outbound attachment kind `:533-546`)

- [ ] **Step 1: Add audio MIME types** to `mimeFromFilename` (`:50`)

```typescript
// add cases:
case '.ogg': case '.opus': return 'audio/ogg';
case '.m4a': return 'audio/mp4';
case '.wav': return 'audio/wav';
case '.mp3': return 'audio/mpeg';
```

- [ ] **Step 2: Tag outbound audio** — at the attachment mapping (`:533-546`), set kind from mime:

```typescript
kind: mime.startsWith('image/') ? 'image' : mime.startsWith('audio/') ? 'audio' : 'file',
```

- [ ] **Step 3: Build.** `pnpm run build` → no errors.

- [ ] **Step 4: Commit**

```bash
git add src/channels/ios-app/v2/index.ts
git commit -m "feat(ios-host): map audio MIME types; tag audio attachments"
```

### Task 3.3: iOS app — send `respond_by_voice`

**Files:**
- Modify: `ios/.../Services/WebSocketClientV2.swift` (the `makeInlineContext` site — confirm location)

- [ ] **Step 1: Add the field** when building InlineContext, sourced from the coordinator state (`autoSpeak && lastSendWasVoice`, or `true` in Orb). Pass a `respondByVoice: Bool` into the send path and include it in the encoded InlineContext JSON (`respond_by_voice`).

- [ ] **Step 2: Set it at call sites** — `AppCoordinator.swift:236` context (derive `settings.autoSpeak && lastSendWasVoice`) and `OrbVoiceView.swift` (always `true`).

- [ ] **Step 3: Build (Xcode/CI).** Confirm compiles.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift ios/JarvisApp/Sources/JarvisApp/Views/OrbVoiceView.swift
git commit -m "feat(ios): send respond_by_voice in InlineContext"
```

### Task 3.4: iOS app — play received audio + fallback

**Files:**
- Modify: `ios/.../Models/Message.swift` (`.audio` case `:63-69`)
- Modify: `ios/.../Services/AppCoordinator.swift` (`onSpeakableText`/message handling `:236-238`)

- [ ] **Step 1: Add `.audio` content case** to the `Content` enum in `Message.swift`:

```swift
case audio(FileInfo)   // server-rendered voice note (opus/m4a)
```
Map an incoming attachment with `kind == "audio"` (or mime `audio/*`) to `.audio(FileInfo(...))` where the message model is built from the envelope.

- [ ] **Step 2: Play audio on arrival** — when an assistant message carries an `.audio` attachment and voice mode is active, play it with `AVAudioPlayer`/`AVPlayer` instead of calling `SpeechSynthesizer.speak`. Add an `AudioPlaybackService` (small) or extend `SpeechSynthesizer` with `func play(data: Data)`.

- [ ] **Step 3: Fallback** — in `AppCoordinator.onSpeakableText` (`:236`), if voice mode is on and **no** audio attachment arrived within a short grace window, fall back to `SpeechSynthesizer.speak(text)` (fixed default voice — see Task 3.5). (Decision per spec §5.5: fallback may be disabled entirely; if so, do nothing on missing audio.)

- [ ] **Step 4: Build (Xcode).** Confirm compiles.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/Message.swift ios/JarvisApp/Sources/JarvisApp/Services/
git commit -m "feat(ios): play server-rendered voice note; fallback to on-device TTS"
```

### Task 3.5: iOS app — remove voice settings UI

**Files:**
- Modify: `ios/.../Models/AppSettings.swift` (remove `voiceId/voiceRate/voicePitch` `:17-19`)
- Modify: `ios/.../Views/SettingsView.swift` (remove voice picker + rate/pitch sliders `:74-91`)
- Modify: `ios/.../Services/SpeechSynthesizer.swift` (drop params `:43`)

- [ ] **Step 1: Remove the settings fields** `voiceId`, `voiceRate`, `voicePitch` from `AppSettings.swift`. **Keep** `autoSpeak`.

- [ ] **Step 2: Remove UI** — delete the voice `voiceRow()` picker + the two `voiceSlider()` controls (`SettingsView.swift:74-91`). Keep the "Озвучивать ответы на голос" toggle (`:73`).

- [ ] **Step 3: Simplify `SpeechSynthesizer.speak`** to `func speak(_ rawText: String)` using fixed internal defaults (former `rate: 0.47, pitch: 0.93`, a default Russian system voice). Update the two call sites (`AppCoordinator.swift:238`, `OrbVoiceView.swift:199`) to drop the removed args.

- [ ] **Step 4: Build (Xcode).** Confirm compiles; no references to removed fields remain (grep `voiceId|voiceRate|voicePitch`).

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift ios/JarvisApp/Sources/JarvisApp/Services/SpeechSynthesizer.swift
git commit -m "refactor(ios): remove voice picker/rate/pitch settings (voice is backend now)"
```

### Task 3.6: iOS app — "показать текст" in Orb/Glass

**Files:**
- Modify: `ios/.../Views/OrbVoiceView.swift`

- [ ] **Step 1: Add a toggle** in the fullscreen Orb view that reveals the latest reply's text (the normal chat view already shows text bubbles). Play the `.audio` attachment when present (Task 3.4), else fallback.

- [ ] **Step 2: Build (Xcode).** Confirm compiles.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbVoiceView.swift
git commit -m "feat(ios): 'показать текст' toggle in Orb voice view"
```

### Task 3.7: iOS end-to-end verification (manual, on-device — Sergei)

- [ ] **Step 1: Rebuild + install** the iOS app on the iPhone (Sergei).
- [ ] **Step 2:** Enable "Озвучивать ответы на голос" in Settings; confirm the voice picker / rate / pitch controls are gone.
- [ ] **Step 3:** Dictate a message to Jarvis (voice input). Expect: text reply appears immediately; the **cloned Jarvis voice note** plays/arrives shortly after (not the on-device Apple voice).
- [ ] **Step 4:** In Orb/Glass fullscreen, confirm replies play in the Jarvis voice and "показать текст" reveals the text.
- [ ] **Step 5:** Kill the sidecar; confirm graceful behavior (fallback Apple TTS or silence per the §5.5 decision), text still arrives.

**Phase 3 done:** Jarvis voice notes in the iOS app, voice settings cleaned up.

---

## Self-Review

**Spec coverage:** §4 architecture → Phases 1-3; §5.1 sidecar → Tasks 1.1-1.6; §5.2 host delivery + voice-intent → Tasks 2.1-2.6; §5.3 Telegram sendVoice + /voice → 2.7-2.8; §5.4 protocol → 3.1-3.2; §5.5 iOS app (send flag, play audio, fallback, settings cleanup, показать текст) → 3.3-3.6; §6 latency (text-first) → 2.6 + 2.9; §7 VDS upgrade/assets → 1.6 + README; §8 error handling → 2.2 (null), 2.6 (skip), 1.4 (400/500); §9 testing → per-task tests + 1.5 smoke + 2.9/3.7 manual. All covered.

**Open decision carried into execution:** §5.5 fallback (keep fixed-default Apple TTS vs disable) — flagged in Task 3.4 Step 3; decide on-device.

**Type consistency:** `renderVoice(text, voice, opts)` (2.2) used identically in 2.6. `resolveVoiceIntent({iosContext, groupVoiceMode})` (2.3) used in 2.4. `OutboundFile.operation='send_voice'` (2.5) produced in 2.6, consumed in 2.7. `respond_by_voice` (3.1) sent in 3.3, read in 2.4 via `ios_context`. Sidecar `POST /tts {text,voice}` (1.4) called by `renderVoice` (2.2). Consistent.

**Manual-gate notes:** F5 render (1.5), VDS deploy (1.6), Telegram E2E (2.9), iOS build + device test (3.7) are not classic-unit-testable — explicit verification steps given with expected output.
