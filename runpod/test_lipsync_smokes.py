#!/usr/bin/env python3
"""Smoke-Tests Wav2Lip + SadTalker über die ComfyUI-API.

Beide Ketten wurden seit dem Umbau (setup.sh/entrypoint.sh) nicht mehr geprüft.
Läuft auf dem Pod:  /workspace/venv/bin/python /workspace/test_lipsync_smokes.py

Voraussetzungen im input-Ordner: lp_source.jpg (Gesicht), tts_test.wav (Sprache).
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

API = "http://127.0.0.1:8188"
FACE = "lp_source.jpg"
AUDIO = "tts_test.wav"
RESULTS = {}

WAV2LIP = {
    "1": {"class_type": "LoadImage", "inputs": {"image": FACE}},
    "2": {"class_type": "LoadAudio", "inputs": {"audio": AUDIO}},
    "3": {"class_type": "Wav2Lip", "inputs": {
        "images": ["1", 0], "audio": ["2", 0],
        "mode": "sequential", "face_detect_batch": 8}},
    "4": {"class_type": "VHS_VideoCombine", "inputs": {
        "images": ["3", 0], "audio": ["3", 1], "frame_rate": 25.0,
        "loop_count": 0, "filename_prefix": "w2l_smoke",
        "format": "video/h264-mp4", "pingpong": False, "save_output": True}},
}

SADTALKER = {
    "1": {"class_type": "LoadImage", "inputs": {"image": FACE}},
    "2": {"class_type": "LoadAudio", "inputs": {"audio": AUDIO}},
    "3": {"class_type": "SadTalker", "inputs": {
        "image": ["1", 0], "audio": ["2", 0], "poseStyle": 0,
        "faceModelResolution": "256", "preprocess": "crop", "stillMode": False,
        "batchSizeInGeneration": 2, "gfpganAsFaceEnhancer": False,
        "useIdleMode": False, "idleModeTime": 5, "useRefVideo": False,
        "refInfo": "pose"}},
    # SadTalker liefert (STRING video_path, STRING show_video_path) -> ohne
    # ShowVideo-Node bricht ComfyUI mit "prompt_no_outputs" ab
    "4": {"class_type": "ShowVideo", "inputs": {"show_video_path": ["3", 1]}},
}


def post(path, payload):
    req = urllib.request.Request(API + path, data=json.dumps(payload).encode(),
                                headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))


def get(path):
    return json.load(urllib.request.urlopen(API + path, timeout=60))


def run(name, workflow, timeout=1800):
    print(f"\n=== {name} === ", flush=True)
    t0 = time.time()
    try:
        res = post("/prompt", {"client_id": f"smoke-{name}", "prompt": workflow})
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:600]
        print(f"  SUBMIT FEHLGESCHLAGEN ({e.code}): {body}")
        RESULTS[name] = {"status": "submit_failed", "error": body}
        return
    pid = res["prompt_id"]
    print(f"  prompt_id: {pid} (Warte auf Ergebnis ...)", flush=True)
    while True:
        hist = get(f"/history/{pid}")
        if pid in hist:
            entry = hist[pid]
            status = entry.get("status", {})
            st = status.get("status_str")
            dur = time.time() - t0
            if st == "error":
                msgs = [m for m in status.get("messages", []) if m[0] in ("execution_error", "execution_interrupted")]
                print(f"  STATUS: error nach {dur:.0f}s")
                print("  ", json.dumps(msgs, default=str)[:800])
                RESULTS[name] = {"status": "error", "seconds": round(dur), "messages": msgs}
                return
            outputs = entry.get("outputs", {})
            files = []
            for node_id, out in outputs.items():
                for key in ("gifs", "images", "audio", "video"):
                    for item in out.get(key, []) if isinstance(out.get(key), list) else []:
                        if isinstance(item, dict) and "filename" in item:
                            files.append(item["filename"])
            print(f"  STATUS: success nach {dur:.0f}s")
            print(f"  Outputs: {files}")
            RESULTS[name] = {"status": "success", "seconds": round(dur), "files": files}
            return
        if time.time() - t0 > timeout:
            print(f"  TIMEOUT nach {timeout}s")
            RESULTS[name] = {"status": "timeout"}
            return
        if int(time.time() - t0) % 30 < 5:
            print(f"    ... {time.time()-t0:.0f}s", flush=True)
        time.sleep(5)


def probe(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                              "stream=codec_name,width,height,nb_frames:format=duration,size",
                              "-of", "default=nw=1", path],
                             capture_output=True, text=True, timeout=60).stdout
        return dict(l.split("=", 1) for l in out.strip().splitlines() if "=" in l)
    except Exception as e:
        return {"error": str(e)}


if __name__ == "__main__":
    print("Health:", get("/system_stats")["system"]["comfyui_version"])
    tmp_before = set(os.listdir("/workspace/ComfyUI/output"))
    run("Wav2Lip", WAV2LIP)
    run("SadTalker", SADTALKER)

    # SadTalker schreibt <timestamp>.mp4 direkt in output/ (kein history-Eintrag)
    new_files = sorted(set(os.listdir("/workspace/ComfyUI/output")) - tmp_before)
    if new_files:
        print(f"\nNeu in output/ (SadTalker): {new_files}")

    print("\n=== Zusammenfassung ===")
    for name, r in RESULTS.items():
        print(f"  {name}: {r.get('status')} {r.get('seconds', '')}s {r.get('files', '')}".rstrip())
    print("\n=== ffprobe ===")
    for f in RESULTS.get("Wav2Lip", {}).get("files", []):
        p = f"/workspace/ComfyUI/output/{f}"
        print(f"  {f}: {probe(p)}")
    for f in new_files:
        if f.endswith(".mp4"):
            p = f"/workspace/ComfyUI/output/{f}"
            print(f"  {f}: {probe(p)}")

    ok = all(r.get("status") == "success" for r in RESULTS.values())
    sys.exit(0 if ok else 1)
