#!/usr/bin/env python3
"""fal.ai-Queue überwachen: Status, Logs, Ergebnis (LoRA) abholen.

Key wird aus ~/.hermes/credentials/fal_api_key gelesen und niemals ausgegeben.

Aufruf:
  fal_status.py --endpoint fal-ai/qwen-image-2512-trainer --request-id <id> [--logs]
  fal_status.py ... --download ziel.zip
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

KEY_FILE = os.path.expanduser("~/.hermes/credentials/fal_api_key")
QUEUE = "https://queue.fal.run"


def key() -> str:
    with open(KEY_FILE) as fh:
        k = fh.read().strip()
    if not k:
        sys.exit("kein Key in " + KEY_FILE)
    return k


def api(url: str) -> dict:
    req = urllib.request.Request(url, headers={"Authorization": f"Key {key()}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="fal-ai/qwen-image-2512-trainer")
    ap.add_argument("--request-id", required=True)
    ap.add_argument("--logs", action="store_true")
    ap.add_argument("--result", action="store_true")
    ap.add_argument("--download", default="")
    a = ap.parse_args()

    base = f"{QUEUE}/{a.endpoint}/requests/{a.request_id}"
    st = api(base + "/status" + ("?logs=1" if a.logs else ""))
    print("STATUS:", st.get("status"))
    for k in ("queue_position", "started_at", "completed_at", "elapsed_seconds"):
        if st.get(k) is not None:
            print(f"  {k}: {st[k]}")
    if a.logs:
        for line in (st.get("logs") or [])[-25:]:
            print("  log:", line.get("message", "")[:200])
    if st.get("status") in ("COMPLETED",) or a.result:
        res = api(base)
        print("\nERGEBNIS:")
        print(json.dumps(res, indent=1)[:2000])
        if a.download:
            def walk(o):
                if isinstance(o, dict):
                    if "url" in o and isinstance(o["url"], str):
                        yield o
                    for v in o.values():
                        yield from walk(v)
                elif isinstance(o, list):
                    for v in o:
                        yield from walk(v)
            for f in walk(res):
                if f.get("url", "").endswith((".safetensors", ".zip")) or "lora" in str(f.get("file_name", "")).lower():
                    dst = a.download
                    if dst.endswith("/") or os.path.isdir(dst):
                        dst = os.path.join(dst, f.get("file_name") or "lora.safetensors")
                    print(f"\nlade {f.get('file_name')} ({f.get('file_size')} B) -> {dst}")
                    urllib.request.urlretrieve(f["url"], dst)
                    print("  fertig:", os.path.getsize(dst), "Bytes")
                    break


if __name__ == "__main__":
    main()
