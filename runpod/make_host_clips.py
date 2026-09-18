#!/usr/bin/env python3
"""Host-Szenen lippensynchron rendern (Wav2Lip) - laeuft IM POD.

Warum nicht LTX: LTX spricht keinen vorgegebenen Text. Mit LTXVReferenceAudio
uebernimmt es nur den Stimmcharakter und ERFINDET den Inhalt (gemessen: Skript
sagte "Dieser Hummer knurrt", der Clip sagte "Aber jetzt brauche ich allen Gord").
Der Ton laeuft dem Bild ausserdem ~0,5 s voraus (LTX-Anlaufzeit 0.70 s vs.
edge-tts 0.20 s). Fuer sprechende Szenen daher Wav2Lip auf ein neutrales
Portrait - dort kommen Lippen und Stimme aus derselben Quelle.

Aufruf: make_host_clips.py <projekt-dir> [--portrait host_neutral.png]
Ergebnis: clips/clip_NN.mp4 fuer jede Szene mit typ == "host"
"""
from __future__ import annotations

import argparse
import json
import shutil
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "http://127.0.0.1:8188"
INPUT = Path("/workspace/ComfyUI/input")


def run(cmd: list[str]) -> None:
    import subprocess
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{cmd[:3]} -> {r.stderr[-400:]}")


def dur(path: str) -> float:
    import subprocess
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=noprint_wrappers=1:nokey=1", path],
                         capture_output=True, text=True).stdout.strip()
    return float(out)


def build(image: str, audio: str, prefix: str, fps: int = 24) -> dict:
    """mode MUSS 'repetitive' sein: die Quelle ist EIN Standbild. Bei
    'sequential' zeigt face_idx bei frame_size=1 zwar ebenfalls auf das Bild,
    aber der Modus ist fuer Videosequenzen gedacht - 'repetitive' ist die
    dokumentierte Einstellung fuer Standbilder."""
    return {
        "1": {"class_type": "LoadImage", "inputs": {"image": image}},
        "2": {"class_type": "LoadAudio", "inputs": {"audio": audio}},
        "3": {"class_type": "Wav2Lip", "inputs": {
            "images": ["1", 0], "audio": ["2", 0],
            "mode": "repetitive", "face_detect_batch": 8}},
        "4": {"class_type": "VHS_VideoCombine", "inputs": {
            "images": ["3", 0], "audio": ["3", 1], "frame_rate": float(fps),
            "loop_count": 0, "filename_prefix": prefix,
            "format": "video/h264-mp4", "pingpong": False, "save_output": True}},
    }


def post(payload: dict) -> dict:
    req = urllib.request.Request(API + "/prompt", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("projekt")
    ap.add_argument("--portrait", default="host_neutral.png",
                    help="neutrales Portrait mit geschlossenem Mund (Pod-Pfad input/)")
    ap.add_argument("--fps", type=int, default=24)
    ap.add_argument("--nur", default="", help="z.B. 1 oder 1,10")
    a = ap.parse_args()

    proj = Path(a.projekt)
    timing = json.load(open(proj / "timing.json"))
    nur = {int(x) for x in a.nur.split(",") if x.strip()} if a.nur else None

    hosts = [s for s in timing["szenen"] if s.get("typ") == "host"]
    if nur:
        hosts = [s for s in hosts if s["id"] in nur]
    if not hosts:
        print("keine Host-Szenen")
        return
    print(f"Host-Szenen: {[s['id'] for s in hosts]}")

    # Portrait bereitstellen (Wav2Lip liest wie LoadImage nur aus input/)
    src = Path("/workspace") / a.portrait
    if not src.exists():
        src = Path(a.portrait)
    dst_img = INPUT / f"hostportrait_{proj.name}.png"
    shutil.copyfile(src, dst_img)

    for sz in hosts:
        sid = sz["id"]
        wav = proj / "audio" / f"szene_{sid:02d}.wav"
        if not wav.exists():
            print(f"  Szene {sid}: Narration fehlt ({wav}) - uebersprungen")
            continue
        audio_name = f"hosttalk_{proj.name}_{sid:02d}.wav"
        shutil.copyfile(wav, INPUT / audio_name)

        prefix = f"hosttalk_{proj.name}_{sid:02d}"
        t0 = time.time()
        try:
            pid = post({"prompt": build(dst_img.name, audio_name, prefix, a.fps)})["prompt_id"]
        except urllib.error.HTTPError as e:
            print(f"  Szene {sid}: VALIDIERUNGSFEHLER {e.read().decode()[:400]}")
            continue
        out = None
        while True:
            time.sleep(5)
            with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
                hist = json.loads(r.read().decode())
            if pid in hist:
                st = hist[pid].get("status", {})
                for _n, o in (hist[pid].get("outputs") or {}).items():
                    for g in o.get("gifs", []) + o.get("videos", []):
                        out = g.get("filename")
                print(f"  Szene {sid}: {st.get('status_str')} ({time.time()-t0:.0f}s) -> {out}")
                break
        if not out:
            continue
        # Ergebnis liegt in output/ -> in den Clip-Ordner als clip_NN.mp4
        produced = Path("/workspace/ComfyUI/output") / out
        target = proj / "clips" / f"clip_{sid:02d}.mp4"
        target.parent.mkdir(parents=True, exist_ok=True)
        run(["ffmpeg", "-y", "-v", "error", "-i", str(produced), "-t", f"{dur(str(wav)):.3f}",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", str(a.fps),
             "-c:a", "aac", "-b:a", "192k", "-ar", "48000", str(target)])
        print(f"  -> {target}  {dur(str(target)):.2f}s")
    print("HOST_CLIPS_FERTIG")


if __name__ == "__main__":
    main()
