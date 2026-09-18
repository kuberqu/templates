#!/usr/bin/env python3
"""Authorization Code gegen YouTube-Tokens tauschen (einmalig!).

Der Code ist nur EINMAL verwendbar — dieses Skript prüft vorher die Voraussetzungen
und schreibt das Ergebnis nach ~/.hermes/auth/youtube_oauth.json (chmod 600).
Secrets werden nie ausgegeben.
"""
from __future__ import annotations

import json
import os
import shutil
import time
import urllib.error
import urllib.parse
import urllib.request

AUTH = os.path.expanduser("~/.hermes/auth/youtube_oauth.json")
SECRET = os.path.expanduser("~/.hermes/auth/youtube_client_secret.json")
CODE = "4/0ATsMZqDi4SOhdywBY41kC-wEgTUMiQCuhsXat8LHk3pGDGWCZwpqUtrovlUnLcXuBTxNrg"
REDIRECT = "http://localhost:8080"

cs = json.load(open(SECRET))["installed"]

# 1) Code einlösen
data = urllib.parse.urlencode({
    "client_id": cs["client_id"],
    "client_secret": cs["client_secret"],
    "code": CODE,
    "redirect_uri": REDIRECT,
    "grant_type": "authorization_code",
}).encode()
try:
    with urllib.request.urlopen(urllib.request.Request(
            cs.get("token_uri", "https://oauth2.googleapis.com/token"), data=data),
            timeout=60) as r:
        tok = json.loads(r.read().decode())
except urllib.error.HTTPError as e:
    print("TOKEN-TAUSCH FEHLGESCHLAGEN:", e.code)
    print(e.read().decode()[:400])
    raise SystemExit(1)

print("Code eingelöst. access_token:", len(tok.get("access_token", "")), "Zeichen")
print("refresh_token vorhanden:", bool(tok.get("refresh_token")))

# 2) Kanal abfragen
req = urllib.request.Request(
    "https://www.googleapis.com/youtube/v3/channels?part=snippet,statistics&mine=true",
    headers={"Authorization": f"Bearer {tok['access_token']}"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        ch = json.loads(r.read().decode())
    items = ch.get("items") or []
    if items:
        c = items[0]
        print("\n=== KANAL ===")
        print("  Name       :", c["snippet"].get("title"))
        print("  Kanal-ID   :", c.get("id"))
        print("  Handle     :", c["snippet"].get("customUrl"))
        print("  Videos     :", c.get("statistics", {}).get("videoCount"))
        print("  Abonnenten :", c.get("statistics", {}).get("subscriberCount"))
        email_hint = c["snippet"].get("title")
    else:
        print("\nWARNUNG: Token ohne Kanal (kein YouTube-Kanal am Konto?)")
except Exception as e:
    print("\nKanalabfrage fehlgeschlagen:", type(e).__name__, str(e)[:200])

# 3) Speichern (Backup der alten Datei)
if os.path.exists(AUTH):
    shutil.copyfile(AUTH, AUTH + f".bak_{time.strftime('%Y%m%d_%H%M')}")
out = {
    "access_token": tok["access_token"],
    "refresh_token": tok.get("refresh_token"),
    "client_id": cs["client_id"],
    "client_secret": cs["client_secret"],
    "project_id": cs.get("project_id"),
    "email": "oliver.2.moeller@gmail.com",
    "scopes": tok.get("scope", ""),
    "token_uri": cs.get("token_uri", "https://oauth2.googleapis.com/token"),
    "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()),
}
with open(AUTH, "w") as f:
    json.dump(out, f, indent=2)
os.chmod(AUTH, 0o600)
print("\ngespeichert:", AUTH, "(chmod 600)")
print("Scopes:", out["scopes"])
