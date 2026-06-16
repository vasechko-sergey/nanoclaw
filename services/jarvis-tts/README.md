# jarvis-tts sidecar

Self-hosted F5-TTS-RU clone of the Jarvis voice. CPU-only. `POST /tts {text,voice?} -> audio/ogg (opus)`.

## Assets (NOT in git) — place under `$JARVIS_TTS_ASSETS`

The sidecar loads these four files by exact name from `$JARVIS_TTS_ASSETS`
(defaults to `/opt/jarvis-tts/assets`). Wrong name → 500 on first `/tts` call.

| Filename in `$JARVIS_TTS_ASSETS` | Source |
|----------------------------------|--------|
| `accent_tune.safetensors` | HF `Misha24-10/F5-TTS_RUSSIAN`, path `F5TTS_v1_Base_accent_tune/model_last_inference.safetensors` — **rename** the downloaded file to `accent_tune.safetensors` |
| `vocab.txt` | HF same repo, path `F5TTS_v1_Base/vocab.txt` — no rename needed |
| `ref_workshop.wav` | Curated Jarvis reference audio (from `voice-samples/`) |
| `ref_workshop_text.txt` | Transcript of `ref_workshop.wav` (plain UTF-8, one line) |

## Run
```bash
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
export JARVIS_TTS_ASSETS=/opt/jarvis-tts/assets
uvicorn app:app --host 127.0.0.1 --port 8099
```

## VDS service (systemd) — see Phase 1 Task 1.6.
## Requires: ffmpeg, ffprobe on PATH; ~4 GB RAM resident.
