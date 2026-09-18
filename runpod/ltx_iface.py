#!/usr/bin/env python3
"""Zeigt die Interfaces exakt benannter Nodes (für den LTX-2.5-Bauplan)."""
from __future__ import annotations

import json
import sys
import urllib.request

API = "http://127.0.0.1:8188"
WANT = sys.argv[1:] or [
    "UNETLoader", "SamplerCustomAdvanced", "LTXVScheduler", "ManualSigmas",
    "VAEDecode", "LatentUpscaleModelLoader", "LTXVSeparateAVLatent",
    "CLIPTextEncode", "ImageScale", "LatentUpscale", "SamplerCustom",
    "KSampler", "LTXVLatentUpsamplerLoader", "ModelPatchLoader",
]

with urllib.request.urlopen(API + "/object_info", timeout=30) as r:
    info = json.loads(r.read().decode())

def _dump(node: dict) -> None:
    inp = node.get("input", {})
    print(f"  category: {node.get('category')} | out: {node.get('output_name')}")
    for group in ("required", "optional"):
        for k, v in inp.get(group, {}).items():
            t = v[0]
            if isinstance(t, list):
                t = f"COMBO(n={len(t)}) erster={t[0] if t else '-'}"
            meta = v[1] if len(v) > 1 and isinstance(v[1], dict) else {}
            bits = {kk: meta[kk] for kk in ("default", "min", "max") if kk in meta}
            print(f"    {group:<8} {k:<22} {t} {bits}")


for name in WANT:
    if name not in info:
        # Fuzzy: alles was den Namen enthält
        cands = [k for k in info if name.lower() in k.lower()]
        if not cands:
            print(f"\n!! {name}: nicht gefunden")
            continue
        for c in cands:
            print(f"\n--- {c} (statt {name}) ---")
            node = info[c]
            _dump(node)
        continue
    print(f"\n{name}")
    _dump(info[name])


def _dump(node: dict) -> None:
    inp = node.get("input", {})
    print(f"  category: {node.get('category')} | out: {node.get('output_name')}")
    for group in ("required", "optional"):
        for k, v in inp.get(group, {}).items():
            t = v[0]
            if isinstance(t, list):
                t = f"COMBO(n={len(t)}) erster={t[0] if t else '-'}"
            meta = v[1] if len(v) > 1 and isinstance(v[1], dict) else {}
            bits = {kk: meta[kk] for kk in ("default", "min", "max") if kk in meta}
            print(f"    {group:<8} {k:<22} {t} {bits}")
