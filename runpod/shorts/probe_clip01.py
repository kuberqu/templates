#!/usr/bin/env python3
"""Welcher Text steckt im aktuellen Host-Clip (Wav2Lip)?"""
from faster_whisper import WhisperModel

m = WhisperModel("small", device="cpu", compute_type="int8", cpu_threads=16)
for f in ("clips/clip_01.mp4",):
    segs, _ = m.transcribe(f, language="de", vad_filter=False)
    txt = " ".join(s.text.strip() for s in segs)
    if not txt:
        txt = "(keine Sprache erkannt)"
    print(f + ": " + txt[:200])
