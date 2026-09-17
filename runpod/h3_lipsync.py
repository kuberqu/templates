#!/usr/bin/env python3
"""H3 -> LipSync Verkabelung (YouTube-Tops x RunPod-LipSync-Pod).

Nimmt einen MiniMax-H3-Clip (Video + Voiceover-Audio) und erzeugt daraus ein
lippensynchrones Ergebnis. Zwei Modi, automatisch per Face-Check entschieden:

  direct     H3-Clip enthält ein Gesicht  -> Wav2Lip läuft über die H3-Frames,
             das Ergebnis wird mit der ORIGINAL-H3-Audiospur gemuxt (16-kHz-
             Wav2Lip-Audio klingt schlechter als das Original).
  presenter  H3-Clip enthält kein Gesicht (z.B. Space-Facts-Motive) -> das
             H3-Audio steuert ein Presenter-/Avatar-Bild (Wav2Lip).

Der Pod stellt ComfyUI nur auf 127.0.0.1:8188 bereit; der Orchestrator baut
daher einen SSH-Tunnel und arbeitet rein über HTTP gegen die ComfyUI-API
(/upload/image, /prompt, /history, /view). Der Face-Check läuft auf dem Pod
mit insightface (im ComfyUI-venv vorhanden).

Beispiele
---------
  ./h3_lipsync.py --h3 ~/workspace/youtube-tops/output/facts_20260905_100134.mp4 \
      --face /tmp/presenter.jpg --duration 6 --out /tmp/h3_lipsync_out.mp4
  ./h3_lipsync.py --h3 clip.mp4 --check-only          # nur Face-Check
Umgebung (statt CLI): LIPSYNC_POD, LIPSYNC_PORT, LIPSYNC_KEY
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

LOCAL_API_PORT = 18188


# ---------------------------------------------------------------- Shell-Helfer
def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def ffprobe(path: str) -> dict:
    out = sh(["ffprobe", "-v", "error", "-show_entries",
              "stream=index,codec_type,codec_name,width,height,nb_frames,r_frame_rate,channels,sample_rate"
              ":format=duration,size", "-of", "json", path]).stdout
    try:
        return json.loads(out)
    except Exception:
        return {}


def summary(path: str) -> str:
    info = ffprobe(path)
    v = next((s for s in info.get("streams", []) if s.get("codec_type") == "video"), {})
    a = next((s for s in info.get("streams", []) if s.get("codec_type") == "audio"), None)
    dur = info.get("format", {}).get("duration", "?")
    size = int(info.get("format", {}).get("size", 0) or 0)
    txt = (f"{v.get('width')}x{v.get('height')} {v.get('codec_name')} {v.get('nb_frames')} Frames "
           f"{float(dur):.2f}s {size/1024:.0f} KB" if v else "kein Video")
    txt += " + Audio" if a else " + KEIN Audio"
    return txt


# ---------------------------------------------------------------- HTTP-Client
class Client:
    def __init__(self, port: int):
        self.base = f"http://127.0.0.1:{port}"

    def get(self, path: str, timeout: int = 60):
        return json.load(urllib.request.urlopen(self.base + path, timeout=timeout))

    def post(self, path: str, payload: dict, timeout: int = 120):
        req = urllib.request.Request(self.base + path, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
        return json.load(urllib.request.urlopen(req, timeout=timeout))

    def upload(self, local_path: str, remote_name: str | None = None) -> str:
        """Datei nach ComfyUI/input hochladen (multipart über den Tunnel)."""
        name = remote_name or os.path.basename(local_path)
        boundary = "----h3lipsync"
        with open(local_path, "rb") as fh:
            data = fh.read()
        parts = []
        for field, value in (("type", "input"), ("overwrite", "true")):
            parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"\r\n\r\n{value}\r\n".encode())
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{name}\"\r\n"
            f"Content-Type: application/octet-stream\r\n\r\n".encode() + data + b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        body = b"".join(parts)
        req = urllib.request.Request(self.base + "/upload/image", data=body,
                                     headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
        res = json.load(urllib.request.urlopen(req, timeout=300))
        return res.get("name") or name

    def download(self, item: dict, dest: str):
        q = urllib.parse.urlencode({"filename": item["filename"],
                                    "subfolder": item.get("subfolder", ""),
                                    "type": item.get("type", "output")})
        with urllib.request.urlopen(f"{self.base}/view?{q}", timeout=600) as r, open(dest, "wb") as fh:
            shutil.copyfileobj(r, fh)


# ---------------------------------------------------------------- SSH-Tunnel
class Tunnel:
    def __init__(self, pod: str, port: int, key: str, local_port: int = LOCAL_API_PORT):
        self.pod, self.port, self.key, self.local_port = pod, port, key, local_port
        self.proc = None

    def _free_port(self) -> int:
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def start(self, timeout: int = 40) -> int:
        self.local_port = self._free_port()
        cmd = ["ssh", "-N", "-o", "StrictHostKeyChecking=no", "-o", "ExitOnForwardFailure=yes",
               "-o", "ServerAliveInterval=30", "-i", os.path.expanduser(self.key),
               "-p", str(self.port), "-L", f"127.0.0.1:{self.local_port}:127.0.0.1:8188", self.pod]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self.proc.poll() is not None:
                raise RuntimeError("SSH-Tunnel beendet: " + (self.proc.stderr.read() or "").strip()[:400])
            try:
                with socket.create_connection(("127.0.0.1", self.local_port), timeout=2):
                    return self.local_port
            except OSError:
                time.sleep(0.5)
        raise RuntimeError(f"SSH-Tunnel nach {timeout}s nicht erreichbar")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def ssh(pod: str, port: int, key: str, script: str, timeout: int = 600) -> subprocess.CompletedProcess:
    """Führt ein Shell-Snippet auf dem Pod aus (script als ein Argument)."""
    return subprocess.run(
        ["ssh", "-o", "StrictHostKeyChecking=no", "-i", os.path.expanduser(key),
         "-p", str(port), pod, script], capture_output=True, text=True, timeout=timeout)


# ---------------------------------------------------------------- Face-Check
FACE_CHECK = r'''
/workspace/venv/bin/python - "$@" <<'PYEOF'
import sys, json, os
import cv2, numpy as np
from insightface.app import FaceAnalysis

paths = sys.argv[1:]
app = FaceAnalysis(name="buffalo_l", root="/workspace/ComfyUI/models/insightface",
                   providers=["CPUExecutionProvider"], allowed_modules=["detection"])
app.prepare(ctx_id=-1, det_size=(640, 640))
out = []
for p in paths:
    img = cv2.imread(p)
    if img is None:
        out.append({"file": os.path.basename(p), "error": "unlesbar"}); continue
    fw = int(img.shape[1])
    faces = app.get(img)
    if not faces:
        out.append({"file": os.path.basename(p), "faces": 0, "frame_w": fw}); continue
    f = max(faces, key=lambda x: (x.bbox[2]-x.bbox[0]) * (x.bbox[3]-x.bbox[1]))
    w = float(f.bbox[2]-f.bbox[0]); h = float(f.bbox[3]-f.bbox[1])
    # Schwellen RELATIV zur Frame-Breite: Wav2Lip braucht ein erkennbares Gesicht,
    # kein großes. >=10% der Frame-Breite und >=48px absolut ist praktikabel.
    min_w = max(48.0, 0.10 * fw)
    out.append({"file": os.path.basename(p), "faces": len(faces), "frame_w": fw,
                "w": round(w), "h": round(h), "score": round(float(f.det_score), 3),
                "usable": bool(w >= min_w and float(f.det_score) >= 0.5),
                "min_w": round(min_w)})
print("FACEJSON=" + json.dumps(out))
PYEOF
'''


def face_check(pod: str, port: int, key: str, frames: list[str]) -> list[dict]:
    """frames = Pfade auf dem POD (bereits im input-Ordner)."""
    args = " ".join(f"/workspace/ComfyUI/input/{f}" for f in frames)
    res = ssh(pod, port, key, FACE_CHECK.replace('"$@"', args), timeout=600)
    for line in (res.stdout or "").splitlines():
        if line.startswith("FACEJSON="):
            return json.loads(line[len("FACEJSON="):])
    raise RuntimeError("Face-Check fehlgeschlagen:\n" + (res.stdout or "")[-800:] + (res.stderr or "")[-800:])


# ---------------------------------------------------------------- Workflows
def wf_wav2lip(source_node: str, audio_node: str, prefix: str, frames: int | None = None) -> dict:
    """source_node = Node-ID, deren Slot 0 IMAGE liefert (LoadImage oder VHS_LoadVideo)."""
    return {
        "1": {"class_type": "LoadAudio", "inputs": {"audio": audio_node}},
        "3": {"class_type": "Wav2Lip", "inputs": {
            "images": [source_node, 0], "audio": ["1", 0],
            "mode": "sequential", "face_detect_batch": 8}},
        "4": {"class_type": "VHS_VideoCombine", "inputs": {
            "images": ["3", 0], "audio": ["3", 1], "frame_rate": 25.0,
            "loop_count": 0, "filename_prefix": prefix,
            "format": "video/h264-mp4", "pingpong": False, "save_output": True}},
    }


def wf_direct(clip: str, audio: str, fps: float, frames: int, prefix: str) -> dict:
    wf = wf_wav2lip("2", audio, prefix)
    wf["2"] = {"class_type": "VHS_LoadVideo", "inputs": {
        "video": clip, "force_rate": fps, "custom_width": 0, "custom_height": 0,
        "frame_load_cap": frames, "skip_first_frames": 0, "select_every_nth": 1,
        "format": "AnimateDiff"}}
    wf["4"]["inputs"]["frame_rate"] = fps
    return wf


def wf_presenter(face: str, audio: str, fps: float, prefix: str) -> dict:
    wf = wf_wav2lip("2", audio, prefix)
    wf["2"] = {"class_type": "LoadImage", "inputs": {"image": face}}
    wf["4"]["inputs"]["frame_rate"] = fps
    return wf


# ---------------------------------------------------------------- Ablauf
def run_workflow(cli: Client, workflow: dict, tag: str, timeout: int = 3600) -> tuple[dict, list[dict]]:
    res = cli.post("/prompt", {"client_id": f"h3lipsync-{tag}", "prompt": workflow})
    pid = res["prompt_id"]
    t0 = time.time()
    last_log = 0
    while True:
        hist = cli.get(f"/history/{pid}")
        if pid in hist:
            entry = hist[pid]
            status = entry.get("status", {})
            if status.get("status_str") == "error":
                msgs = [m for m in status.get("messages", []) if m[0] == "execution_error"]
                raise RuntimeError("ComfyUI-Fehler: " + json.dumps(msgs, default=str)[:1200])
            files = []
            for out in entry.get("outputs", {}).values():
                for item in out.get("gifs", []):
                    files.append(item)
            return {"seconds": round(time.time() - t0)}, files
        if time.time() - t0 > timeout:
            raise RuntimeError(f"Timeout nach {timeout}s (prompt {pid})")
        el = int(time.time() - t0)
        if el and el // 30 > last_log:
            last_log = el // 30
            print(f"    ... {el}s", flush=True)
        time.sleep(5)


def main() -> int:
    ap = argparse.ArgumentParser(description="MiniMax-H3-Clip -> LipSync (RunPod ComfyUI)")
    ap.add_argument("--h3", required=True, help="H3-Clip (mp4, mit Voiceover-Audio)")
    ap.add_argument("--face", help="Presenter-Bild (für Modus 'presenter')")
    ap.add_argument("--mode", choices=["auto", "direct", "presenter"], default="auto")
    ap.add_argument("--start", type=float, default=0.0, help="Startzeit im H3-Clip (s)")
    ap.add_argument("--duration", type=float, default=6.0, help="Länge des Ausschnitts (s)")
    ap.add_argument("--width", type=int, default=540, help="Breite des Ausschnitts (direct-Modus)")
    ap.add_argument("--fps", type=float, default=24.0)
    ap.add_argument("--out", default="h3_lipsync_out.mp4")
    ap.add_argument("--check-only", action="store_true", help="nur Face-Check, kein Render")
    ap.add_argument("--pod", default=os.environ.get("LIPSYNC_POD", "root@157.157.221.29"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("LIPSYNC_PORT", "20439")))
    ap.add_argument("--key", default=os.environ.get("LIPSYNC_KEY", "~/.ssh/id_ed25519"))
    args = ap.parse_args()

    for tool in ("ffmpeg", "ffprobe", "ssh"):
        if not shutil.which(tool):
            print(f"FEHLT: {tool}", file=sys.stderr)
            return 2
    if not os.path.isfile(args.h3):
        print(f"H3-Clip nicht gefunden: {args.h3}", file=sys.stderr)
        return 2

    print(f"H3-Clip: {summary(args.h3)}")
    has_audio = any(s.get("codec_type") == "audio" for s in ffprobe(args.h3).get("streams", []))
    if not has_audio:
        print("FEHLER: Der H3-Clip hat keine Audiospur — Wav2Lip braucht Sprache als Antrieb.\n"
              "        (Für Testzwecke vorher Audio anmuxen: ffmpeg -i clip.mp4 -i speech.wav "
              "-map 0:v -map 1:a -c:v copy -c:a aac out.mp4)", file=sys.stderr)
        return 2
    tmp = tempfile.mkdtemp(prefix="h3lipsync_")
    tunnel = Tunnel(args.pod, args.port, args.key)
    try:
        print(f"--> SSH-Tunnel zu {args.pod}:{args.port} ...", flush=True)
        port = tunnel.start()
        cli = Client(port)
        info = cli.get("/system_stats")["system"]
        print(f"    ComfyUI {info.get('comfyui_version')} erreichbar (Tunnel-Port {port})")

        # 1) Ausschnitt + Audio lokal vorbereiten
        clip = os.path.join(tmp, "h3_clip.mp4")
        audio = os.path.join(tmp, "h3_audio.wav")
        # Ausschnitt wird immer gebraucht: für den Face-Check und als Quelle im direct-Modus
        sh(["ffmpeg", "-v", "error", "-y", "-ss", str(args.start), "-t", str(args.duration),
            "-i", args.h3, "-vf", f"scale={args.width}:-2", "-r", str(args.fps),
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-an", clip], check=True)
        sh(["ffmpeg", "-v", "error", "-y", "-ss", str(args.start), "-t", str(args.duration),
            "-i", args.h3, "-vn", "-ar", "16000", "-ac", "1", audio], check=True)
        # Segment-Audio in Originalqualität (zum Zurückmuxen; die 16-kHz-Wav2Lip-Spur
        # ist nur der Antrieb und klingt schlechter)
        seg_audio = os.path.join(tmp, "h3_seg_audio.m4a")
        sh(["ffmpeg", "-v", "error", "-y", "-ss", str(args.start), "-t", str(args.duration),
            "-i", args.h3, "-vn", "-c:a", "aac", "-b:a", "192k", seg_audio], check=True)
        print(f"    Ausschnitt: {summary(clip)} | Audio: {summary(audio)}")

        # 2) Frames für den Face-Check (1/s) + Upload
        frames = []
        for i in range(max(1, int(args.duration))):
            p = os.path.join(tmp, f"frame{i:02d}.jpg")
            sh(["ffmpeg", "-v", "error", "-y", "-ss", str(i), "-i", clip, "-frames:v", "1", "-q:v", "3", p])
            if os.path.isfile(p):
                frames.append(os.path.basename(cli.upload(p)))
        print(f"--> Face-Check auf dem Pod ({len(frames)} Frames, insightface):", flush=True)
        checks = face_check(args.pod, args.port, args.key, frames)
        for c in checks:
            detail = (f"bbox {c['w']}x{c['h']}px (min {c['min_w']}) score {c['score']}"
                      if c.get("w") else c.get("error", "kein Gesicht"))
            print(f"    {c['file']}: Gesichter={c.get('faces', 0)} {detail}"
                  f"{' -> nutzbar' if c.get('usable') else ''}")
        # Nicht jeder Frame muss ein Gesicht haben (Szenenschnitte in H3-Clips sind normal):
        # es reichen 40% der geprüften Frames.
        usable = [c for c in checks if c.get("usable")]
        need = max(1, int(0.4 * len(checks)))
        has_face = len(usable) >= need
        detected = args.mode if args.mode != "auto" else ("direct" if has_face else "presenter")
        print(f"--> nutzbares Gesicht in {len(usable)}/{len(checks)} Frames (nötig: {need}) "
              f"-> Modus: {detected.upper()}")

        if args.check_only:
            print("(--check-only: kein Render)")
            return 0

        # 3) Quelldateien hochladen
        remote_clip = os.path.basename(cli.upload(clip))
        remote_audio = os.path.basename(cli.upload(audio))
        if detected == "direct":
            n_frames = int(args.duration * args.fps)
            wf = wf_direct(remote_clip, remote_audio, args.fps, n_frames, "h3_lipsync")
        else:
            if not args.face or not os.path.isfile(args.face):
                print("FEHLER: Modus 'presenter' braucht --face <Bild>", file=sys.stderr)
                return 2
            remote_face = os.path.basename(cli.upload(args.face))
            wf = wf_presenter(remote_face, remote_audio, args.fps, "h3_lipsync")

        # 4) Rendern
        print(f"--> Wav2Lip-Render ({detected}) gestartet ...", flush=True)
        stats, files = run_workflow(cli, wf, detected)
        if not files:
            print("FEHLER: kein Ausgabefile im history-Objekt", file=sys.stderr)
            return 1
        raw = os.path.join(tmp, "lipsync_raw.mp4")
        cli.download(files[0], raw)
        print(f"    Render fertig in {stats['seconds']}s: {summary(raw)}")

        # 5) Original-H3-Audio zurückmuxen (16-kHz-Wav2Lip-Spur ist qualitativ schlechter)
        sh(["ffmpeg", "-v", "error", "-y", "-i", raw, "-i", seg_audio, "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "copy", "-c:a", "copy", "-shortest", args.out], check=True)
        if not os.path.isfile(args.out):
            shutil.copy2(raw, args.out)
        print(f"\nERGEBNIS: {args.out}\n  {summary(args.out)}")
        print(f"  Modus: {detected} | H3-Ausschnitt: {args.start:.1f}s +{args.duration:.1f}s | "
              f"Renderzeit: {stats['seconds']}s")
        return 0
    except subprocess.CalledProcessError as e:
        print(f"ffmpeg-Fehler: {(e.stderr or '')[-500:]}", file=sys.stderr)
        return 1
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()[:600]}", file=sys.stderr)
        return 1
    finally:
        tunnel.stop()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
