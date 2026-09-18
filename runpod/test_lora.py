#!/usr/bin/env python3
"""LoRA-Test: dieselbe Beschreibung mit/ohne trainierte Charakter-LoRA.

Aufruf: test_lora.py [--lora charakter_qwen2512.safetensors] [--seed 900]

Erzeugt drei Bilder in ComfyUI/output/lora_test/:
  ohne      - nur Basismodell (Kontrolle)
  1.0       - LoRA mit voller Staerke
  0.8       - LoRA leicht reduziert (oft natuerlicher)
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

PROMPT = ("photorealistic portrait photograph of a man in his mid-thirties with short dark "
          "brown hair, light stubble, brown eyes and a lean face, wearing a dark navy blazer "
          "over a white shirt, medium shot, dark blue studio background, soft key light, 85mm lens")
NEG = "cartoon, anime, illustration, painting, 3d render, deformed, extra limbs, watermark, text"


def graph(prompt: str, seed: int, lora: str | None, strength: float,
          w: int = 832, h: int = 1216) -> dict:
    g = {
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
               "inputs": {"width": w, "height": h, "batch_size": 1}},
        "3": {"class_type": "KSampler",
              "inputs": {"model": ["66", 0], "positive": ["6", 0], "negative": ["7", 0],
                         "latent_image": ["58", 0], "seed": seed, "steps": 20, "cfg": 4.0,
                         "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["39", 0]}},
        "60": {"class_type": "SaveImage",
               "inputs": {"images": ["8", 0], "filename_prefix": "lora_test/x"}},
    }
    if lora:
        g["70"] = {"class_type": "LoraLoaderModelOnly",
                   "inputs": {"model": ["66", 0], "lora_name": lora,
                              "strength_model": strength}}
        g["3"]["inputs"]["model"] = ["70", 0]
    return g


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lora", default="charakter_qwen2512.safetensors")
    ap.add_argument("--seed", type=int, default=900)
    ap.add_argument("--strength", type=float, default=0.7,
                    help="LoRA-Staerke (Nutzer-Standard 0.6-0.8, nicht 1.0)")
    a = ap.parse_args()

    st = round(a.strength, 2)
    # Vergleichsfälle: ohne LoRA, gewaehlte Staerke, ein Referenzwert auerhalb
    # des gewaehlten Bereichs (0.6-0.8 ist Nutzer-Standard, nicht 1.0)
    ref = 0.8 if st != 0.8 else 0.6
    cases = [("ohne", None, 0.0), (f"{st}", a.lora, st), (f"{ref}", a.lora, ref)]
    for name, lora, st in cases:
        # Prefix je Fall, damit die Dateien unterscheidbar sind
        g = graph(PROMPT, a.seed, lora, st)
        g["60"]["inputs"]["filename_prefix"] = f"lora_test/{name}"
        t0 = time.time()
        try:
            req = urllib.request.Request(API + "/prompt",
                                         data=json.dumps({"prompt": g}).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                pid = json.loads(r.read().decode())["prompt_id"]
        except urllib.error.HTTPError as e:
            print(f"[{name}] FEHLER: {e.read().decode()[:600]}")
            continue
        while True:
            time.sleep(4)
            with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
                hist = json.loads(r.read().decode())
            if pid in hist:
                stt = hist[pid].get("status", {}).get("status_str")
                files = [im["filename"]
                         for o in (hist[pid].get("outputs") or {}).values()
                         for im in o.get("images", [])]
                print(f"[{name:>4}] {stt} ({time.time()-t0:.1f}s) -> {files}")
                break


if __name__ == "__main__":
    main()
