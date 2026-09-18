#!/usr/bin/env python3
"""Figuren-Vergleich Teil 2: Gesaessform/-groesse (Basis nordic_ash + Brust 'mittel').

Das Yoga-Referenzbild ist ein Halbkoerper-Frontalportrait — der Po ist darin nicht
sichtbar. Deshalb hier zwei Ansichten, in denen die Silhouette beurteilbar ist:

  seite : Qwen-Edit-2509-Multiple-angles-LoRA, Kamera-Kommando (chinesisch, wie vom
          LoRA-Autor empfohlen) + Beschreibung "three-quarter view from behind"
  hinten: explizite Rueckansicht per Text (die LoRA kennt kein zuverlaessiges
          "Ganz hinten"-Kommando)

Graph = Qwen-Image-Edit-2511 + Lightning-LoRA (4 Steps, cfg 1.0) + Angles-LoRA,
identisch zu qwen_kanon.py (dort verifiziert).

WICHTIG: filename_prefix OHNE "/".

Aufruf (auf dem POD): qwen_host_female3c.py --bild nordic_ash_ref.png [--seed 1600]
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
LORA_ANGLES = "Qwen-Edit-2509-Multiple-angles.safetensors"

IDENT = ("the same woman as in the reference image: long ash blonde to light brown hair in "
         "soft natural waves, fair pale skin with a cool undertone, early twenties, natural "
         "medium bust (B to C cup)")

KEEP = (f"{IDENT}, dark teal yoga top and matching high-waist leggings that fit closely, "
        "the same bright minimalist studio with light wooden floor, same large side window "
        "light, same slim athletic build")

SIZES = {
    "a_flach": ("a small flat athletic rear, toned runner's glutes, no visible volume, "
                "straight silhouette in the leggings"),
    "b_mittel": ("a natural rounded athletic rear, medium size, toned and firm, a clearly "
                 "defined but moderate silhouette in the leggings"),
    "c_voll": ("a fuller round rear, curvy athletic build, clearly visible volume and shape "
               "in the close-fitting leggings"),
}

VIEWS = {
    "seite": ("将镜头向左旋转45度",
              f"Three-quarter view from behind of {KEEP}, __GROESSE__, standing "
              "straight with relaxed arms, she looks over her shoulder away from the camera, "
              "photorealistic photograph, natural skin texture, 85mm lens"),
    "hinten": ("",
               f"Rear view of {KEEP} seen from behind, __GROESSE__, standing straight "
               "facing away from the camera, arms relaxed at her sides, back and legs visible, "
               "photorealistic photograph, natural skin and fabric texture, 85mm lens"),
}


def build(image: str, command: str, scene: str, seed: int, prefix: str) -> dict:
    prompt = f"{command} {scene}".strip()
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
        "154": {"class_type": "LoraLoaderModelOnly",
                "inputs": {"model": ["153", 0], "lora_name": LORA_ANGLES,
                           "strength_model": 1.0}},
        "156": {"class_type": "VAEEncode",
                "inputs": {"pixels": ["160", 0], "vae": ["146", 0]}},
        "169": {"class_type": "KSampler",
                "inputs": {"model": ["154", 0], "positive": ["148", 0],
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
    ap.add_argument("--bild", default="nordic_ash_ref.png")
    ap.add_argument("--seed", type=int, default=1600)
    ap.add_argument("--only", default="")
    a = ap.parse_args()

    i = 0
    for view, (cmd, tmpl) in VIEWS.items():
        for size, size_desc in SIZES.items():
            if a.only and a.only not in f"{size}_{view}":
                continue
            name = f"po_{size}_{view}"
            scene = tmpl.replace("__GROESSE__", size_desc)
            seed = a.seed + i
            i += 1
            t0 = time.time()
            try:
                req = urllib.request.Request(
                    API + "/prompt",
                    data=json.dumps({"prompt": build(a.bild, cmd, scene, seed, name)}).encode(),
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
