#!/usr/bin/env python3
"""Bauplan-Helfer: COMBO-Optionen + Verkabelung eines Referenz-Templates."""
from __future__ import annotations

import json
import urllib.request

API = "http://127.0.0.1:8188"

with urllib.request.urlopen(API + "/object_info", timeout=30) as r:
    info = json.loads(r.read().decode())

print("=== COMBO-Optionen (was kann gewählt werden?) ===")
for node, keys in [
    ("UNETLoader", ["unet_name", "weight_dtype"]),
    ("LTXAVTextEncoderLoader", ["text_encoder", "ckpt_name", "device"]),
    ("LTXVAudioVAELoader", ["ckpt_name"]),
    ("VAELoader", ["ckpt_name"]),
    ("LatentUpscaleModelLoader", ["model_name"]),
    ("SaveVideo", None),
    ("CreateVideo", None),
    ("RandomNoise", None),
    ("KSamplerSelect", ["sampler_name"]),
]:
    if node not in info:
        print(f"\n!! {node} fehlt")
        continue
    inp = info[node].get("input", {})
    print(f"\n{node}")
    for group in ("required", "optional"):
        for k, v in inp.get(group, {}).items():
            if keys and k not in keys:
                continue
            t = v[0]
            if isinstance(t, list):
                opts = [str(x) for x in t]
                show = opts if len(opts) <= 12 else opts[:12] + [f"…(+{len(opts)-12})"]
                print(f"   {k}: COMBO {show}")
            else:
                meta = v[1] if len(v) > 1 and isinstance(v[1], dict) else {}
                print(f"   {k}: {t} {meta.get('default', '')}")

# Referenz-Template: lokale LTX-2.3-Verkabelung
print("\n\n=== Referenz template video_ltx2_3_i2v.json: Verkabelung ===")
try:
    tpl = json.load(open("/tmp/ltx23_i2v.json"))
except FileNotFoundError:
    print("  (Datei fehlt)")
    raise SystemExit
links = {l[0]: l for l in (tpl.get("links") or []) if isinstance(l, list)}
byid = {n["id"]: n for n in tpl.get("nodes", [])}
for n in tpl.get("nodes", []):
    inc = []
    for i in (n.get("inputs") or []):
        lid = i.get("link")
        if lid in links:
            l = links[lid]
            src = byid.get(l[1], {})
            inc.append(f"{i.get('name')}<-{src.get('type')}({l[1]})")
    wv = ", ".join(str(x)[:22] for x in (n.get("widgets_values") or [])[:5])
    print(f"  [{n['id']:>3}] {n.get('type'):<26} {wv}")
    if inc:
        print(f"        in: {', '.join(inc)}")
