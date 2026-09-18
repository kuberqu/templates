#!/usr/bin/env python3
"""Sucht lokal nach qtx-/MinIO-Konfiguration und testet Bucket-Erreichbarkeit.

1) Textdateien im Home nach 'qtx' durchsuchen (begrenzte, gezielte Pfade)
2) Erreichbarkeit von n8n.i.qtx.de prüfen (DNS + HTTPS-HEAD, IPv4 erzwungen)
3) gängige Bucket-Namen auf https://s3.o.qtx.de/ testen:
   HTTP 403 = Bucket existiert (kein Zugriff), 404 = existiert nicht, 200 = öffentlich
"""
from __future__ import annotations

import socket
import subprocess
import sys
from pathlib import Path

HOME = Path("/home/claw")
SEARCH_DIRS = [HOME / ".Hermes", HOME / ".config", HOME / ".mc", HOME / ".aws",
               HOME / "workspace", HOME / "hermes_projects", HOME / "tools"]
SKIP = ("node_modules", "__pycache__", "backup", ".git", "output", "clips", "logs")
TEXT_EXT = {".py", ".json", ".yaml", ".yml", ".env", ".sh", ".md", ".txt", ".ini",
            ".conf", ".cfg", ".toml"}
BUCKETS = ["buffer", "media", "videos", "video", "uploads", "assets", "brainrot",
           "output", "public", "files", "data", "clips", "social", "n8n"]
BASE = "https://s3.o.qtx.de"


def file_hits() -> None:
    print("=== Textdateien mit 'qtx' (max 15) ===")
    hits = 0
    for d in SEARCH_DIRS:
        if not d.exists():
            continue
        for p in d.rglob("*"):
            if hits >= 15:
                return
            if not p.is_file() or p.suffix.lower() not in TEXT_EXT:
                continue
            if any(s in p.parts for s in SKIP):
                continue
            if p.stat().st_size > 2_000_000:
                continue
            try:
                txt = p.read_text(errors="ignore")
            except OSError:
                continue
            if "qtx" in txt.lower():
                hits += 1
                lines = [l.strip()[:160] for l in txt.splitlines() if "qtx" in l.lower()][:3]
                print(f"- {p}")
                for l in lines:
                    print(f"    {l}")
    if hits == 0:
        print("(keine Treffer)")


def dns_and_http() -> None:
    print("\n=== n8n.i.qtx.de ===")
    try:
        print("DNS:", socket.gethostbyname_ex("n8n.i.qtx.de")[2])
    except Exception as exc:
        print("DNS-Fehler:", exc)
    out = subprocess.run(["curl", "-4", "-s", "-o", "/dev/null", "-w",
                          "http=%{http_code} time=%{time_total}s",
                          "--max-time", "20", "https://n8n.i.qtx.de/"],
                         capture_output=True, text=True)
    print("curl:", out.stdout or out.stderr.strip()[:120])


def bucket_probe() -> None:
    print("\n=== Bucket-Probe auf s3.o.qtx.de ===")
    for b in BUCKETS:
        out = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                              "--max-time", "12", f"{BASE}/{b}"],
                             capture_output=True, text=True)
        code = out.stdout.strip()
        verdict = {"200": "ÖFFENTLICH lesbar", "403": "existiert (kein Zugriff)",
                   "404": "existiert nicht", "400": "?"}.get(code, "?")
        print(f"  {b:12s} -> HTTP {code}  {verdict}")


if __name__ == "__main__":
    file_hits()
    dns_and_http()
    bucket_probe()
    sys.exit(0)
