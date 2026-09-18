#!/usr/bin/env python3
"""Hummer-Short auf TikTok veröffentlichen (Kette MinIO -> Buffer).

Nutzt die vorhandene Referenz-Implementierung
(`~/workspace/podcast-clipper/pipeline/tiktok_upload.py`) — kein Nachbau.

Zwei Modi:
  --check    nur lesend prüfen (Token gültig? S3-Creds? Queue-Stand?) und nichts posten
  --publish  S3-Upload + Buffer-createPost (mode shareNow)

Credential-Handling: die Werte werden intern geladen, nie ausgegeben.

Aufruf: tiktok_publish.py --check | --publish
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, "/home/claw/workspace/podcast-clipper")
from pipeline.tiktok_upload import (  # noqa: E402
    _load_s3_creds, _load_token, _get_s3_client, get_tiktok_channel,
    get_queue_count, upload_video,
)

PROJ = Path("/home/claw/workspace/runpod-lipsync/shorts/hummer_lobster")
VIDEO = PROJ / "short_final_infinitetalk.mp4"

CAPTION = ("Dieser Hummer knurrt – aber nicht mit dem Maul 🦞\n\n"
           "Er erzeugt die Vibrationen mit der Magenmühle tief im Körper: 80–250 Hz, "
           "die Raubfische abschrecken.\n\n"
           "#Hummer #Wissen #Meeresbiologie #LernOnTikTok #shorts")


def mask(v: str) -> str:
    return (v[:4] + "***") if v else "(leer)"


def check() -> dict:
    print("1) Buffer-Token        : ", end="")
    tok = _load_token()
    print("geladen", mask(tok))
    ch = get_tiktok_channel(tok)
    print(f"2) TikTok-Kanal        : {ch.get('displayName')} ({ch['id']}) "
          f"| link: {ch.get('externalLink')}")
    q = get_queue_count(ch["id"], tok)
    print(f"3) Buffer-Queue        : {q}/10 belegt (Free-Plan-Limit)")
    creds = _load_s3_creds()
    print(f"4) S3-Ziel             : {creds['endpoint_url']} / Bucket '{creds['bucket']}' "
          f"| key {mask(creds['access_key'])}")
    s3 = _get_s3_client()
    r = s3.list_objects_v2(Bucket=creds["bucket"], MaxKeys=5)
    n = r.get("KeyCount", 0)
    print(f"5) S3-Zugriff          : OK, {n} Objekte gelesen "
          f"(Beispiele: {[o['Key'] for o in r.get('Contents', [])][:3]})")
    if not VIDEO.exists():
        raise SystemExit(f"Video fehlt: {VIDEO}")
    print(f"6) Video               : {VIDEO.name} ({VIDEO.stat().st_size/1e6:.1f} MB)")
    return {"channel_id": ch["id"], "queue": q, "token": tok}


def main() -> None:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--publish", action="store_true")
    a = ap.parse_args()

    info = check()
    if a.check:
        print("\nNur Prüfung — nichts veröffentlicht.")
        return

    print("\n--- CAPTION ---")
    print(CAPTION)
    print("\n--- veröffentlichen ---")
    obj = f"prickle_hummer_knurren_{VIDEO.stat().st_size // 1000}kb.mp4"
    res = upload_video(str(VIDEO), CAPTION, channel_id=info["channel_id"],
                       token=info["token"], s3_object_name=obj)
    print("\nERGEBNIS: " + json.dumps(res, ensure_ascii=False, indent=1)[:1200])
    out = PROJ / "tiktok_info.json"
    out.write_text(json.dumps({"result": res, "caption": CAPTION, "s3_object": obj,
                               "file": str(VIDEO)}, ensure_ascii=False, indent=1))
    print(f"gespeichert: {out}")


if __name__ == "__main__":
    main()
