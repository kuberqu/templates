#!/usr/bin/env python3
"""Analysiert den Subgraphen eines ComfyUI-Templates (LTX-2.5)."""
from __future__ import annotations

import json
import sys

T = "/workspace/venv/lib/python3.12/site-packages/comfyui_workflow_templates_json/templates"
path = sys.argv[1] if len(sys.argv) > 1 else T + "/video_ltx2_5_t2v.json"

d = json.load(open(path))
subs = (d.get("definitions") or {}).get("subgraphs") or []
sub = subs[0]
print("Subgraph-Keys:", list(sub.keys()))
print("Anzahl Subgraphs:", len(subs))
for i, s in enumerate(subs):
    print(f"  [{i}] {s.get('name')} nodes={len(s.get('nodes') or [])} links={len(s.get('links') or [])}")
print()
print("sub.inputs :", json.dumps(sub.get("inputs"))[:500])
print("sub.outputs:", json.dumps(sub.get("outputs"))[:500])
print()

# Subgraph-Node im Hauptgraphen finden
uid = sub.get("id")
print(f"=== Hauptgraph-Node mit id={uid} (Subgraph-Instanz) ===")
for n in d.get("nodes", []):
    if str(n.get("id")) == str(uid) or n.get("type") == uid:
        print("  id:", n.get("id"), "type:", n.get("type"))
        print("  inputs :", json.dumps(n.get("inputs"))[:600])
        print("  outputs:", json.dumps(n.get("outputs"))[:600])
        print("  widgets:", n.get("widgets_values"))
print()
print("=== Hauptgraph-Links ===")
for l in d.get("links") or []:
    print("  ", l)
print()
print("=== Kernwerte im Subgraph ===")
for n in sub["nodes"]:
    t = n.get("type")
    if t in ("ManualSigmas", "ComfyMathExpression", "PrimitiveInt", "PrimitiveBoolean",
             "PrimitiveStringMultiline", "LTXVDualCFGGuider", "EmptyLTXVLatentVideo",
             "LTXVEmptyLatentAudio", "LTXVConditioning", "CreateVideo", "RandomNoise",
             "KSamplerSelect", "UNETLoader", "VAELoader", "CLIPLoader",
             "LatentUpscaleModelLoader", "CLIPTextEncode", "VAEDecodeTiled",
             "ComfySwitchNode", "TextGenerateLTX2Prompt"):
        print(f"  [{n['id']:>3}] {t:<26} {str(n.get('widgets_values'))[:110]}")
print()
print("=== inputNode / outputNode ===")
for key in ("inputNode", "outputNode"):
    node = sub.get(key)
    if not node:
        continue
    print(f"[{key}] id={node.get('id')} type={node.get('type')}")
    for i in (node.get("inputs") or []):
        print(f"   in : {i.get('name')} link={i.get('link')}")
    for o in (node.get("outputs") or []):
        print(f"   out: {o.get('name')} links={o.get('links')}")
print()
print("=== Knoten, die auf den inputNode verweisen (Ports -> innen) ===")
inode = str((sub.get("inputNode") or {}).get("id"))
for l in links:
    if isinstance(l, list) and len(l) >= 5:
        lid, oid, oslot, tid, tslot = l[0], l[1], l[2], l[3], l[4]
    else:
        lid, oid, oslot, tid, tslot = (l.get("id"), l.get("origin_id"), l.get("origin_slot"),
                                       l.get("target_id"), l.get("target_slot"))
    if str(oid) == inode:
        print(f"   Port {oslot} -> {byid.get(tid, tid)}({tid}).{tslot}  ({links_map.get(lid)})")

print()
print("=== Subgraph-Links (Quelle -> Ziel) ===")
links = sub.get("links") or []
byid = {n["id"]: n.get("type") for n in sub["nodes"]}
# Slot-Namen für die Port-Zuordnung
slotname = {}
for n in sub["nodes"]:
    for i, o in enumerate(n.get("outputs") or []):
        slotname[(n["id"], i)] = f"{n.get('type')}.{o.get('name')}"
    for i, inp in enumerate(n.get("inputs") or []):
        slotname[(n["id"], "in", i)] = inp.get("name")
links_map = {}
for l in links:
    if isinstance(l, list) and len(l) >= 6:
        links_map[l[0]] = f"{byid.get(l[1], l[1])}#{l[1]}[{slotname.get((l[1], l[2]), l[2])}]"
    elif isinstance(l, dict):
        links_map[l.get("id")] = f"{byid.get(l.get('origin_id'), l.get('origin_id'))}[{l.get('origin_slot')}]"
for l in links:
    if isinstance(l, list) and len(l) >= 5:
        lid, oid, oslot, tid, tslot = l[0], l[1], l[2], l[3], l[4]
    else:
        lid, oid, oslot, tid, tslot = (l.get("id"), l.get("origin_id"), l.get("origin_slot"),
                                       l.get("target_id"), l.get("target_slot"))
    print(f"  {byid.get(oid, oid)}({oid}).{oslot} -> {byid.get(tid, tid)}({tid}).{tslot}")
