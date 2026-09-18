#!/usr/bin/env python3
"""Szenenclips erzeugen: jedes Szenenbild -> LTX-2.5 I2V, Laenge aus timing.json.

Aufruf: make_clips.py <script.json> [--timing timing.json] [--out-dir ...] [--only 1,3]

Die Cliplaenge folgt der GEMESSENEN Narration (timing.json), plus kleiner Luft
(--luft, Standard 0.4 s), auf die 8n+1-Regel gerundet. Ohne passende Referenz
spricht die Figur nicht - fuer B-Roll wird bewusst nur Atmo erzeugt
('no speech, ambience only' steht in den Clip-Prompts des Skripts).

Wichtig: Der von LTX erzeugte Ton ist NICHT die Narration (gemessen: keine
Korrelation mit dem Referenzaudio) - er dient nur als Atmo und wird im Schnitt
durch Florians Stimme ersetzt.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8188"
LTX = "ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors"
TEXT_ENC = "gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors"
VIDEO_VAE = "ltx-2.5-video-vae-bf16.safetensors"
AUDIO_VAE = "ltx-2.5-audio-vae-bf16.safetensors"
UPSCALER = "ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
SIG1 = "1.0, 0.99375, 0.9875, 0.98125, 0.975, 0.909375, 0.725, 0.421875, 0.0"
SIG2 = "0.85, 0.7250, 0.4219, 0.0"
NEG = "pc game, console game, video game, cartoon, childish, ugly"
FPS = 24


def frames_for(seconds: float) -> int:
    raw = int(round(seconds * FPS)) + 1
    return int(round((raw - 1) / 8.0)) * 8 + 1


def build(image: str, prompt: str, frames: int, w: int, h: int, seed: int,
          prefix: str, strength: float) -> dict:
    bw, bh = w // 2, h // 2
    return {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": LTX, "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader",
              "inputs": {"clip_name": TEXT_ENC, "type": "ltxv", "device": "default"}},
        "16": {"class_type": "VAELoader", "inputs": {"vae_name": VIDEO_VAE}},
        "17": {"class_type": "VAELoader", "inputs": {"vae_name": AUDIO_VAE}},
        "20": {"class_type": "LatentUpscaleModelLoader", "inputs": {"model_name": UPSCALER}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["2", 0]}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": NEG, "clip": ["2", 0]}},
        "5": {"class_type": "LTXVConditioning",
              "inputs": {"positive": ["3", 0], "negative": ["4", 0], "frame_rate": float(FPS)}},
        "30": {"class_type": "LoadImage", "inputs": {"image": image}},
        "31": {"class_type": "LTXVPreprocess",
               "inputs": {"image": ["30", 0], "img_compression": 18}},
        "6": {"class_type": "EmptyLTXVLatentVideo",
              "inputs": {"width": bw, "height": bh, "length": frames, "batch_size": 1}},
        "32": {"class_type": "LTXVImgToVideoInplace",
               "inputs": {"vae": ["16", 0], "image": ["31", 0], "latent": ["6", 0],
                          "strength": strength, "bypass": False}},
        "7": {"class_type": "LTXVEmptyLatentAudio",
              "inputs": {"frames_number": frames, "frame_rate": float(FPS),
                         "batch_size": 1, "audio_vae": ["17", 0]}},
        "8": {"class_type": "LTXVConcatAVLatent",
              "inputs": {"video_latent": ["32", 0], "audio_latent": ["7", 0]}},
        "9": {"class_type": "LTXVDualCFGGuider",
              "inputs": {"model": ["1", 0], "positive": ["5", 0], "negative": ["5", 1],
                         "video_cfg": 1.0, "audio_cfg": 1.0}},
        "10": {"class_type": "RandomNoise", "inputs": {"noise_seed": seed}},
        "11": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler_ancestral"}},
        "12": {"class_type": "ManualSigmas", "inputs": {"sigmas": SIG1}},
        "13": {"class_type": "SamplerCustomAdvanced",
               "inputs": {"noise": ["10", 0], "guider": ["9", 0], "sampler": ["11", 0],
                          "sigmas": ["12", 0], "latent_image": ["8", 0]}},
        "14": {"class_type": "LTXVSeparateAVLatent", "inputs": {"av_latent": ["13", 0]}},
        "15": {"class_type": "LTXVLatentUpsampler",
               "inputs": {"samples": ["14", 0], "upscale_model": ["20", 0], "vae": ["16", 0]}},
        "21": {"class_type": "LTXVConcatAVLatent",
               "inputs": {"video_latent": ["15", 0], "audio_latent": ["14", 1]}},
        "22": {"class_type": "LTXVDualCFGGuider",
               "inputs": {"model": ["1", 0], "positive": ["5", 0], "negative": ["5", 1],
                          "video_cfg": 1.0, "audio_cfg": 1.0}},
        "23": {"class_type": "RandomNoise", "inputs": {"noise_seed": seed + 1}},
        "24": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler_ancestral"}},
        "25": {"class_type": "ManualSigmas", "inputs": {"sigmas": SIG2}},
        "26": {"class_type": "SamplerCustomAdvanced",
               "inputs": {"noise": ["23", 0], "guider": ["22", 0], "sampler": ["24", 0],
                          "sigmas": ["25", 0], "latent_image": ["21", 0]}},
        "18": {"class_type": "LTXVSeparateAVLatent", "inputs": {"av_latent": ["26", 0]}},
        "19": {"class_type": "VAEDecodeTiled",
               "inputs": {"samples": ["18", 0], "vae": ["16", 0], "tile_size": 512,
                          "overlap": 64, "temporal_size": 64, "temporal_overlap": 16}},
        "27": {"class_type": "LTXVAudioVAEDecode",
               "inputs": {"samples": ["18", 1], "audio_vae": ["17", 0]}},
        "28": {"class_type": "CreateVideo",
               "inputs": {"images": ["19", 0], "fps": float(FPS), "audio": ["27", 0],
                          "bit_depth": "auto", "color_space": "sRGB", "codec": "none"}},
        "29": {"class_type": "SaveVideo",
               "inputs": {"video": ["28", 0], "filename_prefix": prefix,
                          "format": "auto", "codec": "auto"}},
    }


def post(payload: dict) -> str:
    req = urllib.request.Request(API + "/prompt", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())["prompt_id"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("script")
    ap.add_argument("--timing", default="")
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--luft", type=float, default=0.4)
    ap.add_argument("--w", type=int, default=720)
    ap.add_argument("--h", type=int, default=1280)
    ap.add_argument("--strength", type=float, default=0.7)
    ap.add_argument("--only", default="")
    ap.add_argument("--seed", type=int, default=900)
    a = ap.parse_args()

    cfg = json.load(open(a.script))
    base = a.out_dir or os.path.join("/workspace/shorts",
                                     os.path.basename(os.path.dirname(a.script)))
    timing = json.load(open(a.timing or os.path.join(base, "timing.json")))
    tdur = {t["id"]: t["dauer_s"] for t in timing["szenen"]}
    cdir = os.path.join(base, "clips")
    os.makedirs(cdir, exist_ok=True)
    want = [int(x) for x in a.only.split(",") if x.strip()] if a.only else []

    total_frames = 0
    for sz in cfg["szenen"]:
        if want and sz["id"] not in want:
            continue
        secs = tdur.get(sz["id"], sz["dauer_s"]) + a.luft
        fr = frames_for(secs)
        total_frames += fr
        img = f"szene_{sz['id']:02d}.png"
        prefix = f"short_hummer/clip_{sz['id']:02d}"
        t0 = time.time()
        try:
            pid = post({"prompt": build(img, sz["clip_prompt"], fr, a.w, a.h,
                                        a.seed + sz["id"], prefix, a.strength)})
        except urllib.error.HTTPError as e:
            print(f"  Szene {sz['id']:>2}: FEHLER {e.read().decode()[:300]}", flush=True)
            continue
        while True:
            time.sleep(10)
            with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
                hist = json.loads(r.read().decode())
            if pid in hist:
                st = hist[pid].get("status", {}).get("status_str")
                fn = None
                for o in (hist[pid].get("outputs") or {}).values():
                    for im in o.get("images", []):
                        fn = im
                if fn:
                    src = f"/workspace/ComfyUI/output/{fn.get('subfolder')}/{fn['filename']}"
                    if os.path.exists(src):
                        shutil.copyfile(src, os.path.join(cdir, f"clip_{sz['id']:02d}.mp4"))
                print(f"  Szene {sz['id']:>2} ({sz['typ']:<5}) {fr:>3} Frames "
                      f"({fr/FPS:.2f}s) {st} {time.time()-t0:6.1f}s", flush=True)
                break
    print(f"Clips in: {cdir} | Gesamtframes {total_frames} = {total_frames/FPS:.2f}s")


if __name__ == "__main__":
    main()
