#!/usr/bin/env python3
"""Trainings-Datensatz für ein Charakter-LoRA (Qwen-Image-Edit 2511) bauen.

Grundlage: das gewählte Kanon-Bild. Daraus erzeuge ich Variationen über die
Multiple-Angles-LoRA (Kamera) plus Szenen-/Outfit-Wechsel — dieselbe Person in
unterschiedlichen Situationen, wie es ein Charakter-Datensatz braucht
(15-30 Bilder, verschiedene Posen, Winkel, Licht, Hintergründe).

Captions: Qwen reagiert empfindlich — KEINE Token wie "TOK"/"sks", sondern
beschreibende Sprache. Caption = Identitaets-Beschreibung + Szene/Outfit.

Ergebnis: /workspace/dataset/<name>.png + <name>.txt, danach ZIP.
"""
from __future__ import annotations

import json
import os
import shutil
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8188"
UNET = "qwen_image_edit_2511_int8_convrot.safetensors"
CLIP = "qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE = "qwen_image_vae.safetensors"
LORA_LIGHT = "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
LORA_ANGLES = "Qwen-Edit-2509-Multiple-angles.safetensors"
OUTDIR = "/workspace/dataset"

# Identitaets-Kern (beschreibend, wird in jede Caption geschrieben)
IDENT = ("a man in his mid-thirties with short dark brown hair, light stubble, brown eyes, "
         "and a lean face")

# (Name, Kamera-Kommando, Szene -> Caption)
SHOTS = [
    ("01_frontal_studio", "将镜头转为特写镜头",
     "a close-up shot against a dark blue studio background with soft key light"),
    ("02_dreiviertel_rechts", "将镜头向右旋转45度",
     "a three-quarter view in a dark blue studio, professional broadcast lighting"),
    ("03_dreiviertel_links", "将镜头向左旋转45度",
     "a three-quarter view in a dark blue studio, professional broadcast lighting"),
    ("04_profil", "将镜头向左移动",
     "a medium close-up in side profile against a dark grey studio background"),
    ("05_wide_studio", "将镜头转为广角镜头",
     "a wide-angle half body shot standing in a modern television studio with "
     "blurred screens and blue light accents"),
    ("06_desk_topdown", "将镜头转为俯视",
     "sitting at a modern desk with notes and a monitor, seen from a top-down view, "
     "warm desk lamp light"),
    ("07_outfit_grey", "将镜头向左旋转45度",
     "wearing a grey crew-neck sweater instead of the blazer, seated in a podcast "
     "studio with warm lamp light"),
    ("08_outfit_black", "将镜头向右旋转45度",
     "wearing a black turtleneck, standing in front of a dark grey wall, "
     "cinematic side light"),
    ("09_outfit_hemd", "将镜头向左移动",
     "wearing only a white shirt with rolled up sleeves, in a bright modern office "
     "with large windows"),
    ("10_buero", "将镜头转为广角镜头",
     "standing in a glass-walled meeting room, daylight from the side, "
     "half body shot, colleagues blurred in the background"),
    ("11_aussen", "将镜头向前移动",
     "outdoors in a city street in the late afternoon, warm sunlight, "
     "blurred pedestrians and buildings behind him"),
    ("12_gestik", "将镜头转为特写镜头",
     "mid-sentence with his hands raised in a explaining gesture, "
     "dark blue studio background, news anchor framing"),
    ("13_nahaufnahme", "将镜头向前移动",
     "an extreme close-up of his face, sharp eyes, visible skin texture, "
     "soft even light, dark background"),
    ("14_halbprofil_rechts", "将镜头向右移动",
     "a side profile view facing left against a warm neutral background, "
     "editorial magazine lighting"),
    ("15_sitzend", "将镜头向下移动",
     "seated on a stool with his arms folded, light grey studio background, "
     "soft box lighting from the right"),
    ("16_konferenz", "将镜头转为广角镜头",
     "standing at a large presentation screen in a conference room, "
     "pointing at the screen, cool blue screen glow on his face"),
    ("17_tiefenunschaerfe", "将镜头向左旋转45度",
     "a medium shot with shallow depth of field, blurred warm interior background, "
     "cinematic bokeh"),
    ("18_frontal_hell", "将镜头向前移动",
     "a bright frontal portrait against a light grey background, "
     "high key lighting, friendly expression"),
]


def build(image: str, command: str, scene: str, seed: int, name: str) -> dict:
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
                           "prompt": f"{command} Show the same man as in the input image: "
                                     f"{IDENT}, {scene}"}},
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
              "inputs": {"images": ["158", 0], "filename_prefix": f"dataset/{name}"}},
    }


def main() -> None:
    image = "charakter_9x16.png"
    os.makedirs(OUTDIR, exist_ok=True)
    ok = 0
    for i, (name, cmd, scene) in enumerate(SHOTS):
        seed = 500 + i
        t0 = time.time()
        try:
            req = urllib.request.Request(
                API + "/prompt",
                data=json.dumps({"prompt": build(image, cmd, scene, seed, name)}).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                pid = json.loads(r.read().decode())["prompt_id"]
        except urllib.error.HTTPError as e:
            print(f"[{name}] FEHLER: {e.read().decode()[:400]}")
            continue
        while True:
            time.sleep(4)
            with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
                hist = json.loads(r.read().decode())
            if pid in hist:
                st = hist[pid].get("status", {})
                for o in (hist[pid].get("outputs") or {}).values():
                    for im in o.get("images", []):
                        src = f"/workspace/ComfyUI/output/{im.get('subfolder')}/{im['filename']}"
                        base = f"{OUTDIR}/{name}.png"
                        if os.path.exists(src):
                            shutil.copyfile(src, base)
                            # Caption: Identitaet + Szene (beschreibend, ohne Token)
                            with open(f"{OUTDIR}/{name}.txt", "w") as fh:
                                fh.write(f"a photo of {IDENT}, {scene}")
                            ok += 1
                print(f"[{name}] {st.get('status_str')} ({time.time()-t0:.1f}s)")
                break
    print(f"FERTIG: {ok}/{len(SHOTS)} Bilder + Captions in {OUTDIR}")


if __name__ == "__main__":
    main()
