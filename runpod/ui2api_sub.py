#!/usr/bin/env python3
"""UI-Template (inkl. Subgraphen) -> API-Prompt für ComfyUI.

Warum: Die offiziellen Templates stecken ihre Logik in Subgraphen
(UUID-Nodes mit `definitions.subgraphs`). Selbst gebaute Workflows weichen
dann in Details ab, die man nicht errät (Beispiel LTX-2.5: CFG 1.0/1.0 statt
3/7 — sonst ist die Tonspur stumm).

Aufruf:
  ui2api_sub.py <template.json> [--out prompt.json] [--dump] [--set k=v ...]

--set erlaubt das Überschreiben von Widget-Werten per Pfad:
  --set 76.text="..."   (Node-ID im Haupt-/Subgraph, Widgetname)
"""
from __future__ import annotations

import argparse
import json
import urllib.request

API = "http://127.0.0.1:8188"
WIDGET_TYPES = {"INT", "FLOAT", "STRING", "BOOLEAN", "COMBO", "COMBO_MULTISELECT",
                "COMFY_DYNAMICCOMBO_V3"}


def obj_info() -> dict:
    with urllib.request.urlopen(API + "/object_info", timeout=30) as r:
        return json.loads(r.read().decode())


def widget_specs(ni: dict) -> list[str]:
    spec = ni.get("input", {})
    names = []
    for group in ("required", "optional"):
        for name, val in spec.get(group, {}).items():
            t = val[0]
            if isinstance(t, list) or (isinstance(t, str) and t.upper() in WIDGET_TYPES):
                names.append(name)
    return names


def norm_links(raw: list) -> dict:
    out = {}
    for l in raw or []:
        if isinstance(l, list) and len(l) >= 5:
            out[l[0]] = {"id": l[0], "from": l[1], "fslot": l[2], "to": l[3], "tslot": l[4]}
        elif isinstance(l, dict):
            out[l.get("id")] = {"id": l.get("id"), "from": l.get("origin_id"),
                                "fslot": l.get("origin_slot"), "to": l.get("target_id"),
                                "tslot": l.get("target_slot")}
    return out


