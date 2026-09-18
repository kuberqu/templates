#!/usr/bin/env python3
"""fal/diffusers-LoRA -> ComfyUI-Format konvertieren (Qwen-Image).

Warum: fal liefert `transformer.transformer_blocks.…lora_A/lora_B.weight`,
ComfyUI erwartet `transformer_blocks.…lora_down/lora_up.weight` (+ `alpha`).
Ohne Konvertierung meldet ComfyUI die LoRA als unbekannt oder ignoriert sie
stillschweigend.

Aufruf: convert_lora.py <in.safetensors> <out.safetensors> [--alpha 32]
                        [--target-mm-prefix "diffusion_model."]
"""
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

import torch
from safetensors.torch import load_file, save_file

MAP = {"lora_A.weight": "lora_down.weight", "lora_B.weight": "lora_up.weight"}


def read_meta(path: str) -> dict:
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        hdr = json.loads(f.read(n))
    md = hdr.get("__metadata__", {})
    if "lora_adapter_metadata" in md:
        try:
            return json.loads(md["lora_adapter_metadata"])
        except Exception:
            return {}
    return md


def rank_of(tensors: dict) -> int:
    for k, v in tensors.items():
        if k.endswith("lora_A.weight"):
            return int(v.shape[0])
    return 0


def convert(src: str, dst: str, alpha: float | None, prefix: str) -> None:
    tensors = load_file(src)
    out: dict = {}
    renamed = 0
    for k, v in tensors.items():
        nk = k
        # 1) diffusers-Praefix entfernen
        if nk.startswith("transformer."):
            nk = nk[len("transformer."):]
        if nk.startswith("diffusion_model."):
            nk = nk[len("diffusion_model."):]
        # 2) lora_A/B -> lora_down/up
        for a, b in MAP.items():
            if nk.endswith(a):
                nk = nk[: -len(a)] + b
                renamed += 1
                break
        out[prefix + nk] = v.contiguous()

    # 3) alpha-Tensoren ergaenzen (ComfyUI skaliert damit)
    if alpha:
        bases = {k[: -len(".lora_down.weight")] for k in out if k.endswith(".lora_down.weight")}
        for b in bases:
            out[b + ".alpha"] = torch.tensor(float(alpha))

    Path(dst).parent.mkdir(parents=True, exist_ok=True)
    save_file(out, dst, metadata={"format": "comfyui", "converted_from": Path(src).name,
                                  "alpha": str(alpha), "rank": str(rank_of(tensors))})
    print(f"konvertiert: {len(tensors)} -> {len(out)} Tensoren "
          f"({renamed} umbenannt), alpha={alpha}, rank={rank_of(tensors)}")
    print("  Ziel:", dst)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--alpha", type=float, default=None)
    ap.add_argument("--prefix", default="", help="optional z.B. 'diffusion_model.'")
    a = ap.parse_args()

    md = read_meta(a.src)
    rank = None
    for k in ("transformer.r", "r", "transformer.lora_alpha", "lora_alpha", "transformer.rank"):
        if k in md:
            print(f"  Metadaten {k} = {md[k]}")
    if a.alpha is None:
        for k in ("transformer.lora_alpha", "lora_alpha"):
            if k in md:
                a.alpha = float(md[k])
                break
    convert(a.src, a.dst, a.alpha, a.prefix)


if __name__ == "__main__":
    main()
