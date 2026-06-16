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
