#!/usr/bin/env python3
"""Talking-Head-Bakeoff auf dem POD: InfiniteTalk vs. Wan2.2 S2V.

Beide Graphen sind 1:1 aus den offiziellen ComfyUI-Templates
(Comfy-Org/workflow_templates: video_wan2_1_infinitetalk.json,
video_wan2_2_14B_s2v.json) abgeleitet — inkl. der dort gesetzten
Sampler-Werte:

  InfiniteTalk : KSamplerSelect euler / CFGGuider 1.0 / BasicScheduler
                 "normal" 6 Steps / ModelSamplingSD3 shift 8 /
                 LoRA lightx2v_I2V_14B_480p_...rank64 @1.0 /
                 negativ = ConditioningZeroOut(positiv) / 25 fps
  Wan2.2 S2V   : KSampler 20 Steps cfg 6.0 / uni_pc / simple /
                 ModelSamplingSD3 shift 8 / 16 fps / kein LoRA

Aufruf (auf dem POD):
  run_wan_talk.py it  --audio szene_01.wav --bild host_ref.png --sekunden 3.07
  run_wan_talk.py s2v --audio szene_01.wav --bild host_ref.png --sekunden 3.07
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8188"

POS = ("A person speaks to the camera, mouth moving naturally with the speech, "
       "subtle natural head movement, fixed camera, realistic skin, sharp focus, "
       "no camera motion")

NEG = ("blurry, low quality, distorted face, deformed mouth, extra fingers, "
       "text, watermark, subtitles, static, overexposed, cartoon")


def frames_for(seconds: float, fps: int) -> int:
    """Wan-Video-Laenge: 4n+1 Frames."""
    n = max(1, round(seconds * fps / 4))
    return 4 * n + 1


def base_nodes(unet: str, patch: str | None, lora: str | None) -> dict:
    n = {
        "1": {"class_type": "UNETLoader",
              "inputs": {"unet_name": unet, "weight_dtype": "default"}},
        "3": {"class_type": "CLIPLoader",
              "inputs": {"clip_name": "umt5_xxl_fp16.safetensors", "type": "wan",
                         "device": "default"}},
        "4": {"class_type": "VAELoader", "inputs": {"vae_name": "wan_2.1_vae.safetensors"}},
        "13": {"class_type": "ModelSamplingSD3", "inputs": {"model": ["1", 0], "shift": 8.0}},
    }
    tail = "13"
    if lora:
        n["14"] = {"class_type": "LoraLoaderModelOnly",
                   "inputs": {"model": ["13", 0], "lora_name": lora,
                              "strength_model": 1.0}}
        tail = "14"
    if patch:
        n["2"] = {"class_type": "ModelPatchLoader", "inputs": {"name": patch}}
    n["_tail"] = tail
    return n


def build_it(a: argparse.Namespace, length: int) -> dict:
    g = base_nodes("wan2.1_i2v_480p_14B_fp16.safetensors",
                   "wan2.1_infiniteTalk_single_fp16.safetensors",
                   "lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors")
    tail = g.pop("_tail")
    g.update({
        "5": {"class_type": "CLIPVisionLoader",
              "inputs": {"clip_name": "clip_vision_h.safetensors"}},
        "6": {"class_type": "LoadImage", "inputs": {"image": a.bild}},
        "7": {"class_type": "CLIPVisionEncode",
              "inputs": {"clip_vision": ["5", 0], "image": ["6", 0], "crop": "center"}},
        "8": {"class_type": "LoadAudio", "inputs": {"audio": a.audio}},
        "9": {"class_type": "AudioEncoderLoader",
              "inputs": {"audio_encoder_name": a.audio_encoder}},
        "10": {"class_type": "AudioEncoderEncode",
               "inputs": {"audio_encoder": ["9", 0], "audio": ["8", 0]}},
        "11": {"class_type": "CLIPTextEncode",
               "inputs": {"text": a.prompt or POS, "clip": ["3", 0]}},
        "12": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["11", 0]}},
        "15": {"class_type": "WanInfiniteTalkToVideo",
               "inputs": {"mode": "single_speaker", "model": [tail, 0],
                          "model_patch": ["2", 0], "positive": ["11", 0],
                          "negative": ["12", 0], "vae": ["4", 0],
                          "width": a.breite, "height": a.hoehe, "length": length,
                          "motion_frame_count": 9, "audio_scale": 1.0,
                          "audio_encoder_output_1": ["10", 0],
                          "clip_vision_output": ["7", 0], "start_image": ["6", 0]}},
        "16": {"class_type": "KSampler",
               "inputs": {"model": ["15", 0], "positive": ["15", 1],
                          "negative": ["15", 2], "latent_image": ["15", 3],
                          "seed": a.seed, "steps": 6, "cfg": 1.0,
                          "sampler_name": "euler", "scheduler": "normal",
                          "denoise": 1.0}},
        "17": {"class_type": "VAEDecode", "inputs": {"samples": ["16", 0], "vae": ["4", 0]}},
        "18": {"class_type": "CreateVideo",
               "inputs": {"images": ["17", 0], "fps": 25.0, "audio": ["8", 0]}},
        "19": {"class_type": "SaveVideo",
               "inputs": {"video": ["18", 0], "filename_prefix": a.prefix,
                          "format": "auto", "codec": "auto"}},
    })
    return g


def build_s2v(a: argparse.Namespace, length: int) -> dict:
    g = base_nodes(a.unet or "wan2.2_s2v_14B_bf16.safetensors", None,
                   a.lora or None)
    tail = g.pop("_tail")
    g.update({
        "6": {"class_type": "LoadImage", "inputs": {"image": a.bild}},
        "8": {"class_type": "LoadAudio", "inputs": {"audio": a.audio}},
        "9": {"class_type": "AudioEncoderLoader",
              "inputs": {"audio_encoder_name": a.audio_encoder}},
        "10": {"class_type": "AudioEncoderEncode",
               "inputs": {"audio_encoder": ["9", 0], "audio": ["8", 0]}},
        "11": {"class_type": "CLIPTextEncode",
               "inputs": {"text": a.prompt or POS, "clip": ["3", 0]}},
        "12": {"class_type": "CLIPTextEncode",
               "inputs": {"text": NEG, "clip": ["3", 0]}},
        "15": {"class_type": "WanSoundImageToVideo",
               "inputs": {"positive": ["11", 0], "negative": ["12", 0], "vae": ["4", 0],
                          "width": a.breite, "height": a.hoehe, "length": length,
                          "batch_size": 1, "audio_encoder_output": ["10", 0],
                          "ref_image": ["6", 0]}},
        "16": {"class_type": "KSampler",
               "inputs": {"model": [tail, 0], "positive": ["15", 0],
                          "negative": ["15", 1], "latent_image": ["15", 2],
                          "seed": a.seed, "steps": a.steps, "cfg": a.cfg,
                          "sampler_name": "uni_pc", "scheduler": "simple",
                          "denoise": 1.0}},
        "17": {"class_type": "VAEDecode", "inputs": {"samples": ["16", 0], "vae": ["4", 0]}},
        "18": {"class_type": "CreateVideo",
               "inputs": {"images": ["17", 0], "fps": 16.0, "audio": ["8", 0]}},
        "19": {"class_type": "SaveVideo",
               "inputs": {"video": ["18", 0], "filename_prefix": a.prefix,
                          "format": "auto", "codec": "auto"}},
    })
    return g


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["it", "s2v"])
    ap.add_argument("--audio", default="szene_01.wav")
    ap.add_argument("--bild", default="host_ref.png")
    ap.add_argument("--sekunden", type=float, default=3.07)
    ap.add_argument("--seed", type=int, default=7701)
    ap.add_argument("--breite", type=int, default=480)
    ap.add_argument("--hoehe", type=int, default=832)
    ap.add_argument("--prefix", default="")
    ap.add_argument("--prompt", default="")
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--cfg", type=float, default=6.0)
    ap.add_argument("--lora", default="")
    ap.add_argument("--unet", default="")
    ap.add_argument("--audio-encoder", dest="audio_encoder",
                    default="wav2vec2-chinese-base_fp16.safetensors")
    a = ap.parse_args()

    fps = 25 if a.mode == "it" else 16
    length = frames_for(a.sekunden, fps)
    a.prefix = a.prefix or f"talk_{a.mode}"
    g = build_it(a, length) if a.mode == "it" else build_s2v(a, length)

    print(f"[{a.mode}] {a.breite}x{a.hoehe} {length} Frames @{fps}fps "
          f"({length/fps:.2f}s) steps={6 if a.mode == 'it' else a.steps} "
          f"cfg={1.0 if a.mode == 'it' else a.cfg}", flush=True)

    t0 = time.time()
    try:
        req = urllib.request.Request(API + "/prompt",
                                     data=json.dumps({"prompt": g}).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            pid = json.loads(r.read().decode())["prompt_id"]
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print("VALIDIERUNGSFEHLER:", body[:1500], flush=True)
        raise SystemExit(1)

    while True:
        time.sleep(10)
        with urllib.request.urlopen(f"{API}/history/{pid}", timeout=30) as r:
            hist = json.loads(r.read().decode())
        if pid in hist:
            st = hist[pid].get("status", {})
            outs = hist[pid].get("outputs") or {}
            print(f"[{a.mode}] {st.get('status_str')} ({time.time()-t0:.0f}s)")
            print(json.dumps(outs, ensure_ascii=False)[:800])
            if st.get("status_str") == "error":
                print(json.dumps(hist[pid].get("status", {}).get("messages", []),
                                 ensure_ascii=False)[:2000])
            break
    print("FERTIG", flush=True)


if __name__ == "__main__":
    main()
