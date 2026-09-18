#!/usr/bin/env python3
"""Was hoert man im Host-Clip? Vergleich mit dem Skript-Text."""
from faster_whisper import WhisperModel

m = WhisperModel("small", device="cpu", compute_type="int8", cpu_threads=16)
for f, label in (("clips/clip_01.mp4", "Host Szene 1 (LTX-Ton)"),
                 ("clips/clip_02.mp4", "B-Roll Szene 2 (LTX-Atmo)")):
    segs, _ = m.transcribe(f, language="de", vad_filter=False)
    txt = " | ".join(s.text.strip() for s in segs)
    if not txt:
        txt = "(keine Sprache erkannt)"
    print(label + ": " + txt[:220])
