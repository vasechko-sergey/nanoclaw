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
