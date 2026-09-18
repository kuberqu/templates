#!/usr/bin/env python3
"""Scannt die n8n-Workflows nach MinIO-/S3-/Buffer-Bezug (nur lesend).

Secrets werden NIE ausgegeben: gefundene Schlüssel/Werte werden maskiert.
"""
import json
import re
import subprocess
import sys
import urllib.request

N8N = "https://n8n.i.qtx.de"
CRED = "/home/claw/.Hermes/credentials/n8n.json"
KEYS = ("key", "secret", "password", "token", "apikey", "api_key", "access")


def api_key() -> str:
    with open(CRED) as f:
        return json.load(f)["api_key"]


def get(path: str, key: str):
    req = urllib.request.Request(N8N + path, headers={"X-N8N-API-KEY": key,
                                                     "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def mask(value: str) -> str:
    if not isinstance(value, str):
        return str(value)
    if len(value) <= 6:
        return "***"
    return value[:3] + "***" + value[-2:]


def walk(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(v, str) and any(s in k.lower() for s in KEYS) and len(v) > 8:
                yield path + "/" + k, mask(v)
            yield from walk(v, path + "/" + k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, "%s[%d]" % (path, i))


def main() -> int:
    key = api_key()
    print("n8n-Key geladen (maskiert):", mask(key))
    try:
        data = get("/api/v1/workflows?limit=250", key)
    except Exception as exc:
        print("FEHLER beim Abruf:", exc)
        return 1
    wfs = data.get("data", data if isinstance(data, list) else [])
    print("Workflows:", len(wfs))
    pattern = re.compile(r"minio|s3|buffer|qtx|bucket|storage", re.I)
    hits = 0
    for wf in wfs:
        blob = json.dumps(wf, ensure_ascii=False)
        if not pattern.search(blob):
            continue
        hits += 1
        print("\n=== %s (id=%s, active=%s) ===" % (wf.get("name"), wf.get("id"), wf.get("active")))
        for node in wf.get("nodes", []):
            nb = json.dumps(node, ensure_ascii=False)
            if pattern.search(nb):
                print("  - Node: %s | type=%s" % (node.get("name"), node.get("type")))
                params = node.get("parameters", {})
                for field in ("url", "path", "bucketName", "bucket", "fileName", "endpoint"):
                    if field in json.dumps(params):
                        m = re.search(r'"%s"\s*:\s*"([^"]{0,120})' % field, json.dumps(params))
                        if m:
                            print("      %s = %s" % (field, m.group(1)[:120]))
                for p, v in walk(params):
                    if v != "***":
                        print("      %s = %s" % (p, v))
                creds = node.get("credentials")
                if creds:
                    print("      credentials: %s" % json.dumps({k: {"id": c.get("id"), "name": c.get("name")}
                                                                for k, c in creds.items()}, ensure_ascii=False))
    print("\nWorkflows mit Treffer:", hits)
    return 0


if __name__ == "__main__":
    sys.exit(main())
