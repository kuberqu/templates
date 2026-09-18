#!/usr/bin/env python3
"""Zeigt die Struktur eines ComfyUI-API-Templates (LTX-2.5) kompakt an."""
import glob
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ltx_i2v.json"
data = json.load(open(path))
nodes = data if isinstance(data, dict) and "class_type" not in data else {"0": data}
print("Datei:", path)
print("Nodes:", len(nodes))
print()
for nid, node in sorted(nodes.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0):
    ct = node.get("class_type", "?")
    title = (node.get("_meta") or {}).get("title", "")
    ins = node.get("inputs", {})
    vals = {}
    for k, v in ins.items():
        if isinstance(v, list) and len(v) == 2 and isinstance(v[0], (str, int)):
            vals[k] = f"<-{v[0]}.{v[1]}"
        elif isinstance(v, (str, int, float, bool)):
            s = str(v)
            vals[k] = s[:70] + ("…" if len(s) > 70 else "")
        elif isinstance(v, dict):
            vals[k] = "{…}"
    print(f"[{nid}] {ct}  {('#'+title) if title else ''}")
    for k, v in vals.items():
        print(f"      {k} = {v}")
