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
