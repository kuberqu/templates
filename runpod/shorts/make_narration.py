#!/usr/bin/env python3
"""Narration je Szene erzeugen (edge-tts) + echte Dauern ermitteln.

Aufruf: make_narration.py <script.json> [--out-dir /workspace/shorts/<projekt>]

Erzeugt pro Szene eine WAV (48 kHz mono) und schreibt die gemessenen Dauern
zurueck in eine separate Datei `timing.json` (das Skript-JSON bleibt unberuehrt).
Die Clip-Laenge im Video richtet sich nach diesen Werten:
Frames = ceil(dauer * fps) auf 8n+1 gerundet.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys

import edge_tts


async def speak(text: str, voice: str, rate: str, mp3: str) -> None:
    await edge_tts.Communicate(text, voice, rate=rate).save(mp3)


def dur(path: str) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", path],
        capture_output=True, text=True).stdout.strip()
    return float(out) if out else 0.0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("script")
    ap.add_argument("--out-dir", default="")
    a = ap.parse_args()

    cfg = json.load(open(a.script))
    base = a.out_dir or os.path.join("/workspace/shorts",
                                     os.path.basename(os.path.dirname(a.script)))
    adir = os.path.join(base, "audio")
    os.makedirs(adir, exist_ok=True)
    voice = cfg.get("stimme", "de-DE-FlorianMultilingualNeural")
    rate = cfg.get("voice_rate", "+8%")

    timing = []
    total = 0.0
    for sz in cfg["szenen"]:
        mp3 = os.path.join(adir, f"szene_{sz['id']:02d}.mp3")
        wav = os.path.join(adir, f"szene_{sz['id']:02d}.wav")
        asyncio.run(speak(sz["text"], voice, rate, mp3))
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", mp3,
                        "-ar", "48000", "-ac", "1", wav], check=True)
        d = dur(wav)
        total += d
        timing.append({"id": sz["id"], "typ": sz["typ"], "text": sz["text"],
                       "dauer_s": round(d, 3), "wav": wav,
                       "geplant_s": sz.get("dauer_s")})
        print(f"  Szene {sz['id']:>2} ({sz['typ']:<5}) {d:5.2f}s  "
              f"geplant {sz.get('dauer_s')}s  | {sz['text'][:58]}")

    out = os.path.join(base, "timing.json")
    json.dump({"stimme": voice, "rate": rate, "gesamt_s": round(total, 3),
               "szenen": timing}, open(out, "w"), ensure_ascii=False, indent=1)
    print(f"\nGesamtnarration: {total:.2f} s  ({len(timing)} Szenen)")
    print("geschrieben:", out)


if __name__ == "__main__":
    main()
