#!/usr/bin/env python3
"""Prüft die YouTube-Auth: Refresh-Token einlösen + Kanal abfragen.
Gibt NIE Secrets aus, nur Kanalname/ID/Status."""
from __future__ import annotations

import json
import urllib.parse
import urllib.request

AUTH = "/home/claw/.hermes/auth/youtube_oauth.json"
d = json.load(open(AUTH))
print("Konto laut Auth:", d.get("email"))
print("Scopes:", d.get("scopes"))

# 1) Refresh
data = urllib.parse.urlencode({
    "client_id": d["client_id"],
    "client_secret": d["client_secret"],
    "refresh_token": d["refresh_token"],
    "grant_type": "refresh_token",
}).encode()
try:
    with urllib.request.urlopen(urllib.request.Request(
            d.get("token_uri", "https://oauth2.googleapis.com/token"), data=data), timeout=30) as r:
        tok = json.loads(r.read().decode())
    at = tok["access_token"]
    print(f"\nRefresh OK - neuer access_token ({len(at)} Zeichen), gültig {tok.get('expires_in')}s")
except Exception as e:
    print("\nRefresh FEHLGESCHLAGEN:", type(e).__name__, str(e)[:200])
    raise SystemExit(1)

# 2) Kanal abfragen
req = urllib.request.Request(
    "https://www.googleapis.com/youtube/v3/channels?part=snippet,statistics,contentDetails&mine=true",
    headers={"Authorization": f"Bearer {at}"})
with urllib.request.urlopen(req, timeout=30) as r:
    ch = json.loads(r.read().decode())
if not ch.get("items"):
    print("Kein Kanal gefunden (Token ohne Kanal?)")
    raise SystemExit(2)
c = ch["items"][0]
sn, st = c["snippet"], c.get("statistics", {})
print("\n=== KANAL ===")
print("  Name        :", sn.get("title"))
print("  Kanal-ID    :", c.get("id"))
print("  Handle      :", sn.get("customUrl"))
print("  Land        :", sn.get("country"))
print("  Abonnenten  :", st.get("subscriberCount"))
print("  Videos      :", st.get("videoCount"))
print("  Uploads-Liste:", c.get("contentDetails", {}).get("relatedPlaylists", {}).get("uploads"))
