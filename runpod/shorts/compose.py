#!/usr/bin/env python3
"""Short zusammensetzen: Clips + Narration + Untertitel + Musikbett -> 1080x1920.

Aufruf (im Pod): compose.py <projekt-dir> [--no-whisper] [--keep-ltx-audio]

Ablauf
  1. Clips (clips/clip_NN.mp4) in Szenenreihenfolge zusammensetzen
  2. LTX-Tonspur stark absenken (-26 dB): sie ist Atmo, kann aber Sprachreste
     des Prompts enthalten (englischer Ton war genau das Problem)
  3. Narration (audio/szene_NN.wav) mit 0.4 s Luft je Szene aneinanderreihen
  4. Untertitel aus Whisper-Wort-Timings (3-4 Woerter je Zeile)
  5. Musikbett synthetisieren + Ducking unter die Narration
  6. Loudness auf -14 LUFS, Ausgabe 1080x1920
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import wave
from pathlib import Path

import numpy as np

LUFT = 0.4
FPS = 24


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise RuntimeError(f"cmd failed ({r.returncode}): {' '.join(cmd[:6])}...\n{r.stderr[-800:]}")
    return r


def dur(path: str) -> float:
    out = run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
               "-of", "default=noprint_wrappers=1:nokey=1", path]).stdout.strip()
    return float(out)


def synth_bed(seconds: float, sr: int = 48000, seed: int = 11) -> str:
    """Dunkles Ambient-Bett (Unterwasser): tiefe Sinuslagen + gefiltertes Rauschen."""
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * sr)) / sr
    bed = np.zeros_like(t)
    for f, a in ((55, 0.30), (82.5, 0.22), (110, 0.16), (164.8, 0.10)):
        bed += a * np.sin(2 * np.pi * f * t + rng.uniform(0, 6.28))
    noise = rng.normal(0, 1, len(t))
    # Tiefpass: vektorisiert per IIR (scipy), sonst ueber Cumsum-Naeherung.
    # (Eine Python-Schleife ueber 2,4 Mio Samples dauert Minuten - gemessen.)
    alpha = 0.0025
    try:
        from scipy.signal import lfilter  # type: ignore
        filt = lfilter([alpha], [1.0, -(1.0 - alpha)], noise)
    except Exception:
        filt = (np.cumsum(noise) * alpha)
        filt -= np.linspace(0, filt[-1], len(filt))     # Drift entfernen
    bed += 2.2 * filt
    # langsame Amplitude (Atmen)
    bed *= 0.75 + 0.25 * np.sin(2 * np.pi * 0.045 * t)
    bed /= max(1e-9, np.abs(bed).max())
    return bed, sr


def write_wav(path: str, data: np.ndarray, sr: int, channels: int = 2) -> None:
    x = np.clip(data, -1, 1)
    ints = (x * 32000).astype(np.int16)
    if channels == 2:
        ints = np.repeat(ints.reshape(-1, 1), 2, axis=1).ravel()
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(ints.tobytes())


def build_timeline(proj: Path, timing: dict) -> tuple[str, list[tuple[int, float, str]]]:
    """Reiht Narration mit Luft aneinander; liefert (wav, [(szene_id, start, text)])."""
    sr = 48000
    parts, marks = [], []
    cursor = 0.0
    for sz in timing["szenen"]:
        wav = proj / "audio" / f"szene_{sz['id']:02d}.wav"
        with wave.open(str(wav), "rb") as w:
            n = w.getnframes()
            d = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float32) / 32768.0
            if w.getnchannels() == 2:
                d = d.reshape(-1, 2).mean(axis=1)
        marks.append((sz["id"], cursor, sz["text"]))
        parts.append(d)
        pause = np.zeros(int(LUFT * sr), dtype=np.float32)
        parts.append(pause)
        cursor += len(d) / sr + LUFT
    joined = np.concatenate(parts) if parts else np.zeros(1, dtype=np.float32)
    out = str(proj / "narration_timeline.wav")
    write_wav(out, joined.astype(np.float32), sr, channels=1)
    return out, marks


def whisper_srt(narration: str, out_srt: str) -> bool:
    try:
        from faster_whisper import WhisperModel  # type: ignore
    except Exception as e:                                    # pragma: no cover
        print("  faster_whisper nicht verfuegbar:", e)
        return False
    model = WhisperModel("small", device="cpu", compute_type="int8", cpu_threads=16)
    segs, _ = model.transcribe(narration, language="de", word_timestamps=True,
                               vad_filter=False)
    words = []
    for s in segs:
        for w in (s.words or []):
            words.append((w.start, w.end, w.word.strip()))

    def ts(x: float) -> str:
        h, rem = divmod(x, 3600)
        m, s = divmod(rem, 60)
        return f"{int(h):02d}:{int(m):02d}:{s:06.3f}".replace(".", ",")

    lines, buf, start = [], [], None
    for st, en, w in words:
        if start is None:
            start = st
        buf.append(w)
        if len(buf) >= 4 or re.search(r"[.!?:]$", w):
            lines.append((start, en, " ".join(buf)))
            buf, start = [], None
    if buf:
        lines.append((start, words[-1][1], " ".join(buf)))
    with open(out_srt, "w") as fh:
        for i, (a, b, txt) in enumerate(lines, 1):
            fh.write(f"{i}\n{ts(a)} --> {ts(b)}\n{txt}\n\n")
    print(f"  Untertitel: {len(lines)} Zeilen -> {out_srt}")
    return True


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("projekt")
    ap.add_argument("--keep-ltx-audio", action="store_true")
    ap.add_argument("--no-whisper", action="store_true")
    a = ap.parse_args()

    proj = Path(a.projekt)
    timing = json.load(open(proj / "timing.json"))
    clips = sorted((proj / "clips").glob("clip_*.mp4"))
    if not clips:
        raise SystemExit("keine Clips gefunden")
    print(f"Clips: {len(clips)}")

    # 1) Video zusammensetzen (re-encode, damit Schnitte exakt sitzen)
    listing = proj / "concat.txt"
    listing.write_text("".join(f"file '{c}'\n" for c in clips))
    vid = proj / "video_raw.mp4"
    run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0",
         "-i", str(listing), "-c:v", "libx264", "-preset", "medium", "-crf", "19",
         "-pix_fmt", "yuv420p", "-r", str(FPS), str(vid)])
    total = dur(vid)
    print(f"  Video: {total:.2f}s")

    # 2) Narration-Zeitleiste
    narration, marks = build_timeline(proj, timing)
    print(f"  Narration-Zeitleiste: {dur(narration):.2f}s")

    # 3) Untertitel
    srt = proj / "untertitel.srt"
    ok = False if a.no_whisper else whisper_srt(narration, str(srt))
    if not ok:
        # Fallback: Szenentexte gleichmaessig verteilen
        with open(srt, "w") as fh:
            for i, (sid, st, txt) in enumerate(marks, 1):
                e = st + timing["szenen"][i - 1]["dauer_s"]
                fh.write(f"{i}\n00:00:{st:06.3f} --> 00:00:{e:06.3f}\n{txt}\n\n"
                         .replace(".", ","))
        print("  Untertitel: Fallback aus Szenentexten")

    # 4) Musikbett + Mischung
    bed, sr = synth_bed(total)
    bed_path = proj / "musikbett.wav"
    write_wav(str(bed_path), bed * 0.22, sr)

    vf = "scale=1080:1920:flags=lanczos"
    if a.keep_ltx_audio:
        mix = ("[0:a]volume=-26dB[atmo];"
               "[1:a]volume=1.0[nar];"
               "[2:a]volume=0.5[mus];"
               "[atmo][nar]sidechaincompress=threshold=0.05:ratio=8:attack=20:release=400[nar_d];"
               "[nar_d][mus]amix=inputs=2:duration=first:dropout_transition=0[mix]")
        fcmap = ["-filter_complex", mix, "-map", "0:v", "-map", "[mix]"]
    else:
        mix = ("[1:a]volume=1.0[nar];"
               "[2:a]volume=0.5[mus];"
               "[nar][mus]sidechaincompress=threshold=0.05:ratio=8:attack=20:release=400[d];"
               "[nar][d]amix=inputs=2:duration=first:dropout_transition=0[mix]")
        fcmap = ["-filter_complex", mix, "-map", "0:v", "-map", "[mix]"]

    final = proj / "short_final.mp4"
    run(["ffmpeg", "-y", "-v", "error",
         "-i", str(vid), "-i", str(narration), "-i", str(bed_path),
         *fcmap,
         "-vf", vf + f",subtitles={srt}",
         "-c:v", "libx264", "-preset", "medium", "-crf", "19", "-pix_fmt", "yuv420p",
         "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
         "-af", "loudnorm=I=-14:TP=-1.5:LRA=11",
         str(final)])
    print(f"FERTIG: {final}  {dur(str(final)):.2f}s")


if __name__ == "__main__":
    main()
