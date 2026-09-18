#!/usr/bin/env python3
"""Prüft die bestehende Buffer-/MinIO-Anbindung (NUR LESEND — postet nichts).

1) Existenz der Credential-Dateien (Werte maskiert)
2) Buffer GraphQL: Organisation + verbundene Kanäle auflisten
3) MinIO: Schreibtest-Verzicht, nur Objektzählung im Bucket 'buffer'
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import requests

AUTH = Path(os.path.expanduser("~/.hermes/auth"))
BUF_TOKEN = AUTH / "buffer_token.json"
S3_CREDS = AUTH / "s3_credentials.json"
GRAPHQL = "https://api.buffer.com/graphql"
ORG = "69fdf62899d12587b2ba02fe"


def mask(v):
    s = str(v)
    return s[:4] + "***" + s[-2:] if len(s) > 8 else "***"


def check_creds() -> bool:
    print("=== Credential-Dateien ===")
    ok = True
    for p in (BUF_TOKEN, S3_CREDS):
        if p.exists():
            d = json.loads(p.read_text())
            keys = {k: (mask(v) if any(s in k.lower() for s in
                                      ("token", "key", "secret", "password")) else v)
                    for k, v in d.items()}
            print(f"✅ {p.name}: {json.dumps(keys, ensure_ascii=False)[:300]}")
        else:
            ok = False
            print(f"❌ {p} fehlt")
    if AUTH.exists():
        print("Inhalt ~/.hermes/auth/:", sorted(x.name for x in AUTH.iterdir())[:30])
    return ok


def buffer_channels() -> None:
    print("\n=== Buffer Kanäle (lesend) ===")
    if not BUF_TOKEN.exists():
        print("übersprungen (kein Token)")
        return
    token = json.loads(BUF_TOKEN.read_text())["access_token"]
    q = """
    query Ch($input: ChannelsInput!) {
      channels(input: $input) { id displayName service externalLink }
    }"""
    r = requests.post(GRAPHQL, headers={"Authorization": f"Bearer {token}",
                                       "Content-Type": "application/json"},
                      json={"query": q, "variables": {"input": {"organizationId": ORG}}},
                      timeout=45)
    print("HTTP", r.status_code)
    if r.status_code != 200:
        print(r.text[:400])
        return
    data = r.json()
    if "errors" in data:
        print("GraphQL-Fehler:", json.dumps(data["errors"], ensure_ascii=False)[:400])
        return
    for c in data.get("data", {}).get("channels", []) or []:
        print(f"  - {c.get('service'):10s} {c.get('displayName')}  id={c.get('id')}  {c.get('externalLink') or ''}")


def s3_probe() -> None:
    print("\n=== MinIO Bucket 'buffer' (lesend) ===")
    try:
        import boto3
        from botocore.config import Config
    except ImportError:
        print("boto3 fehlt")
        return
    if not S3_CREDS.exists():
        print("übersprungen (keine s3_credentials.json)")
        return
    c = json.loads(S3_CREDS.read_text())
    s3 = boto3.client("s3", endpoint_url=c["endpoint_url"],
                      aws_access_key_id=c["access_key"],
                      aws_secret_access_key=c["secret_key"],
                      region_name=c.get("region", "us-east-1"),
                      config=Config(signature_version="s3v4"))
    keys = s3.list_objects_v2(Bucket=c["bucket"]).get("Contents", [])
    print(f"Objekte im Bucket '{c['bucket']}': {len(keys)}")
    for o in keys[:8]:
        print(f"  - {o['Key']}  ({o['Size']/1e6:.1f} MB, {o['LastModified']:%Y-%m-%d})")


if __name__ == "__main__":
    creds_ok = check_creds()
    buffer_channels()
    s3_probe()
    print("\nZusammenfassung: Credential-Dateien vorhanden =", creds_ok)
    sys.exit(0)
