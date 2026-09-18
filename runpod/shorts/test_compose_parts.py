#!/usr/bin/env python3
"""Testet die Schnitt-Bausteine isoliert (ohne Clips): Zeitleiste, Untertitel, Musikbett."""
from __future__ import annotations

import json
import os
import sys
import time
import wave
from pathlib import Path

sys.path.insert(0, "/workspace")
import numpy as np

PROJ = Path("/workspace/shorts/hummer_lobster")

# --- Bausteine aus compose.py importieren ---
import importlib.util
spec = importlib.util.spec_from_file_location("compose", "/workspace/compose.py")
compose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compose)

timing = json.load(open(PROJ / "timing.json"))

print("1) Narration-Zeitleiste bauen")
t0 = time.time()
narration, marks = compose.build_timeline(PROJ, timing)
print(f"   -> {narration}  ({compose.dur(narration):.2f}s, {time.time()-t0:.1f}s)")
print("   Szenen-Startpunkte:")
for sid, st, txt in marks:
    print(f"     Szene {sid:>2} ab {st:5.2f}s: {txt[:52]}")

print("\n2) Untertitel via Whisper")
t0 = time.time()
srt = str(PROJ / "untertitel.srt")
ok = compose.whisper_srt(narration, srt)
print(f"   ok={ok} ({time.time()-t0:.1f}s)")
if ok:
    lines = open(srt).read().strip().split("\n\n")
    print(f"   {len(lines)} Zeilen, erste 4:")
    for seg in lines[:4]:
        print("     " + seg.replace("\n", " | "))

print("\n3) Musikbett synthetisieren")
t0 = time.time()
total = compose.dur(narration)
bed, sr = compose.synth_bed(total)
compose.write_wav(str(PROJ / "musikbett_test.wav"), bed * 0.22, sr)
print(f"   {len(bed)} Samples ({len(bed)/sr:.2f}s) in {time.time()-t0:.1f}s -> musikbett_test.wav")
lv = np.abs(bed).max()
print(f"   Pegel max {20*np.log10(max(lv,1e-9)):.1f} dBFS")
