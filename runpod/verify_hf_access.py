#!/usr/bin/env python3
"""Prüft HF-Token-Zugriff und listet die echten Dateinamen/Größen der Ziel-Repos.

Zweck: Statt Dateinamen zu raten, werden die exakten Namen + Größen abgefragt —
die Setup-Liste wird daraus gebaut. Nur lesend.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from huggingface_hub import HfApi

TOKEN_FILE = Path("/workspace/.hf_token")
REPOS = [
    "Lightricks/LTX-2.5",                       # gated, Video+Audio
    "Comfy-Org/LTX-2.5_ComfyUI_repackaged",     # falls vorhanden: ComfyUI-Layout
    "Comfy-Org/Qwen-Image_ComfyUI",             # Qwen-Image (Apache-2.0)
    "Comfy-Org/Qwen-Image-Edit_ComfyUI",        # Qwen-Image-Edit (Charakter-Konsistenz)
    "Tongyi-MAI/Z-Image-Turbo",                 # Z-Image Turbo (Apache-2.0)
    "Comfy-Org/z_image_turbo_ComfyUI_repackaged",
    "black-forest-labs/FLUX.2-klein",           # Apache-2.0, klein
]


def main() -> int:
    token = TOKEN_FILE.read_text().strip() if TOKEN_FILE.exists() else None
    if not token:
        print("kein Token gefunden")
        return 1
    api = HfApi(token=token)
    try:
        who = api.whoami()
        print("Token gehört zu:", who.get("name"), "| Typ:", who.get("type"))
        auth = who.get("auth", {})
        if auth.get("accessToken"):
            print("  Token-Rolle:", auth["accessToken"].get("role"))
    except Exception as exc:
        print("whoami fehlgeschlagen:", exc)
        return 1

    for repo in REPOS:
        print("\n" + "=" * 60)
        print("REPO:", repo)
        try:
            info = api.model_info(repo, files_metadata=True)
        except Exception as exc:
            print("  nicht verfügbar:", str(exc)[:160])
            continue
        files = sorted((f.rfilename, f.size or 0) for f in (info.siblings or []))
        big = [(n, s) for n, s in files if s > 50_000_000]
        small = [(n, s) for n, s in files if s <= 50_000_000]
        total = sum(s for _, s in files) / 1e9
        print(f"  Dateien: {len(files)} | Gesamt: {total:.1f} GB | gated: {info.gated}")
        for n, s in big:
            print(f"  {s/1e9:6.2f} GB  {n}")
        for n, s in small[:12]:
            print(f"  {s/1e6:6.1f} MB  {n}")
        if len(small) > 12:
            print(f"  … {len(small)-12} weitere kleine Dateien")
    return 0


if __name__ == "__main__":
    sys.exit(main())
