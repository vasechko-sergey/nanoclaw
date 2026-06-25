import os
from pathlib import Path

ASSETS = Path(os.environ.get("JARVIS_TTS_ASSETS", "/opt/jarvis-tts/assets"))
CKPT_FILE = str(ASSETS / "accent_tune.safetensors")
VOCAB_FILE = str(ASSETS / "vocab.txt")
MODEL_NAME = "F5TTS_v1_Base"

# Voice registry: voice name (== agent folder) -> (reference wav, reference
# transcript). Each clone is zero-shot from its ref clip, so the clip IS the
# voice — keep it clean (single speaker, ~6-12s, no music/SFX bed).
VOICES = {
    "jarvis": {  # J.A.R.V.I.S. (Iron Man RU dub, Баранов)
        "ref_wav": str(ASSETS / "ref_workshop.wav"),
        "ref_text_file": str(ASSETS / "ref_workshop_text.txt"),
    },
    "greg": {  # Грегори Хаус (Доктор Хаус, LostFilm / Кухарешин)
        "ref_wav": str(ASSETS / "ref_greg.wav"),
        "ref_text_file": str(ASSETS / "ref_greg_text.txt"),
    },
    "gordon": {  # Гордон Рамзи (Kitchen Nightmares RU)
        "ref_wav": str(ASSETS / "ref_gordon.wav"),
        "ref_text_file": str(ASSETS / "ref_gordon_text.txt"),
    },
    "payne": {  # Майор Пейн (RU dub, казарма)
        "ref_wav": str(ASSETS / "ref_payne.wav"),
        "ref_text_file": str(ASSETS / "ref_payne_text.txt"),
    },
    "scrooge": {  # Скрудж МакДак (Утиные истории, Борзунов)
        "ref_wav": str(ASSETS / "ref_scrooge.wav"),
        "ref_text_file": str(ASSETS / "ref_scrooge_text.txt"),
    },
}
DEFAULT_VOICE = "jarvis"

HOST = os.environ.get("JARVIS_TTS_HOST", "127.0.0.1")
PORT = int(os.environ.get("JARVIS_TTS_PORT", "8099"))
CPU_THREADS = int(os.environ.get("JARVIS_TTS_THREADS", "4"))
MAX_CHARS = int(os.environ.get("JARVIS_TTS_MAX_CHARS", "1200"))
# F5 flow-matching steps. 16 ≈ indistinguishable from 32 by ear (Sergei A/B'd)
# but ~1.8x faster on CPU (6.3min -> 3.5min for a ~6s line). Override via env.
NFE_STEP = int(os.environ.get("JARVIS_TTS_NFE", "16"))
