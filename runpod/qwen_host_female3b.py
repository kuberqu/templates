#!/usr/bin/env python3
"""Koerper-/Brustgroessen-Varianten des weiblichen Hosts (Basis: nordic_ash).

Zweck: Vor dem LoRA-Training muss die Figur eingefroren werden. Im Yoga-Framing
(Halbkoerper) ist die Silhouette nicht beurteilbar, deshalb pro Groesse ZWEI
Einstellungen: 'halb' (Kanal-Look, wie im Short) und 'ganz' (Ganzkoerper, damit
die Proportionen sichtbar sind).

Graph = Qwen-Image-Edit-2511 + Lightning (4 Steps, cfg 1.0). Alles ausser der
Brustpartie bleibt unveraendert (Pose, Outfit, Studio, Licht, Gesicht).

WICHTIG: filename_prefix OHNE "/" (ComfyUI ueberschreibt sonst).

Aufruf (auf dem POD): qwen_host_female3b.py --bild nordic_ash_ref.png [--seed 1500]
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

# Gesicht/Identitaet + Umgebung, die NICHT angefasst werden darf (B = aschblond)
IDENT = ("keep the exact same face and identity: long ash blonde to light brown hair in soft "
         "natural waves, grey blue eyes, fair pale skin with a cool undertone, straight slim "
         "nose, light eyebrows, early twenties")
KEEP = (f"{IDENT}, keep the same dark teal yoga top and high-waist leggings, the same bright "
        "minimalist studio with light wooden floor and large side window light, the same slim "
        "athletic build, the same pose")

SIZES = {
    "a_klein": ("a small natural athletic bust (A cup), flat toned chest, runner's build, "
                "no cleavage, modest sportswear fit"),
    "b_mittel": ("a natural medium bust (B to C cup), proportionate and athletic, slight "
                 "natural cleavage line, modest sportswear fit"),
    "c_gross": ("a fuller natural bust (D cup), curvy athletic figure, clearly visible shape "
                "under the sports top, still modest sportswear fit"),
}

FRAMES = {
    "halb": ("half body shot from the waist up, exactly the same framing as before, "
             "same camera angle, same lens"),
    "ganz": ("full body shot showing her from head to toes, standing straight facing the "
             "camera, same studio, same light, same lens, feet visible"),
}

VARIANTS = [(s, f) for s in SIZES for f in FRAMES]


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
    ap.add_argument("--bild", default="nordic_ash_ref.png")
    ap.add_argument("--seed", type=int, default=1500)
    ap.add_argument("--only", default="")
    a = ap.parse_args()

    for i, (size, frame) in enumerate(VARIANTS):
        name = f"body_{size}_{frame}"
        if a.only and a.only not in name:
            continue
        prompt = (f"Change the woman's bust to {SIZES[size]}. {KEEP}. "
                  f"Show her as a {FRAMES[frame]}. Photorealistic photograph, natural skin "
                  f"texture with visible pores, 85mm lens, sharp focus.")
        seed = a.seed + i
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
