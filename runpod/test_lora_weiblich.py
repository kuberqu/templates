#!/usr/bin/env python3
"""LoRA-Test weiblicher Host: derselbe Prompt mit/ohne Charakter-LoRA.

Zweck: VOR dem Produktionseinsatz pruefen, ob das LoRA die Figur trifft und ob es
bei Stärke 0.6-0.8 (Mirkos Vorgabe) sauber aussieht. Getestet wird mit einem NEUEN
Outfit, das NICHT im Trainingssatz vorkommt (dort: kein roter Pullover) - so zeigt
sich, ob das LoRA die Person gelernt hat und nicht die Kleidung.

Vier Faelle, gleicher Seed (nur so ist der Vergleich aussagekraeftig):
  ohne / 0.6 / 0.7 / 0.8

WICHTIG: filename_prefix OHNE "/" (sonst keine Hochzaehlung).

Aufruf (POD): test_lora_weiblich.py [--lora charakter_weiblich.safetensors] [--seed 4242]
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

PROMPT = ("photorealistic portrait photograph of a young woman in her early twenties with "
          "Scandinavian features, long ash blonde to light brown hair in soft natural waves, "
          "grey blue eyes, fair pale skin with a cool undertone, slim athletic build with a "
          "natural medium bust, wearing a red knit sweater, plain light grey studio backdrop, "
          "natural skin texture with visible pores, sharp focus on the face, 85mm lens")
NEG = ("cartoon, anime, illustration, painting, 3d render, deformed, extra limbs, watermark, "
       "text, logo, low quality, blurry face, plastic skin")


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
               "inputs": {"images": ["8", 0], "filename_prefix": "loratestf"}},
    }
    if lora:
        g["70"] = {"class_type": "LoraLoaderModelOnly",
                   "inputs": {"model": ["66", 0], "lora_name": lora,
                              "strength_model": strength}}
        g["3"]["inputs"]["model"] = ["70", 0]
    return g


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lora", default="charakter_weiblich.safetensors")
    ap.add_argument("--seed", type=int, default=4242)
    a = ap.parse_args()

    cases = [("ohne", None, 0.0), ("06", a.lora, 0.6), ("07", a.lora, 0.7),
             ("08", a.lora, 0.8)]
    for name, lora, st in cases:
        g = graph(PROMPT, a.seed, lora, st)
        g["60"]["inputs"]["filename_prefix"] = f"loratestf_{name}"
        t0 = time.time()
        try:
            req = urllib.request.Request(API + "/prompt",
                                         data=json.dumps({"prompt": g}).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                pid = json.loads(r.read().decode())["prompt_id"]
        except urllib.error.HTTPError as e:
            print(f"[{name}] FEHLER: {e.read().decode()[:700]}", flush=True)
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
                print(f"[{name:>4}] {stt} ({time.time()-t0:.1f}s) -> {files}", flush=True)
                break
    print("FERTIG", flush=True)


if __name__ == "__main__":
    main()
