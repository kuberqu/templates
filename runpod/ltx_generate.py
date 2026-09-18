#!/usr/bin/env python3
"""LTX-2.5 lokal: Video+Audio in einem Pass. Baut den API-Prompt, führt ihn aus,
pollt den Fortschritt und lädt das Ergebnis herunter.

Aufruf: ltx_generate.py "Prompt" [--w 768] [--h 1344] [--frames 121] [--steps 8] [--seed 42]
"""
from __future__ import annotations

import argparse
import json
import shutil
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8188"
LTX_MODEL = "ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors"
TEXT_ENC = "gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors"
VIDEO_VAE = "ltx-2.5-video-vae-bf16.safetensors"
AUDIO_VAE = "ltx-2.5-audio-vae-bf16.safetensors"


def build(width: int, height: int, frames: int, steps: int, seed: int,
          prompt: str, negative: str) -> dict:
    return {
        "1": {"class_type": "UNETLoader",
              "inputs": {"unet_name": LTX_MODEL, "weight_dtype": "default"}},
        "2": {"class_type": "LTXAVTextEncoderLoader",
              "inputs": {"text_encoder": TEXT_ENC, "ckpt_name": LTX_MODEL,
                         "device": "default"}},
        "3": {"class_type": "CLIPTextEncode",
              "inputs": {"text": prompt, "clip": ["2", 0]}},
        "4": {"class_type": "CLIPTextEncode",
              "inputs": {"text": negative, "clip": ["2", 0]}},
        "5": {"class_type": "LTXVConditioning",
              "inputs": {"positive": ["3", 0], "negative": ["4", 0],
                         "frame_rate": 25.0}},
        "6": {"class_type": "EmptyLTXVLatentVideo",
              "inputs": {"width": width, "height": height, "length": frames,
                         "batch_size": 1}},
        "7": {"class_type": "LTXVAudioVAELoader",
              "inputs": {"ckpt_name": AUDIO_VAE}},
        "8": {"class_type": "LTXVEmptyLatentAudio",
              "inputs": {"frames_number": frames, "frame_rate": 25.0,
                         "batch_size": 1, "audio_vae": ["7", 0]}},
        "9": {"class_type": "LTXVConcatAVLatent",
              "inputs": {"video_latent": ["6", 0], "audio_latent": ["8", 0]}},
        "10": {"class_type": "LTXVDualCFGGuider",
               "inputs": {"model": ["1", 0], "positive": ["5", 0],
                          "negative": ["5", 1], "video_cfg": 3.0, "audio_cfg": 7.0}},
        "11": {"class_type": "LTXVScheduler",
               "inputs": {"steps": steps, "max_shift": 2.05, "base_shift": 0.95,
                          "stretch": True, "terminal": 0.1, "latent": ["9", 0]}},
        "12": {"class_type": "RandomNoise", "inputs": {"noise_seed": seed}},
        "13": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
        "14": {"class_type": "SamplerCustomAdvanced",
               "inputs": {"noise": ["12", 0], "guider": ["10", 0],
                          "sampler": ["13", 0], "sigmas": ["11", 0],
                          "latent_image": ["9", 0]}},
        "15": {"class_type": "LTXVSeparateAVLatent",
               "inputs": {"av_latent": ["14", 0]}},
        "16": {"class_type": "VAELoader", "inputs": {"vae_name": VIDEO_VAE}},
        "17": {"class_type": "VAEDecode",
               "inputs": {"samples": ["15", 0], "vae": ["16", 0]}},
        "18": {"class_type": "LTXVAudioVAEDecode",
               "inputs": {"samples": ["15", 1], "audio_vae": ["7", 0]}},
        "19": {"class_type": "CreateVideo",
               "inputs": {"images": ["17", 0], "fps": 25.0, "audio": ["18", 0]}},
        "20": {"class_type": "SaveVideo",
               "inputs": {"video": ["19", 0], "filename_prefix": "ltx_test/t2v",
                          "format": "auto", "codec": "auto"}},
    }


def api_post(path: str, payload: dict) -> dict:
    req = urllib.request.Request(API + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt")
    ap.add_argument("--w", type=int, default=768)
    ap.add_argument("--h", type=int, default=1344)
    ap.add_argument("--frames", type=int, default=121)
    ap.add_argument("--steps", type=int, default=8)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--negative", default="blurry, low quality, distorted, watermark, text")
    ap.add_argument("--out", default="/workspace/ltx_out")
    args = ap.parse_args()

    wf = build(args.w, args.h, args.frames, args.steps, args.seed, args.prompt, args.negative)
    print(f"Prompt-Nodes: {len(wf)}  {args.w}x{args.h}, {args.frames} Frames "
          f"({args.frames/25:.2f}s @25fps), {args.steps} Steps, seed={args.seed}", flush=True)

    t0 = time.time()
    try:
        res = api_post("/prompt", {"prompt": wf})
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"VALIDIERUNGSFEHLER {e.code}:\n{body[:3000]}")
        raise SystemExit(2)
    pid = res["prompt_id"]
    print(f"queued: {pid}", flush=True)

    last = ""
    while True:
        time.sleep(10)
        with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
            hist = json.loads(r.read().decode())
        if pid in hist:
            entry = hist[pid]
            status = entry.get("status", {})
            print(f"STATUS: {status.get('status_str')} completed={status.get('completed')}")
            for m in status.get("messages", [])[-4:]:
                print("   ", json.dumps(m)[:200])
            if status.get("status_str") == "error":
                print(json.dumps(entry, indent=1)[:2500])
                raise SystemExit(3)
            for node_id, out in (entry.get("outputs") or {}).items():
                print(f"  Node {node_id} -> {json.dumps(out)[:400]}")
            break
        el = time.time() - t0
        try:
            with urllib.request.urlopen(f"{API}/queue", timeout=15) as r:
                q = json.loads(r.read().decode())
            running = len(q.get("queue_running", []))
            pending = len(q.get("queue_pending", []))
        except Exception:
            running = pending = -1
        msg = f"  [{el:6.1f}s] running={running} pending={pending}"
        if msg != last:
            print(msg, flush=True)
            last = msg

    dt = time.time() - t0
    print(f"FERTIG nach {dt:.1f}s ({dt/60:.1f} min)")


if __name__ == "__main__":
    main()
