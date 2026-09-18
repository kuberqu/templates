#!/usr/bin/env python3
"""Konvertiert ein ComfyUI-UI-Template (nodes/links) in einen API-Prompt.

Aufruf: ui2api.py <template.json> [--out prompt.json] [--dump]
"""
from __future__ import annotations

import argparse
import json
import urllib.request

API = "http://127.0.0.1:8188"
WIDGET_TYPES = {"INT", "FLOAT", "STRING", "BOOLEAN", "COMBO", "COMBO_MULTISELECT"}


def obj_info() -> dict:
    with urllib.request.urlopen(API + "/object_info", timeout=30) as r:
        return json.loads(r.read().decode())


def widget_specs(node_info: dict) -> list[str]:
    """Namen der Widget-Inputs in Anzeige-Reihenfolge."""
    spec = node_info.get("input", {})
    names = []
    for group in ("required", "optional"):
        for name, val in spec.get(group, {}).items():
            t = val[0]
            if isinstance(t, list):
                names.append(name)          # COMBO
            elif isinstance(t, str) and t.upper() in WIDGET_TYPES:
                names.append(name)
    return names


def convert(tpl: dict, info: dict) -> tuple[dict, list[str]]:
    links = {}
    for l in tpl.get("links") or []:
        if isinstance(l, list) and len(l) >= 5:
            links[l[0]] = {"from": l[1], "from_slot": l[2], "to": l[3], "to_slot": l[4]}
        elif isinstance(l, dict):
            links[l.get("id")] = {"from": l.get("origin_id"), "from_slot": l.get("origin_slot"),
                                  "to": l.get("target_id"), "to_slot": l.get("target_slot")}
    byid = {n["id"]: n for n in tpl.get("nodes", [])}
    prompt, notes = {}, []

    for n in tpl.get("nodes", []):
        nid = str(n["id"])
        ct = n.get("type", "")
        ni = info.get(ct)
        if ni is None:
            notes.append(f"Node {nid} ({ct}) nicht in object_info — übersprungen")
            continue
        if n.get("mode") in (2, 4):     # muted / bypassed
            notes.append(f"Node {nid} ({ct}) mode={n.get('mode')} — übersprungen")
            continue

        inputs: dict = {}
        # 1) verlinkte Eingänge
        linked_names = set()
        for i in (n.get("inputs") or []):
            lid = i.get("link")
            if lid is not None and lid in links:
                l = links[lid]
                inputs[i["name"]] = [str(l["from"]), l["from_slot"]]
                linked_names.add(i["name"])
        # 2) Widget-Werte der Reihe nach
        wnames = widget_specs(ni)
        wv = list(n.get("widgets_values") or [])
        wi = 0
        for name in wnames:
            if name in inputs or name in linked_names:
                continue
            if wi < len(wv):
                inputs[name] = wv[wi]
                wi += 1
        if wi < len(wv):
            notes.append(f"Node {nid} ({ct}): {len(wv)-wi} Widget-Werte ohne Zuordnung "
                         f"({wv[wi:]!r}) — prüfen!")
        prompt[nid] = {"class_type": ct, "inputs": inputs,
                       "_meta": {"title": (n.get("title") or ct)}}
    return prompt, notes


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("template")
    ap.add_argument("--out")
    ap.add_argument("--dump", action="store_true")
    a = ap.parse_args()

    tpl = json.load(open(a.template))
    if "nodes" not in tpl:
        print("Kein UI-Template (kein 'nodes'-Key)")
        raise SystemExit(1)
    prompt, notes = convert(tpl, obj_info())
    print(f"Konvertiert: {len(tpl.get('nodes', []))} UI-Nodes -> {len(prompt)} API-Nodes")
    for nt in notes:
        print("  HINWEIS:", nt)
    if a.dump:
        for nid in sorted(prompt, key=lambda x: int(x) if x.isdigit() else 0):
            nd = prompt[nid]
            simp = {k: (v if not isinstance(v, str) or len(v) < 60 else v[:57] + "…")
                    for k, v in nd["inputs"].items()}
            print(f"  [{nid:>4}] {nd['class_type']:<26} {simp}")
    if a.out:
        json.dump(prompt, open(a.out, "w"), indent=1)
        print("geschrieben:", a.out)


if __name__ == "__main__":
    main()
