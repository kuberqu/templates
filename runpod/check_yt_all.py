#!/usr/bin/env python3
"""Testet alle YouTube-/Google-Auths: genauer Fehlertext (ohne Secrets)."""
import json, glob, urllib.parse, urllib.request, os

CAND = ["youtube_oauth.json", "youtube_oauth.json.bak_upload_good",
        "youtube_oauth.json.bak3", "youtube_oauth.json.bak2",
        "youtube_oauth.json.bak", "youtube_oauth_science_avatar.json",
        "google_oauth.json"]
BASE = "/home/claw/.hermes/auth"

for name in CAND:
    p = os.path.join(BASE, name)
    if not os.path.exists(p):
        print(f"{name}: fehlt"); continue
    d = json.load(open(p))
    # google_oauth.json hat andere Feldnamen
    cid = d.get("client_id")
    csec = d.get("client_secret")
    rt = d.get("refresh_token") or d.get("refresh")
    if not (cid and csec and rt):
        print(f"{name}: unvollstaendig (kein client_id/secret/refresh_token) — Felder: {sorted(d)}")
        continue
    data = urllib.parse.urlencode({"client_id": cid, "client_secret": csec,
                                   "refresh_token": rt,
                                   "grant_type": "refresh_token"}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(
                "https://oauth2.googleapis.com/token", data=data), timeout=30) as r:
            tok = json.loads(r.read().decode())
        print(f"{name}: REFRESH OK (access_token {len(tok['access_token'])} Zeichen)")
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:200]
        print(f"{name}: HTTP {e.code} -> {body}")
    except Exception as e:
        print(f"{name}: {type(e).__name__} {str(e)[:120]}")
