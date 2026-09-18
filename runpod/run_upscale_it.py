#!/usr/bin/env python3
"""InfiniteTalk-Clip hochskalieren: 480x832 -> 1080x1872 per 4x-UltraSharp (ESRGAN).

Warum: InfiniteTalk rendert nativ 480x832. Ein reiner Lanczos-Scale auf 1080 waere
weich; ESRGAN 4x + Downscale auf 1080 bringt echte Details (Augen, Hautporen, Haare).
Nebenbei passt 480x832 (0,577) viel besser ins 1080x1920-Ziel als der alte
Wav2Lip-Clip (832x1216 = 0,684), der beim Schnitt um 21 % gestaucht wurde.

Chunking: ESRGAN laeuft auf 4x 1920x3328 pro Frame - grosse Batches sprengen das VRAM.
Deshalb in Bloecken von --chunk Frames; SaveImage zaehlt bei gleichem Prefix ueber
mehrere Laeufe weiter (upit_00001_.png ... upit_00077_.png) - genau die ComfyUI-
Eigenschaft, die mit "/" im Prefix kaputtgeht.

Aufruf (auf dem POD):
  run_upscale_it.py --video talk_it_00001_.mp4 --frames 77 --prefix upit --chunk 16
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8188"
UPSCALER = "4x-UltraSharp.pth"


def build(video: str, skip: int, cap: int, prefix: str,
          w: int, h: int) -> dict:
    return {
        "1": {"class_type": "VHS_LoadVideo",
              "inputs": {"video": video, "force_rate": 25.0, "custom_width": 0,
                         "custom_height": 0, "frame_load_cap": cap,
                         "skip_first_frames": skip, "select_every_nth": 1}},
        "2": {"class_type": "UpscaleModelLoader", "inputs": {"model_name": UPSCALER}},
        "3": {"class_type": "ImageUpscaleWithModel",
              "inputs": {"upscale_model": ["2", 0], "image": ["1", 0]}},
        "4": {"class_type": "ImageScale",
              "inputs": {"image": ["3", 0], "upscale_method": "lanczos",
                         "width": w, "height": h, "crop": "disabled"}},
        "5": {"class_type": "SaveImage",
              "inputs": {"images": ["4", 0], "filename_prefix": prefix}},
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", default="talk_it_00001_.mp4")
    ap.add_argument("--frames", type=int, default=77)
    ap.add_argument("--prefix", default="upit")
    ap.add_argument("--chunk", type=int, default=16)
    ap.add_argument("--breite", type=int, default=1080)
    ap.add_argument("--hoehe", type=int, default=1872)
    a = ap.parse_args()

    done = 0
    while done < a.frames:
        cap = min(a.chunk, a.frames - done)
        t0 = time.time()
        try:
            req = urllib.request.Request(
                API + "/prompt",
                data=json.dumps({"prompt": build(a.video, done, cap, a.prefix,
                                                 a.breite, a.hoehe)}).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                pid = json.loads(r.read().decode())["prompt_id"]
        except urllib.error.HTTPError as e:
            print("VALIDIERUNGSFEHLER:", e.read().decode()[:800], flush=True)
            raise SystemExit(1)
        while True:
            time.sleep(4)
            with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
                hist = json.loads(r.read().decode())
            if pid in hist:
                st = hist[pid].get("status", {})
                n = sum(len(o.get("images", []))
                        for o in (hist[pid].get("outputs") or {}).values())
                print(f"  Frames {done+1}-{done+cap}: {st.get('status_str')} "
                      f"({time.time()-t0:.0f}s, {n} Bilder)", flush=True)
                if st.get("status_str") == "error":
                    print(json.dumps(hist[pid], indent=1)[:1500], flush=True)
                    raise SystemExit(1)
                break
        done += cap
    print(f"FERTIG: {done} Frames -> /workspace/ComfyUI/output/{a.prefix}_XXXXX_.png",
          flush=True)


if __name__ == "__main__":
    main()
