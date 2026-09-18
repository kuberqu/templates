#!/usr/bin/env python3
"""LTX-2.5 T2V — Rekonstruktion des OFFIZIELLEN ComfyUI-Workflows als API-Prompt.

Quelle: comfyui_workflow_templates_json/templates/video_ltx2_5_t2v.json
(Subgraph "Text to Video (LTX-2.5)", 42 Nodes). Abweichungen zu einem naiven
Single-Stage-Bau, die den Unterschied machen (live verifiziert):

  * LTXVDualCFGGuider mit **1.0/1.0** — das Modell ist DISTILLED, CFG>1
    übergewichtet den Negativ-Prompt und lässt die Tonspur kollabieren
    (gemessen: -91 dB Stille statt -14.8 dB).
  * ZWEI Sampling-Stufen: Basis bei halber Zielauflösung, dann
    LTXVLatentUpsampler x2 und eine Refine-Stufe (ManualSigmas 0.85 -> 0.0).
  * ManualSigmas statt LTXVScheduler, Sampler **euler_ancestral**.
  * Textencoder via CLIPLoader(type="ltxv") aus text_encoders/ — kein
    LTXAVTextEncoderLoader (der liest models/checkpoints/).
  * Audio-VAE via Standard-VAELoader (vae/), nicht LTXVAudioVAELoader.
  * VAEDecodeTiled für die Ausgabe (VRAM).
  * 24 fps, Frames = Sekunden * 24 + 1 (8n+1).

Aufruf:
  ltx_official.py "Prompt" [--seconds 5] [--width 720] [--height 1280]
                 [--seed 42] [--out-prefix ltx_test/official]
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8188"

LTX = "ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors"
TEXT_ENC = "gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors"
VIDEO_VAE = "ltx-2.5-video-vae-bf16.safetensors"
AUDIO_VAE = "ltx-2.5-audio-vae-bf16.safetensors"
UPSCALER = "ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"

# Sigma-Folgen aus dem offiziellen Template (Stufe 1 / Stufe 2)
SIGMAS_STAGE1 = "1.0, 0.99375, 0.9875, 0.98125, 0.975, 0.909375, 0.725, 0.421875, 0.0"
SIGMAS_STAGE2 = "0.85, 0.7250, 0.4219, 0.0"
NEGATIVE = "pc game, console game, video game, cartoon, childish, ugly"

FPS = 24


def build(prompt: str, seconds: int, width: int, height: int, seed: int,
          prefix: str, tiled: bool = True) -> dict:
    frames = seconds * FPS + 1                       # 8n+1-Regel
    bw, bh = width // 2, height // 2                 # Basis = halbe Zielgroesse
    decode = "VAEDecodeTiled" if tiled else "VAEDecode"
    decode_in = ({"samples": ["18", 0], "vae": ["16", 0], "tile_size": 512,
                  "overlap": 64, "temporal_size": 64, "temporal_overlap": 16}
                 if tiled else {"samples": ["18", 0], "vae": ["16", 0]})

    return {
        # --- Loader ---
        "1": {"class_type": "UNETLoader",
              "inputs": {"unet_name": LTX, "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader",
              "inputs": {"clip_name": TEXT_ENC, "type": "ltxv", "device": "default"}},
        "16": {"class_type": "VAELoader", "inputs": {"vae_name": VIDEO_VAE}},
        "17": {"class_type": "VAELoader", "inputs": {"vae_name": AUDIO_VAE}},
        "20": {"class_type": "LatentUpscaleModelLoader",
               "inputs": {"model_name": UPSCALER}},
        # --- Konditionierung ---
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["2", 0]}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": NEGATIVE, "clip": ["2", 0]}},
        "5": {"class_type": "LTXVConditioning",
              "inputs": {"positive": ["3", 0], "negative": ["4", 0], "frame_rate": float(FPS)}},
        # --- Latents ---
        "6": {"class_type": "EmptyLTXVLatentVideo",
              "inputs": {"width": bw, "height": bh, "length": frames, "batch_size": 1}},
        "7": {"class_type": "LTXVEmptyLatentAudio",
              "inputs": {"frames_number": frames, "frame_rate": float(FPS),
                         "batch_size": 1, "audio_vae": ["17", 0]}},
        "8": {"class_type": "LTXVConcatAVLatent",
              "inputs": {"video_latent": ["6", 0], "audio_latent": ["7", 0]}},
        # --- Stufe 1: Basis (distilled -> CFG 1.0) ---
        "9": {"class_type": "LTXVDualCFGGuider",
              "inputs": {"model": ["1", 0], "positive": ["5", 0], "negative": ["5", 1],
                         "video_cfg": 1.0, "audio_cfg": 1.0}},
        "10": {"class_type": "RandomNoise", "inputs": {"noise_seed": seed}},
        "11": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler_ancestral"}},
        "12": {"class_type": "ManualSigmas", "inputs": {"sigmas": SIGMAS_STAGE1}},
        "13": {"class_type": "SamplerCustomAdvanced",
               "inputs": {"noise": ["10", 0], "guider": ["9", 0], "sampler": ["11", 0],
                          "sigmas": ["12", 0], "latent_image": ["8", 0]}},
        "14": {"class_type": "LTXVSeparateAVLatent", "inputs": {"av_latent": ["13", 0]}},
        # --- Latent-Upscale x2 (nur Video, Audio unveraendert weiterreichen) ---
        "15": {"class_type": "LTXVLatentUpsampler",
               "inputs": {"samples": ["14", 0], "upscale_model": ["20", 0], "vae": ["16", 0]}},
        "21": {"class_type": "LTXVConcatAVLatent",
               "inputs": {"video_latent": ["15", 0], "audio_latent": ["14", 1]}},
        # --- Stufe 2: Refine (andere Sigma-Folge) ---
        "22": {"class_type": "LTXVDualCFGGuider",
               "inputs": {"model": ["1", 0], "positive": ["5", 0], "negative": ["5", 1],
                          "video_cfg": 1.0, "audio_cfg": 1.0}},
        "23": {"class_type": "RandomNoise", "inputs": {"noise_seed": seed + 1}},
        "24": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler_ancestral"}},
        "25": {"class_type": "ManualSigmas", "inputs": {"sigmas": SIGMAS_STAGE2}},
        "26": {"class_type": "SamplerCustomAdvanced",
               "inputs": {"noise": ["23", 0], "guider": ["22", 0], "sampler": ["24", 0],
                          "sigmas": ["25", 0], "latent_image": ["21", 0]}},
        "18": {"class_type": "LTXVSeparateAVLatent", "inputs": {"av_latent": ["26", 0]}},
        # --- Decode ---
        "19": {"class_type": decode, "inputs": decode_in},
        "27": {"class_type": "LTXVAudioVAEDecode",
               "inputs": {"samples": ["18", 1], "audio_vae": ["17", 0]}},
        "28": {"class_type": "CreateVideo",
               "inputs": {"images": ["19", 0], "fps": float(FPS), "audio": ["27", 0]}},
        "29": {"class_type": "SaveVideo",
               "inputs": {"video": ["28", 0], "filename_prefix": prefix,
                          "format": "auto", "codec": "auto"}},
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt")
    ap.add_argument("--seconds", type=int, default=5)
    ap.add_argument("--width", type=int, default=720)
    ap.add_argument("--height", type=int, default=1280)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--prefix", default="ltx_test/official")
    ap.add_argument("--no-tiled", action="store_true")
    a = ap.parse_args()

    wf = build(a.prompt, a.seconds, a.width, a.height, a.seed, a.prefix,
               tiled=not a.no_tiled)
    frames = a.seconds * FPS + 1
    print(f"OFFIZIELLER LTX-2.5-Graph: {len(wf)} Nodes | Ziel {a.width}x{a.height} | "
          f"Basis {a.width//2}x{a.height//2} | {frames} Frames "
          f"({frames/FPS:.2f}s @{FPS}fps) | 2 Stufen | CFG 1.0/1.0 | seed={a.seed}",
          flush=True)

    t0 = time.time()
    try:
        req = urllib.request.Request(API + "/prompt",
                                     data=json.dumps({"prompt": wf}).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            pid = json.loads(r.read().decode())["prompt_id"]
    except urllib.error.HTTPError as e:
        print(f"VALIDIERUNGSFEHLER {e.code}:\n{e.read().decode()[:3000]}")
        raise SystemExit(2)
    print("queued:", pid, flush=True)

    while True:
        time.sleep(10)
        with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
            hist = json.loads(r.read().decode())
        if pid in hist:
            entry = hist[pid]
            st = entry.get("status", {})
            print(f"STATUS: {st.get('status_str')} completed={st.get('completed')}")
            if st.get("status_str") == "error":
                print(json.dumps(entry, indent=1)[:2500])
                raise SystemExit(3)
            for nid, out in (entry.get("outputs") or {}).items():
                print(f"  Node {nid} -> {json.dumps(out)[:300]}")
            break
        el = time.time() - t0
        if int(el) % 60 < 10:
            print(f"  [{el:6.1f}s]", flush=True)
    print(f"FERTIG nach {time.time()-t0:.1f}s ({(time.time()-t0)/60:.1f} min)")


if __name__ == "__main__":
    main()
