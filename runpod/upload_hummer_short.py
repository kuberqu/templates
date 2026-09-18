#!/usr/bin/env python3
"""Hummer-Short auf YouTube hochladen (Kanal 'The Prickle').

Nutzt das bestehende Modul aus der YouTube-Tops-Pipeline
(`/home/claw/workspace/youtube-tops/pipeline/youtube_upload.py`), das den
Refresh-Token aus ~/.hermes/auth/youtube_oauth.json verwendet.

Titel/Quellen kommen aus dem Projekt (`script_v2.json`), damit Video und
Beschreibung denselben Stand haben.

Aufruf: upload_hummer_short.py [--privacy public|unlisted|private] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, "/home/claw/workspace/youtube-tops")
from pipeline.youtube_upload import upload_video  # noqa: E402

PROJ = Path("/home/claw/workspace/runpod-lipsync/shorts/hummer_lobster")
VIDEO = PROJ / "short_final_infinitetalk.mp4"

TITLE = "Hummer knurren – aber nicht mit dem Maul 🦞"

DESCRIPTION = """Dieser Hummer knurrt – aber nicht mit dem Maul.

Tief in seinem Verdauungstrakt sitzt die Magenmühle: drei Mahlzähne aus Chitin und \
Calciumcarbonat, die die Nahrung zerreiben. Eine Studie von 2025 hat gemessen, dass \
Homarus gammarus dabei Vibrationen von 80–250 Hz im Panzer erzeugt – Frequenzen, die \
Raubfische abschrecken.

Belegt ist außerdem: Stummgeschaltete Langusten werden häufiger angegriffen. Der Ton \
hat also eine Funktion, auch wenn die genaue Schallquelle (Magenmühle oder \
Carapax-Vibration) noch diskutiert wird.

Quellen:
• arXiv 2511.16848 (2025) – Carapax-Vibrationen bei Homarus gammarus, 80–250 Hz
• Patek 2001/2002 (Nature, Journal of Experimental Biology) – Stridulation der Langusten
• Bouwma & Herrnkind 2004/2007 – stummgeschaltete Tiere werden häufiger attackiert"""

HASHTAGS = ["#Shorts", "#Hummer", "#Meeresbiologie", "#Wissen", "#Natur"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--privacy", default="public", choices=["public", "unlisted", "private"])
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if not VIDEO.exists():
        sys.exit(f"Video fehlt: {VIDEO}")
    size_mb = VIDEO.stat().st_size / 1e6
    print(f"Video : {VIDEO}  ({size_mb:.1f} MB)")
    print(f"Titel : {TITLE}")
    print(f"Sichtbarkeit: {a.privacy}")
    print(f"Hashtags: {' '.join(HASHTAGS)}")
    if a.dry_run:
        print("\n--- Beschreibung ---")
        print(DESCRIPTION)
        return

    vid = upload_video(str(VIDEO), TITLE, DESCRIPTION,
                       hashtags=HASHTAGS, privacy=a.privacy)
    print(f"VIDEO_ID={vid}")
    print(f"URL=https://youtube.com/watch?v={vid}")
    out = PROJ / "upload_info.json"
    out.write_text(json.dumps({"video_id": vid, "title": TITLE, "privacy": a.privacy,
                               "file": str(VIDEO), "size_bytes": VIDEO.stat().st_size,
                               "hashtags": HASHTAGS, "description": DESCRIPTION},
                              ensure_ascii=False, indent=1))
    print(f"Metadaten gespeichert: {out}")


if __name__ == "__main__":
    main()
