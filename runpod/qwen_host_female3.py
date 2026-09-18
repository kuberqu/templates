#!/usr/bin/env python3
"""Skandinavische Varianten des weiblichen Hosts — Edit-2511 auf Basis von 05_yoga.

Warum Edit statt Neu-Generierung: Mirko gefällt Bild 05 (Pose, Outfit, Studio, Licht).
Deshalb wird NUR das Aussehen (Ethnie) getauscht und alles andere beibehalten.

Graph = Qwen-Image-Edit-2511 + Lightning-LoRA (4 Steps, cfg 1.0), ohne Angles-LoRA,
damit die Kamera exakt so bleibt wie im Referenzbild.

WICHTIG: filename_prefix OHNE "/" (sonst ueberschreibt ComfyUI jede Datei).

Aufruf (auf dem POD):  qwen_host_female3.py --bild weiblich_ref.png [--seed 1400]
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8188"
UNET = "qwen_image_edit_2511_int8_convrot.safetensors"
CLIP = "qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE = "qwen_image_vae.safetensors"
LORA_LIGHT = "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"

# Alles, was am Referenzbild UNVERAENDERT bleiben muss
KEEP = ("keep the exact same pose, the same dark teal yoga top and leggings, the same bright "
        "minimalist studio with light wooden floor and the same large side window light, the "
        "same framing, the same camera angle, the same age (early twenties) and the same slim "
        "athletic build")

SCANDI = ("Scandinavian Nordic features, long light golden blonde hair with soft natural waves, "
          "light blue eyes, fair pale skin with a cool porcelain undertone and a hint of natural "
          "freckles on the nose, high cheekbones, straight narrow nose, light blonde eyebrows, "
          "natural understated makeup, clean look")

SCANDI_ASH = ("Scandinavian Nordic features, long ash blonde to light brown hair in soft natural "
              "waves, grey blue eyes, fair pale skin with a cool natural undertone, straight "
              "slim nose, light eyebrows, minimal natural makeup, clean look")

SCANDI_WARM = ("Scandinavian Nordic features, long honey blonde hair with lighter sun-bleached "
               "ends in soft waves, light green grey eyes, fair skin with a warm light tone and "
               "soft freckles, high cheekbones, straight nose, natural light makeup, clean look")

SCANDI_PLAT = ("Scandinavian Nordic features, long platinum blonde hair, very light blue eyes, "
               "very fair pale skin with a cool undertone, straight narrow nose, light eyebrows, "
               "very natural minimal makeup, clean look")

VARIANTS = [
    ("nordic_gold", 0, SCANDI),
    ("nordic_ash", 1, SCANDI_ASH),
    ("nordic_warm", 2, SCANDI_WARM),
    ("nordic_plat", 3, SCANDI_PLAT),
]


def build(image: str, prompt: str, seed: int, prefix: str) -> dict:
    return {
        "161": {"class_type": "UNETLoader",
                "inputs": {"unet_name": UNET, "weight_dtype": "default"}},
        "162": {"class_type": "CLIPLoader",
                "inputs": {"clip_name": CLIP, "type": "qwen_image", "device": "default"}},
        "146": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "41": {"class_type": "LoadImage", "inputs": {"image": image}},
        "160": {"class_type": "FluxKontextImageScale", "inputs": {"image": ["41", 0]}},
        "151": {"class_type": "TextEncodeQwenImageEditPlus",
                "inputs": {"clip": ["162", 0], "vae": ["146", 0], "image1": ["160", 0],
                           "prompt": prompt}},
        "149": {"class_type": "TextEncodeQwenImageEditPlus",
                "inputs": {"clip": ["162", 0], "vae": ["146", 0], "image1": ["160", 0],
                           "prompt": ""}},
        "148": {"class_type": "FluxKontextMultiReferenceLatentMethod",
                "inputs": {"conditioning": ["151", 0],
                           "reference_latents_method": "index_timestep_zero"}},
        "147": {"class_type": "FluxKontextMultiReferenceLatentMethod",
                "inputs": {"conditioning": ["149", 0],
                           "reference_latents_method": "index_timestep_zero"}},
        "145": {"class_type": "ModelSamplingAuraFlow",
                "inputs": {"model": ["161", 0], "shift": 3.1}},
        "152": {"class_type": "CFGNorm",
                "inputs": {"model": ["145", 0], "strength": 1.0, "pre_cfg": False}},
        "153": {"class_type": "LoraLoaderModelOnly",
                "inputs": {"model": ["152", 0], "lora_name": LORA_LIGHT,
                           "strength_model": 1.0}},
        "156": {"class_type": "VAEEncode",
                "inputs": {"pixels": ["160", 0], "vae": ["146", 0]}},
        "169": {"class_type": "KSampler",
                "inputs": {"model": ["153", 0], "positive": ["148", 0],
                           "negative": ["147", 0], "latent_image": ["156", 0],
                           "seed": seed, "steps": 4, "cfg": 1.0,
                           "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}},
        "158": {"class_type": "VAEDecode",
                "inputs": {"samples": ["169", 0], "vae": ["146", 0]}},
        "9": {"class_type": "SaveImage",
              "inputs": {"images": ["158", 0], "filename_prefix": prefix}},
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bild", default="weiblich_ref.png")
    ap.add_argument("--seed", type=int, default=1400)
    ap.add_argument("--only", default="")
    a = ap.parse_args()

    for name, off, scandi in VARIANTS:
        if a.only and a.only not in name:
            continue
        seed = a.seed + off
        prompt = (f"Change the woman to {scandi}. {KEEP}. Photorealistic photograph, sharp "
                  f"focus on the face, natural skin texture with visible pores, 85mm lens, "
                  f"shallow depth of field.")
        t0 = time.time()
        try:
            req = urllib.request.Request(
                API + "/prompt",
                data=json.dumps({"prompt": build(a.bild, prompt, seed, name)}).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                pid = json.loads(r.read().decode())["prompt_id"]
        except urllib.error.HTTPError as e:
            print(f"[{name}] VALIDIERUNGSFEHLER: {e.read().decode()[:700]}", flush=True)
            return
        while True:
            time.sleep(4)
            with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
                hist = json.loads(r.read().decode())
            if pid in hist:
                st = hist[pid].get("status", {})
                files = [im.get("filename")
                         for o in (hist[pid].get("outputs") or {}).values()
                         for im in o.get("images", [])]
                print(f"[{name}] seed={seed} {st.get('status_str')} "
                      f"({time.time()-t0:.1f}s) -> {files}", flush=True)
                if st.get("status_str") == "error":
                    print(json.dumps(hist[pid], indent=1)[:1200], flush=True)
                break
    print("FERTIG", flush=True)


if __name__ == "__main__":
    main()