def convert_graph(nodes: list, raw_links: list, info: dict, port_map: dict | None,
                  notes: list, prefix: str = "") -> tuple[dict, dict]:
    """Konvertiert einen (Teil-)Graphen. port_map: {(node_id, slot) -> Wert|Ref}
    für Subgraph-Ports. Liefert (prompt, out_ports) mit out_ports:
    {slot: [node_id, slot]} für den outputNode."""
    links = norm_links(raw_links)
    byid = {n["id"]: n for n in nodes}
    prompt, out_ports = {}, {}

    for n in nodes:
        nid = n.get("id")
        ct = n.get("type", "")
        # Subgraph-Port-Nodes auflösen
        if ct is None and str(nid) == "-10":
            for i, o in enumerate(n.get("outputs") or []):
                for lid in (o.get("links") or []):
                    if lid in links and port_map and (port_map.get(i) is not None):
                        links[lid]["_override"] = port_map[i]
            continue
        if ct is None and str(nid) == "-20":
            for i, inp in enumerate(n.get("inputs") or []):
                lid = inp.get("link")
                if lid in links:
                    l = links[lid]
                    out_ports[i] = [str(l["from"]), l["fslot"]]
            continue

        ni = info.get(ct)
        if ni is None:
            if ct not in ("MarkdownNote", "Note"):
                notes.append(f"{prefix}Node {nid} ({ct}) nicht in object_info — übersprungen")
            continue
        if n.get("mode") in (2, 4):
            notes.append(f"{prefix}Node {nid} ({ct}) mode={n.get('mode')} — übersprungen")
            continue

        inputs: dict = {}
        for i in (n.get("inputs") or []):
            lid = i.get("link")
            if lid is not None and lid in links:
                l = links[lid]
                if "_override" in l:
                    ov = l["_override"]
                    if isinstance(ov, list):     # externer Link
                        inputs[i["name"]] = ov
                    else:
                        inputs[i["name"]] = ov
                else:
                    key = (l["from"], l["fslot"])
                    inputs[i["name"]] = [str(l["from"]), l["fslot"]]
        wnames = widget_specs(ni)
        wv = list(n.get("widgets_values") or [])
        # ComfyUI schreibt Widget-Werte POSITIONELL, auch wenn der Eingang per
        # Link kommt (der Link gewinnt beim Ausfuehren, der Wert bleibt stehen).
        # Passen die Laengen zusammen -> positionell zuordnen, sonst nur freie.
        if len(wv) == len(wnames):
            for name, val in zip(wnames, wv):
                if isinstance(val, dict) and "value" in val:
                    val = val["value"]
                inputs.setdefault(name, val)
        else:
            wi = 0
            for name in wnames:
                if name in inputs:
                    continue
                if wi < len(wv):
                    val = wv[wi]
                    if isinstance(val, dict) and "value" in val:
                        val = val["value"]
                    inputs[name] = val
                    wi += 1
            if wi < len(wv):
                notes.append(f"{prefix}Node {nid} ({ct}): Rest-Widgets {wv[wi:]!r} "
                             f"(Widgets {len(wv)} vs. Specs {len(wnames)})")
        prompt[str(nid)] = {"class_type": ct, "inputs": inputs,
                            "_meta": {"title": n.get("title") or ct}}
    return prompt, out_ports


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("template")
    ap.add_argument("--out")
    ap.add_argument("--dump", action="store_true")
    ap.add_argument("--set", action="append", default=[])
    a = ap.parse_args()

    tpl = json.load(open(a.template))
    info = obj_info()
    notes: list = []
    subs = {s["id"]: s for s in (tpl.get("definitions") or {}).get("subgraphs", [])}
    prompt: dict = {}

    overrides: dict = {}
    for s in a.set:
        k, _, v = s.partition("=")
        overrides[k.strip()] = v.strip().strip('"')

    used_subs = []
    for n in tpl.get("nodes", []):
        stype = n.get("type")
        if stype in subs:
            sub = subs[stype]
            # Werte der Instanz-Inputs: Reihenfolge folgt sub["inputs"]
            inst_widgets = list(n.get("widgets_values") or [])
            port_map: dict = {}
            wnames = [p.get("name") for p in (sub.get("inputs") or [])]
            # Widget-Position: nur Inputs ohne "link" belegen Widgets
            wi = 0
            for i, port in enumerate(sub.get("inputs") or []):
                inst_in = (n.get("inputs") or [])[i] if i < len(n.get("inputs") or []) else {}
                if inst_in.get("link") is not None:
                    port_map[i] = None      # kommt von außen (selten)
                    continue
                val = None
                if wi < len(inst_widgets):
                    val = inst_widgets[wi]
                    if isinstance(val, dict) and "value" in val:
                        val = val["value"]
                    wi += 1
                if port.get("name") in overrides:
                    val = overrides[port["name"]]
                if port.get("label") in overrides:
                    val = overrides[port["label"]]
                port_map[i] = val
            inner, out_ports = convert_graph(sub["nodes"], sub.get("links"), info,
                                             port_map, notes, prefix=f"[sub {sub.get('name')}] ")
            prompt.update(inner)
            used_subs.append((n, sub, out_ports, port_map, inner))
        else:
            one, _ = convert_graph([n], tpl.get("links"), info, None, notes)
            prompt.update(one)

    # globale Links: Ziele, die auf eine Subgraph-Instanz zeigen, ersetzen
    inst_ids = {str(n["id"]): (out_ports) for n, sub, out_ports, _, _ in used_subs}
    links = norm_links(tpl.get("links"))
    # Output-Links der Instanz -> inneren Node umbiegen
    for n, sub, out_ports, _, _ in used_subs:
        for oi, o in enumerate(n.get("outputs") or []):
            for lid in (o.get("links") or []):
                l = links.get(lid)
                if not l:
                    continue
                tgt = str(l["to"])
                if tgt in prompt:
                    src = out_ports.get(oi)
                    if src:
                        # Ziel-Input finden und umschreiben
                        for iname, iv in list(prompt[tgt]["inputs"].items()):
                            if isinstance(iv, list) and iv == [str(n["id"]), oi]:
                                prompt[tgt]["inputs"][iname] = src

    # Links zwischen Hauptgraph-Nodes, die auf Instanzen zeigen, korrigieren
    for l in links.values():
        t = str(l["to"])
        f = str(l["from"])
        if t in inst_ids and t not in prompt:
            pass
        if f in inst_ids and t in prompt:
            src = inst_ids[f].get(l["fslot"])
            if src:
                for iname, iv in list(prompt[t]["inputs"].items()):
                    if isinstance(iv, list) and iv == [f, l["fslot"]]:
                        prompt[t]["inputs"][iname] = src

    print(f"API-Nodes: {len(prompt)} (Subgraphen aufgelöst: {len(used_subs)})")
    for nt in notes:
        print("  HINWEIS:", nt)
    if a.dump:
        for nid in sorted(prompt, key=lambda x: int(x) if x.lstrip("-").isdigit() else 0):
            nd = prompt[nid]
            simp = {k: (v if not isinstance(v, str) or len(v) < 70 else v[:67] + "…")
                    for k, v in nd["inputs"].items()}
            print(f"  [{nid:>4}] {nd['class_type']:<28} {simp}")
    if a.out:
        json.dump(prompt, open(a.out, "w"), indent=1)
        print("geschrieben:", a.out)


if __name__ == "__main__":
    main()
