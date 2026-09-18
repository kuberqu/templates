#!/usr/bin/env python3
"""Charakter-Kanon: mehrere Ansichten derselben Person aus EINEM Basisbild.

Graph = offizieller Qwen-Image-Edit-2511-Workflow (Template
image_qwen_image_edit_2511.json), ergänzt um die Multiple-Angles-LoRA.

Kamera-Steuerung: Die LoRA (dx8152/Qwen-Edit-2509-Multiple-angles) hat KEINE
Trigger-Wörter, versteht aber Kamera-Kommandos — laut Autor zuverlässig in
chinesischer Form, z. B.:
  将镜头向左旋转45度   Rotate the camera 45 degrees to the left
  将镜头向右旋转45度   Rotate the camera 45 degrees to the right
  将镜头向左移动       Move the camera left
  将镜头转为特写镜头   Turn the camera to a close-up
  将镜头转为广角镜头   Turn the camera to a wide-angle lens
  将镜头转为俯视       Turn the camera to a top-down view
Der Autor verlangt zusätzlich die Qwen-Image-Lightning-LoRA (hier 4 Steps,
cfg 1.0 — deshalb KSampler steps=4/cfg=1.0 statt 40/4).

Aufruf: qwen_kanon.py [--bild charakter_basis.png] [--seed 200]
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

CHAR = ("the same man, 35 years old, pale skin, dark brown short hair, light stubble, "
        "brown eyes, wearing a dark navy blazer over a white shirt")

# (Name, Kamera-Kommando, Szenenbeschreibung)
SHOTS = [
    ("frontal_nah", "将镜头转为特写镜头",
     f"Close-up news anchor shot of {CHAR}, looking straight into the camera, speaking, "
     "dark blue seamless studio background, soft professional key light, 85mm lens"),
    ("rotate45_links", "将镜头向左旋转45度",
     f"Medium shot of {CHAR}, dark blue studio background, professional broadcast lighting"),
    ("rotate45_rechts", "将镜头向右旋转45度",
     f"Medium shot of {CHAR}, dark blue studio background, professional broadcast lighting"),
    ("halbprofil", "将镜头向左移动",
     f"Medium close-up of {CHAR} in side profile, dark grey studio background, "
     "cinematic rim light, editorial style"),
    ("studio_wide", "将镜头转为广角镜头",
     f"Wide-angle half body shot of {CHAR} standing in a modern television studio, "
     "blurred screens and blue light accents in the background"),
    ("schreibtisch", "将镜头转为俯视",
     f"{CHAR} sitting at a modern desk with notes and a monitor, top-down view of the "
     "desk, warm desk lamp, podcast studio"),
]


def build(image: str, command: str, scene: str, seed: int, prefix: str) -> dict:
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
                           "prompt": f"{command} {scene}"}},
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
    ap.add_argument("--bild", default="charakter_basis.png")
    ap.add_argument("--seed", type=int, default=200)
    ap.add_argument("--prefix", default="charakter/kanon")
    ap.add_argument("--only", default="")
    a = ap.parse_args()

    for i, (name, cmd, scene) in enumerate(SHOTS):
        if a.only and a.only not in name:
            continue
        seed = a.seed + i
        t0 = time.time()
        try:
            req = urllib.request.Request(
                API + "/prompt",
                data=json.dumps({"prompt": build(a.bild, cmd, scene, seed,
                                                 f"{a.prefix}_{name}")}).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                pid = json.loads(r.read().decode())["prompt_id"]
        except urllib.error.HTTPError as e:
            print(f"[{name}] VALIDIERUNGSFEHLER: {e.read().decode()[:700]}")
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
                print(f"[{name}] {cmd} seed={seed} {st.get('status_str')} "
                      f"({time.time()-t0:.1f}s) -> {files}")
                if st.get("status_str") == "error":
                    print(json.dumps(hist[pid], indent=1)[:1200])
                break


if __name__ == "__main__":
    main()
