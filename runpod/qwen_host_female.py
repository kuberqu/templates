#!/usr/bin/env python3
"""Charakter-Vorschlaege: junge sportliche Frau (Anfang 20) fuer einen eigenen Kanal.

Sechs Outfit-/Setting-Varianten, damit eine Auswahl moeglich ist. Qwen-Image 2512
T2I (gleicher Graph wie qwen_portraits.py). Aufruf: qwen_host_female.py [--seed 500]
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

# Grundcharakter: sportlich, Anfang 20, freundlich, fotorealistisch
BASE = ("photorealistic portrait photograph of an athletic young woman in her early twenties, "
        "slim sporty build, long dark blonde hair tied back in a sporty ponytail, blue eyes, "
        "light natural makeup, friendly confident smile, smooth skin with realistic texture, "
        "sharp focus on the face")
NEG = ("cartoon, anime, illustration, painting, 3d render, deformed, extra limbs, watermark, "
       "text, logo, low quality, blurry face, child, teenager, plastic skin")

VARIANTS = [
    ("01_tennis",
     f"{BASE}, wearing a white sleeveless tennis top with a deep v-neck, standing on an outdoor "
     "tennis court in bright daylight, blurred green court and net behind her, medium shot from "
     "the waist up, sports editorial photography, 85mm lens, shallow depth of field"),
    ("02_fitness",
     f"{BASE}, wearing a fitted dark grey sports top with a deep v-neck and a light zip jacket "
     "worn open, standing in a bright modern gym, blurred equipment behind her, half body shot, "
     "clean bright lighting, fitness magazine style, 50mm lens"),
    ("03_running",
     f"{BASE}, wearing a light blue sleeveless running top with a deep scoop neck, jogging outdoors "
     "on a park path in warm morning sunlight, blurred trees behind her, medium shot, natural "
     "backlight in her hair, lifestyle sports photography, 85mm lens"),
    ("04_yoga",
     f"{BASE}, wearing a dark teal yoga top with a deep v-neck and high-waist leggings, standing "
     "calmly in a bright minimalist yoga studio with light wooden floor, large window light from "
     "the side, half body shot, serene expression, clean wellness editorial style"),
    ("05_studio_serioes",
     f"{BASE}, wearing a dark blue blazer over a white sports top with a deep v-neck, standing in "
     "a modern TV studio with a dark blue seamless background, soft even studio light, head and "
     "shoulders framing, professional broadcast look for a news channel, 85mm lens"),
    ("06_golf",
     f"{BASE}, wearing a white collared polo shirt unbuttoned at the neck and a light beige skirt, "
     "standing on a golf course with green fairway and blurred trees, warm late afternoon light, "
     "medium shot, sporty elegant country club editorial style, 85mm lens"),
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
               "inputs": {"images": ["8", 0],
                          "filename_prefix": "weiblich/"}},
    }


def post(payload: dict) -> dict:
    req = urllib.request.Request(API + "/prompt", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=500)
    ap.add_argument("--size", type=int, default=1024)
    a = ap.parse_args()
    for i, (name, prompt) in enumerate(VARIANTS):
        seed = a.seed + i
        t0 = time.time()
        try:
            pid = post({"prompt": build(prompt, seed, a.size, a.size)})["prompt_id"]
        except urllib.error.HTTPError as e:
            print(f"[{name}] VALIDIERUNGSFEHLER: {e.read().decode()[:600]}", flush=True)
            return
        while True:
            time.sleep(5)
            with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
                hist = json.loads(r.read().decode())
            if pid in hist:
                st = hist[pid].get("status", {})
                files = [im.get("filename") for _n, o in (hist[pid].get("outputs") or {}).items()
                         for im in o.get("images", [])]
                print(f"[{name}] seed={seed} status={st.get('status_str')} "
                      f"({time.time()-t0:.1f}s) -> {files}", flush=True)
                break
    print("FERTIG", flush=True)


if __name__ == "__main__":
    main()
