#!/usr/bin/env python3
"""Listet alle LTX-relevanten Nodes kompakt (Name, Typ, Inputs, Outputs)."""
from __future__ import annotations

import json
import urllib.request

API = "http://127.0.0.1:8188"

with urllib.request.urlopen(API + "/object_info", timeout=30) as r:
    info = json.loads(r.read().decode())

PATTERNS = ("ltx", "unetloader", "vaeloader", "cliploader", "checkpointloader",
            "creatvideo", "createvideo", "savevideo", "manualsigmas", "scheduler",
            "emptylatentaudio", "loadimage", "loadaudio")

print("=== LTX-/Loader-Nodes (kompakt) ===")
for k in sorted(info):
    if not any(p in k.lower() for p in PATTERNS):
        continue
    node = info[k]
    inp = node.get("input", {})
    req = inp.get("required", {})
    opt = inp.get("optional", {})

    def fmt(items):
        out = []
        for name, val in items.items():
            t = val[0]
            if isinstance(t, list):
                t = "COMBO"
                if t == "COMBO" and isinstance(val[0], list) and val[0]:
                    t = f"COMBO(n={len(val[0])})"
            meta = val[1] if len(val) > 1 and isinstance(val[1], dict) else {}
            d = meta.get("default")
            out.append(f"{name}:{t}" + (f"={d}" if d is not None else ""))
        return ", ".join(out)

    print(f"\n{k}   [{node.get('category')}]")
    print(f"   out: {node.get('output_name')}")
    if req:
        print(f"   req: {fmt(req)}")
    if opt:
        print(f"   opt: {fmt(opt)}")

print("\n=== Suche nach LTX-2.5-Templates auf der Platte ===")
import subprocess
for pat in ("*ltx2_5*", "*ltx_2_5*", "*ltx25*"):
    out = subprocess.run(["find", "/workspace/venv", "/workspace/ComfyUI", "-name", pat],
                         capture_output=True, text=True).stdout.strip()
    for line in out.splitlines():
        print("  ", line)
