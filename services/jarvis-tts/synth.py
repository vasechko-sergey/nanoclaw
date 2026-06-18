import logging, os, subprocess, tempfile, threading
import soundfile as sf
from config import CKPT_FILE, VOCAB_FILE, MODEL_NAME, VOICES, CPU_THREADS, NFE_STEP
from textprep import strip_markdown, chunk_text

log = logging.getLogger("jarvis-tts")
_model = None
_accent = None
_ref_cache: dict[str, tuple[str, str]] = {}
# FastAPI runs sync handlers in a threadpool; the F5 model is not thread-safe.
# All synthesis calls serialise through this lock.
_synth_lock = threading.Lock()

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

# ffmpeg encode args per output format. opus/ogg = Telegram voice notes;
# m4a/AAC = iOS (AVAudioPlayer can't decode OGG/Opus, but plays AAC natively).
_FMT = {
    "opus": (["-c:a", "libopus", "-b:a", "32k"], "out.ogg"),
    "m4a":  (["-c:a", "aac", "-b:a", "64k"], "out.m4a"),
}


def synth_to_opus(text: str, voice: str, max_chars: int, fmt: str = "opus") -> bytes:
    """Render text -> encoded audio bytes (opus/ogg or m4a/aac). Raises on failure."""
    if fmt not in _FMT:
        raise ValueError(f"unknown format {fmt!r}")
    enc_args, out_name = _FMT[fmt]
    with _synth_lock:
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
                wav, sr, _ = _model.infer(ref_file=ref_wav, ref_text=ref_text, gen_text=gen, nfe_step=NFE_STEP)
                sr_out = sr
                segments.append(wav)
            import numpy as np
            full = np.concatenate(segments) if len(segments) > 1 else segments[0]
            full = np.asarray(full, dtype=np.float32)
            # Soften the ending: F5 can cut at a non-zero sample (audible click /
            # abrupt stop). Apply a short fade-out, then append trailing silence
            # so the voice eases out instead of clipping off.
            fade = min(int(sr_out * 0.04), full.shape[0])
            if fade > 0:
                full[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)
            full = np.concatenate([full, np.zeros(int(sr_out * 0.12), dtype=np.float32)])
            sf.write(wav_path, full, sr_out)
            out_path = os.path.join(td, out_name)
            subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path,
                 "-af", "loudnorm=I=-16:TP=-2", *enc_args, out_path],
                check=True,
            )
            with open(out_path, "rb") as f:
                return f.read()
