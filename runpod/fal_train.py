#!/usr/bin/env python3
"""LoRA-Training bei fal.ai starten (Dataset hochladen + Queue-Request).

Ablauf:
  1. ZIP in den fal-Storage hochladen (initiate -> PUT -> file_url)
  2. Trainings-Request in die Queue legen
  3. request_id ausgeben (Status danach mit fal_status.py)

Der API-Key kommt aus ~/.hermes/credentials/fal_api_key und wird NICHT ausgegeben.

Aufruf:
  fal_train.py --zip weiblich_lora_dataset.zip --endpoint fal-ai/qwen-image-2512-trainer \
               [--steps 1000] [--lr 0.0005] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

KEY_FILE = os.path.expanduser("~/.hermes/credentials/fal_api_key")
UPLOAD_INIT = "https://rest.alpha.fal.ai/storage/upload/initiate"
QUEUE = "https://queue.fal.run"


def key() -> str:
    with open(KEY_FILE) as fh:
        k = fh.read().strip()
    if not k:
        sys.exit("kein Key in " + KEY_FILE)
    return k


def post_json(url: str, payload: dict, k: str) -> dict:
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Authorization": f"Key {k}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode())


def upload(path: str, k: str) -> str:
    """ZIP hochladen, oeffentliche file_url zurueckgeben."""
    size = os.path.getsize(path)
    name = os.path.basename(path)
    print(f"[upload] {name} ({size/1e6:.1f} MB)")
    init = post_json(f"{UPLOAD_INIT}?storage_type=fal-cdn-v3",
                     {"content_type": "application/zip", "file_name": name}, k)
    up, file_url = init.get("upload_url"), init.get("file_url")
    if not up or not file_url:
        sys.exit(f"[upload] unerwartete Antwort: {json.dumps(init)[:300]}")
    with open(path, "rb") as fh:
        req = urllib.request.Request(up, data=fh.read(), method="PUT",
                                     headers={"Content-Type": "application/zip"})
        with urllib.request.urlopen(req, timeout=600) as r:
            print(f"[upload] PUT -> HTTP {r.status}")
    print(f"[upload] file_url: {file_url}")
    return file_url


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", default="weiblich_lora_dataset.zip")
    ap.add_argument("--endpoint", default="fal-ai/qwen-image-2512-trainer")
    ap.add_argument("--steps", type=int, default=1000)
    ap.add_argument("--lr", type=float, default=0.0005)
    ap.add_argument("--caption", default="")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    k = key()
    url = upload(a.zip, k)
    payload = {"image_data_url": url, "steps": a.steps, "learning_rate": a.lr}
    if a.caption:
        payload["default_caption"] = a.caption
    print("[request] " + json.dumps({**payload, "image_data_url": "<uploaded-zip>"}, indent=1))
    if a.dry_run:
        print("[dry-run] kein Request gesendet"); return

    try:
        res = post_json(f"{QUEUE}/{a.endpoint}", payload, k)
    except urllib.error.HTTPError as e:
        sys.exit(f"[request] FEHLER {e.code}: {e.read().decode()[:600]}")
    print("[request] Antwort: " + json.dumps(res, indent=1)[:800])
    rid = res.get("request_id")
    if not rid:
        sys.exit("[request] keine request_id erhalten")
    print(f"\nREQUEST_ID={rid}")
    print(f"STATUS: python3 fal_status.py --endpoint {a.endpoint} --request-id {rid} --logs")


if __name__ == "__main__":
    main()
