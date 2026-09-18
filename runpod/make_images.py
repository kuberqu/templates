#!/usr/bin/env python3
"""Szenenbilder erzeugen: Host-Szenen über den Charakter-Kanon, B-Roll via T2I.

Aufruf: make_images.py <script.json> [--basis charakter_9x16.png]
                       [--out-dir /workspace/shorts/<projekt>]

Host  -> Qwen-Image-Edit 2511 + Multiple-Angles-LoRA + Lightning (Kamera-Kommando
         im Prompt steuert die Ansicht), Basis = Kanonbild.
B-Roll-> Qwen-Image 2512 T2I, 768x1344 (Vielfache von 32, 9:16).

Ergebnis: <out-dir>/images/szene_NN.png
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
LTX_UNET = "qwen_image_2512_fp8_e4m3fn.safetensors"
EDIT_UNET = "qwen_image_edit_2511_int8_convrot.safetensors"
CLIP = "qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE = "qwen_image_vae.safetensors"
LORA_LIGHT = "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
LORA_ANGLES = "Qwen-Edit-2509-Multiple-angles.safetensors"
NEG = "cartoon, anime, illustration, painting, 3d render, deformed, extra limbs, watermark, text"


def t2i(prompt: str, seed: int, w: int, h: int, prefix: str) -> dict:
    return {
        "37": {"class_type": "UNETLoader",
               "inputs": {"unet_name": LTX_UNET, "weight_dtype": "default"}},
        "38": {"class_type": "CLIPLoader",
               "inputs": {"clip_name": CLIP, "type": "qwen_image", "device": "default"}},
        "39": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "66": {"class_type": "ModelSamplingAuraFlow", "inputs": {"model": ["37", 0], "shift": 3.1}},
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
               "inputs": {"images": ["8", 0], "filename_prefix": prefix}},
    }


def edit(basis: str, prompt: str, seed: int, prefix: str) -> dict:
    return {
        "161": {"class_type": "UNETLoader",
                "inputs": {"unet_name": EDIT_UNET, "weight_dtype": "default"}},
        "162": {"class_type": "CLIPLoader",
                "inputs": {"clip_name": CLIP, "type": "qwen_image", "device": "default"}},
        "146": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "41": {"class_type": "LoadImage", "inputs": {"image": basis}},
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
                "inputs": {"model": ["152", 0], "lora_name": LORA_LIGHT, "strength_model": 1.0}},
        "154": {"class_type": "LoraLoaderModelOnly",
                "inputs": {"model": ["153", 0], "lora_name": LORA_ANGLES, "strength_model": 1.0}},
        "156": {"class_type": "VAEEncode", "inputs": {"pixels": ["160", 0], "vae": ["146", 0]}},
        "169": {"class_type": "KSampler",
                "inputs": {"model": ["154", 0], "positive": ["148", 0], "negative": ["147", 0],
                           "latent_image": ["156", 0], "seed": seed, "steps": 4, "cfg": 1.0,
                           "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}},
        "158": {"class_type": "VAEDecode", "inputs": {"samples": ["169", 0], "vae": ["146", 0]}},
        "9": {"class_type": "SaveImage",
              "inputs": {"images": ["158", 0], "filename_prefix": prefix}},
    }


def post(payload: dict) -> str:
    req = urllib.request.Request(API + "/prompt", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())["prompt_id"]


def wait(pid: str) -> tuple[str, str | None]:
    while True:
        time.sleep(4)
        with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
            hist = json.loads(r.read().decode())
        if pid in hist:
            st = hist[pid].get("status", {}).get("status_str")
            f = None
            for o in (hist[pid].get("outputs") or {}).values():
                for im in o.get("images", []):
                    f = im
            return st, (f"{f['subfolder']}/{f['filename']}" if f else None)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("script")
    ap.add_argument("--basis", default="charakter_9x16.png")
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--w", type=int, default=768)
    ap.add_argument("--h", type=int, default=1344)
    ap.add_argument("--seed", type=int, default=700)
    ap.add_argument("--only", default="", help="nur diese Szenen-IDs, z.B. 4,10")
    a = ap.parse_args()

    cfg = json.load(open(a.script))
    base = a.out_dir or os.path.join("/workspace/shorts",
                                     os.path.basename(os.path.dirname(a.script)))
    idir = os.path.join(base, "images")
    os.makedirs(idir, exist_ok=True)

    want = [int(x) for x in a.only.split(",") if x.strip()] if a.only else []
    for i, sz in enumerate(cfg["szenen"]):
        if want and sz["id"] not in want:
            continue
        seed = a.seed + sz["id"] * 10
        pf = f"short_{os.path.basename(base)}/szene_{sz['id']:02d}"
        wf = (edit(a.basis, sz["bild_prompt"], seed, pf) if sz["typ"] == "host"
              else t2i(sz["bild_prompt"], seed, a.w, a.h, pf))
        t0 = time.time()
        try:
            pid = post({"prompt": wf})
        except urllib.error.HTTPError as e:
            print(f"  Szene {sz['id']}: FEHLER {e.read().decode()[:300]}")
            continue
        st, fn = wait(pid)
        if fn:
            src = f"/workspace/ComfyUI/output/{fn}"
            dst = os.path.join(idir, f"szene_{sz['id']:02d}.png")
            if os.path.exists(src):
                shutil.copyfile(src, dst)
        print(f"  Szene {sz['id']:>2} ({sz['typ']:<5}) {st} {time.time()-t0:6.1f}s "
              f"-> {os.path.basename(dst) if fn else 'KEIN BILD'}")
    print("Bilder in:", idir)


if __name__ == "__main__":
    main()
