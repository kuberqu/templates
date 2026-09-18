#!/usr/bin/env python3
"""Sonde für ComfyUI-Workflows: Template-Struktur + Node-Interfaces.

Aufruf: ltx_probe.py <template.json> [node-filter]
"""
from __future__ import annotations

import json
import sys
import urllib.request

API = "http://127.0.0.1:8188"


def obj_info() -> dict:
    with urllib.request.urlopen(API + "/object_info", timeout=30) as r:
        return json.loads(r.read().decode())


def dump_template(path: str) -> dict:
    d = json.load(open(path))
    print("=" * 70)
    print("TEMPLATE:", path)
    print("Top-Level:", {k: (f"list[{len(v)}]" if isinstance(v, list) else type(v).__name__)
                         for k, v in d.items()})
    nodes = d.get("nodes") or []
    if not nodes and isinstance(d, dict) and d and "class_type" in json.dumps(d)[:200]:
        print("  (sieht nach API-Format aus)")
        return d
    print(f"\nNodes: {len(nodes)}  Links: {len(d.get('links') or [])}")
    for n in nodes:
        wv = n.get("widgets_values") or []
        wvs = ", ".join(str(x)[:28] for x in wv[:6])
        ins = [(i.get("name"), i.get("link")) for i in (n.get("inputs") or [])]
        print(f"  [{n.get('id'):>3}] {n.get('type'):<30} {(n.get('title') or ''):<20}")
        if wvs:
            print(f"        widgets: {wvs}")
        if ins:
            print(f"        inputs : {ins}")
    return d


def dump_nodes(filt: str, info: dict) -> None:
    keys = sorted(k for k in info if filt.lower() in k.lower())
    print("\n" + "=" * 70)
    print(f"NODE-INTERFACES *{filt}* ({len(keys)}):")
    for k in keys:
        spec = info[k].get("input", {})
        req = spec.get("required", {})
        opt = spec.get("optional", {})
        print(f"\n{k}")
        print(f"  category: {info[k].get('category')}  output: {info[k].get('output_name')}")
        for group, items in (("required", req), ("optional", opt)):
            for name, val in items.items():
                t = val[0]
                if isinstance(t, list):
                    t = f"COMBO[{len(t)}]"
                extra = {}
                if isinstance(val[1], dict):
                    extra = {kk: vv for kk, vv in val[1].items()
                             if kk in ("default", "min", "max", "multiline")}
                print(f"    {group:<8} {name:<24} {t} {extra if extra else ''}")


if __name__ == "__main__":
    path = sys.argv[1]
    filt = sys.argv[2] if len(sys.argv) > 2 else "ltxv"
    dump_template(path)
    if filt != "none":
        dump_nodes(filt, obj_info())
