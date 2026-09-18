#!/usr/bin/env python3
"""LoRA-Trainingsdatensatz fuer den weiblichen Host (Charakter 'nordic_ash').

Eingefrorene Figur (Mirko-Entscheid 18.09.):
  Gesicht  = nordic_ash  (aschblond->hellbraun, graublaue Augen, heller Teint, Anfang 20)
  Brust    = B (mittel, B-C Cup, natuerlich)
  Gesaess  = B (mittel, rund-athletisch, nicht flach, nicht voll)

Design-Regeln (aus Mirkos Vorgabe):
  * VIELFALT bei Kleidung (Tops, Pullover, Jacken, Kleider, Business, Sport, Winter)
  * NUR die Person im Bild — keine Objekte, keine Hintergrundgeschichten
  * Hintergruende = schlichte Studio-Flaechen (weiss/grau/dunkel) — das LoRA soll
    die Person lernen, nicht die Szenerie
  * Variation bei Kamera, Ausschnitt, Ausdruck, Frisur (offen / Zopf / Dutt)
  * Captions beschreibend, KEINE Trigger-Tokens ("sks"/"TOK") — Qwen reagiert darauf
    empfindlich

Graph = Qwen-Image-Edit-2511 + Lightning + Multiple-Angles-LoRA (identisch zu
qwen_kanon.py, dort verifiziert). Anker = nordic_anchor.png (Brust B).

WICHTIG: filename_prefix OHNE "/" — ComfyUI legt die Dateien flach in output/ ab.
Das Skript kopiert danach nach /workspace/dataset_weiblich/<name>.png + .txt.

Aufruf (auf dem POD): qwen_host_female4_dataset.py [--anchor nordic_anchor.png] [--seed 2000]
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
UNET = "qwen_image_edit_2511_int8_convrot.safetensors"
CLIP = "qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE = "qwen_image_vae.safetensors"
LORA_LIGHT = "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
LORA_ANGLES = "Qwen-Edit-2509-Multiple-angles.safetensors"
OUTDIR = "/workspace/dataset_weiblich"

# Identitaet (beschreibend — landet so in jeder Caption)
IDENT = ("a young woman in her early twenties with Scandinavian features, long ash blonde to "
         "light brown hair in soft natural waves, grey blue eyes, fair pale skin with a cool "
         "undertone, high cheekbones, straight slim nose, slim athletic build with a natural "
         "medium bust and a natural rounded athletic figure")

# (Name, Kamera-Kommando, Szene/Outfit)
SHOTS = [
    ("01_closeup_weiss", "将镜头转为特写镜头",
     "wearing a simple white fitted tank top, plain light grey seamless studio backdrop, "
     "soft even light, neutral friendly expression"),
    ("02_halb_rolli", "将镜头向前移动",
     "wearing a black turtleneck sweater, plain white seamless studio backdrop, soft box light"),
    ("03_3viertel_denim", "将镜头向左旋转45度",
     "wearing a light blue denim jacket over a white t-shirt, plain beige studio backdrop"),
    ("04_halb_strick", "将镜头向右旋转45度",
     "wearing a cream chunky knit sweater, plain dark grey seamless backdrop"),
    ("05_kleid_leicht", "将镜头转为广角镜头",
     "wearing a light floral summer dress, plain white studio backdrop, half body shot"),
    ("06_blazer", "将镜头向前移动",
     "wearing a dark navy blazer over a white blouse, plain mid grey studio backdrop, "
     "professional look"),
    ("07_hoodie", "将镜头向左移动",
     "wearing a grey hoodie with the hood down, plain light grey backdrop, relaxed expression"),
    ("08_wintermantel", "将镜头向左旋转45度",
     "wearing a dark wool winter coat with a light scarf, plain cool grey backdrop"),
    ("09_regenjacke", "将镜头向右旋转45度",
     "wearing a yellow rain jacket, plain white backdrop"),
    ("10_lederjacke", "将镜头向左旋转45度",
     "wearing a black leather jacket over a white top, plain dark grey backdrop"),
    ("11_hemd_gestreift", "将镜头向右移动",
     "wearing a blue and white striped shirt, plain light grey backdrop"),
    ("12_sport_top", "将镜头转为特写镜头",
     "wearing a dark teal sports top, plain white studio backdrop, neutral calm expression"),
    ("13_zopf_sport", "将镜头向左旋转45度",
     "with her hair tied back in a ponytail, wearing a black sports top, "
     "plain light grey backdrop"),
    ("14_dutt_serioes", "将镜头向前移动",
     "with her hair in a loose bun, wearing a white shirt, plain grey backdrop, "
     "serious expression"),
    ("15_lachend", "将镜头向前移动",
     "laughing openly and happily, wearing a casual grey t-shirt, plain light backdrop"),
    ("16_profil_links", "将镜头向左移动",
     "in side profile facing left, wearing a simple white top, plain grey backdrop"),
    ("17_profil_rechts", "将镜头向右移动",
     "in side profile facing right, wearing a simple black top, plain light backdrop"),
    ("18_untersicht", "将镜头向上移动",
     "seen from a slight low angle, wearing a denim shirt, plain white backdrop"),
    ("19_aufsicht", "将镜头向下移动",
     "seen from a slight high angle, wearing a cream blouse, plain grey backdrop"),
    ("20_dunkel_halb", "将镜头向前移动",
     "wearing a dark green sweater, plain black seamless backdrop, cinematic side light"),
    ("21_cardigan", "将镜头向左旋转45度",
     "wearing a beige cardigan over a white top, plain cream studio backdrop"),
    ("22_winterjacke", "将镜头向右旋转45度",
     "wearing a black puffer jacket, plain light grey backdrop"),
    ("23_abendkleid", "将镜头向前移动",
     "wearing an elegant dark blue evening dress, hair pinned up, plain dark grey backdrop"),
    ("24_hemd_scharf", "将镜头转为特写镜头",
     "wearing a crisp white shirt, plain white backdrop, friendly smile, "
     "sharp focus on the skin texture"),
]

SUFFIX = ("Plain simple background, only the person in frame, no objects, no text, "
          "photorealistic photograph, natural skin texture with visible pores, "
          "sharp focus, 85mm lens")


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
                           "prompt": f"{command} Show the same young woman as in the input "
                                     f"image: {IDENT}, {scene}. {SUFFIX}"}},
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
    ap.add_argument("--anchor", default="nordic_anchor.png")
    ap.add_argument("--seed", type=int, default=2000)
    ap.add_argument("--only", default="")
    a = ap.parse_args()

    os.makedirs(OUTDIR, exist_ok=True)
    ok = 0
    for i, (name, cmd, scene) in enumerate(SHOTS):
        if a.only and a.only not in name:
            continue
        prefix = f"dsf_{name}"
        seed = a.seed + i
        t0 = time.time()
        try:
            req = urllib.request.Request(
                API + "/prompt",
                data=json.dumps({"prompt": build(a.anchor, cmd, scene, seed, prefix)}).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                pid = json.loads(r.read().decode())["prompt_id"]
        except urllib.error.HTTPError as e:
            print(f"[{name}] VALIDIERUNGSFEHLER: {e.read().decode()[:500]}", flush=True)
            continue

        while True:
            time.sleep(4)
            with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
                hist = json.loads(r.read().decode())
            if pid in hist:
                st = hist[pid].get("status", {})
                for o in (hist[pid].get("outputs") or {}).values():
                    for im in o.get("images", []):
                        src = os.path.join("/workspace/ComfyUI/output", im["filename"])
                        if os.path.exists(src):
                            shutil.copyfile(src, f"{OUTDIR}/{name}.png")
                            with open(f"{OUTDIR}/{name}.txt", "w") as fh:
                                fh.write(f"a photo of {IDENT}, {scene}")
                            ok += 1
                print(f"[{name}] {st.get('status_str')} ({time.time()-t0:.1f}s)", flush=True)
                if st.get("status_str") == "error":
                    print(json.dumps(hist[pid], indent=1)[:800], flush=True)
                break
    print(f"FERTIG: {ok} Bilder + Captions in {OUTDIR}", flush=True)


if __name__ == "__main__":
    main()
