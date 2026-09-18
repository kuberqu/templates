#!/usr/bin/env python3
"""Charakter-Portraits mit Qwen-Image 2512 (offizieller T2I-Graph als API-Prompt).

Parameter-Quelle: comfyui_workflow_templates_json/templates/image_qwen_image.json
(Subgraph "Text to Image (Qwen-Image)"): ModelSamplingAuraFlow shift=3.1,
KSampler euler/simple, Standard-Pfad 20 Steps / cfg 4 (der Lightning-8-Step-Pfad
des Templates braucht ein separates LoRA, das hier nicht liegt).

Aufruf: qwen_portraits.py [--varianten N] [--seed 100]
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8188"
UNET = "qwen_image_2512_fp8_e4m3fn.safetensors"
CLIP = "qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE = "qwen_image_vae.safetensors"

# Fester Charakter-Kanon: männlich, weiß, 35, dunkle Haare
BASE = ("photorealistic portrait photograph of a 35-year-old white man with dark brown hair, "
        "short and neatly styled, light stubble, defined jawline, brown eyes, neutral friendly "
        "expression, wearing a dark navy blazer over a white shirt")
NEG = "cartoon, anime, illustration, painting, 3d render, deformed, extra limbs, watermark, text"

VARIANTS = [
    ("frontal_bu", f"{BASE}, looking straight into the camera, head and shoulders framing, "
                   "studio softbox lighting from the front left, dark blue seamless background, "
                   "news anchor style, 85mm lens, shallow depth of field"),
    ("dreiviertel", f"{BASE}, three-quarter view turned slightly to his left, medium shot from "
                    "chest up, cinematic rim light from behind, dark grey studio background, "
                    "professional interview look, 50mm lens"),
    ("halbprofil", f"{BASE}, side profile view facing right, medium close-up, dramatic soft "
                   "window light from the right side, dark charcoal background, editorial "
                   "magazine style, 85mm lens"),
    ("nahaufnahme", f"{BASE}, extreme close-up of the face filling the frame, eyes sharp, "
                    "skin texture visible with fine detail, soft even lighting, dark background, "
                    "cine lens, high detail"),
    ("halbkoerper", f"{BASE}, half body shot, arms relaxed at his sides, standing in a modern "
                    "TV studio with soft blue light accents and blurred screens behind him, "
                    "professional broadcast look"),
    ("laessig", f"{BASE}, casual look wearing a dark grey sweater, seated at a desk with a "
                "laptop slightly out of focus, warm desk lamp light, podcast studio atmosphere, "
                "medium shot"),
]


def build(prompt: str, seed: int, width: int = 1024, height: int = 1024) -> dict:
    return {
        "37": {"class_type": "UNETLoader",
               "inputs": {"unet_name": UNET, "weight_dtype": "default"}},
        "38": {"class_type": "CLIPLoader",
               "inputs": {"clip_name": CLIP, "type": "qwen_image", "device": "default"}},
        "39": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "66": {"class_type": "ModelSamplingAuraFlow",
               "inputs": {"model": ["37", 0], "shift": 3.1}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["38", 0]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": NEG, "clip": ["38", 0]}},
        "58": {"class_type": "EmptySD3LatentImage",
               "inputs": {"width": width, "height": height, "batch_size": 1}},
        "3": {"class_type": "KSampler",
              "inputs": {"model": ["66", 0], "positive": ["6", 0], "negative": ["7", 0],
                         "latent_image": ["58", 0], "seed": seed, "steps": 20, "cfg": 4.0,
                         "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["39", 0]}},
        "60": {"class_type": "SaveImage",
               "inputs": {"images": ["8", 0], "filename_prefix": "charakter/portrait"}},
    }


def post(payload: dict) -> dict:
    req = urllib.request.Request(API + "/prompt",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=100)
    ap.add_argument("--size", type=int, default=1024)
    a = ap.parse_args()

    for i, (name, prompt) in enumerate(VARIANTS):
        seed = a.seed + i
        t0 = time.time()
        try:
            pid = post({"prompt": build(prompt, seed, a.size, a.size)})["prompt_id"]
        except urllib.error.HTTPError as e:
            print(f"[{name}] VALIDIERUNGSFEHLER: {e.read().decode()[:800]}")
            return
        while True:
            time.sleep(5)
            with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
                hist = json.loads(r.read().decode())
            if pid in hist:
                st = hist[pid].get("status", {})
                outs = hist[pid].get("outputs") or {}
                files = []
                for _n, o in outs.items():
                    for im in o.get("images", []):
                        files.append(im.get("filename"))
                print(f"[{name}] seed={seed} status={st.get('status_str')} "
                      f"({time.time()-t0:.1f}s) -> {files}")
                if st.get("status_str") == "error":
                    print(json.dumps(hist[pid], indent=1)[:1500])
                break


if __name__ == "__main__":
    main()
