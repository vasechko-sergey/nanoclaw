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
