#!/usr/bin/env python3
"""Zeigt die Kernverdrahtung eines konvertierten API-Prompts."""
from __future__ import annotations

import json
import sys

d = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/i2v.json"))
keys = sys.argv[2].split(",") if len(sys.argv) > 2 else sorted(
    d, key=lambda x: int(x) if x.lstrip("-").isdigit() else 0)

for k in keys:
    n = d.get(k)
    if not n:
        print(f"[{k:>4}] (fehlt)")
        continue
    vals, links = {}, {}
    for kk, vv in n["inputs"].items():
        if isinstance(vv, list) and len(vv) == 2 and (str(vv[0]).lstrip("-").isdigit()):
            links[kk] = f"<-{vv[0]}.{vv[1]}"
        else:
            vals[kk] = (vv[:60] + "…") if isinstance(vv, str) and len(vv) > 60 else vv
    print(f"[{k:>4}] {n['class_type']}")
    if vals:
        print(f"        val  : {vals}")
    if links:
        print(f"        links: {links}")
