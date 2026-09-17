#!/usr/bin/env python3
"""LivePortrait-Retargeting-Test: Eye-/Lip-Retargeting gegen Baseline.

Baut die vollständige LivePortrait-Kette ZWEIMAL:
  1. baseline  — ohne Retargeting
  2. retarget  — LivePortraitRetargeting (eye + lip, konfigurierbarer Multiplier)
und rendert beide. Beweis, dass das Retargeting greift, erfolgt danach außerhalb
(ffmpeg psnr/ssim + visueller Vergleich der Augen-/Mundregion).

Aufruf: /workspace/venv/bin/python /workspace/test_lp_retargeting.py [multiplier]
"""
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8188"
FRAMES = 78
MULT = float(sys.argv[1]) if len(sys.argv) > 1 else 1.5
NODE_ASSETS = "/workspace/ComfyUI/custom_nodes/ComfyUI-LivePortrait/assets/examples"
INPUT_DIR = "/workspace/ComfyUI/input"


def ensure_assets() -> bool:
    """Frische Pods haben leeres input/ -> Beispiel-Assets aus dem Node-Repo holen."""
    os.makedirs(INPUT_DIR, exist_ok=True)
    for src, dst in ((f"{NODE_ASSETS}/source/s0.jpg", f"{INPUT_DIR}/lp_source.jpg"),
                     (f"{NODE_ASSETS}/driving/d0.mp4", f"{INPUT_DIR}/lp_driving.mp4")):
        if os.path.exists(dst):
            continue
        if os.path.exists(src):
            shutil.copy2(src, dst)
            print(f"  asset bereitgestellt: {os.path.basename(dst)}")
        else:
            print(f"  FEHLER: Asset fehlt und nicht auffindbar: {src}")
            return False
    return True

BASE = {
    "1": {"class_type": "LoadImage", "inputs": {"image": "lp_source.jpg"}},
    "2": {"class_type": "VHS_LoadVideo", "inputs": {
        "video": "lp_driving.mp4", "force_rate": 0, "custom_width": 0,
        "custom_height": 0, "frame_load_cap": FRAMES, "skip_first_frames": 0,
        "select_every_nth": 1, "format": "AnimateDiff"}},
    "3": {"class_type": "DownloadAndLoadLivePortraitModels",
          "inputs": {"precision": "auto", "mode": "human"}},
    "4": {"class_type": "LivePortraitLoadMediaPipeCropper",
          "inputs": {"landmarkrunner_onnx_device": "CPU", "keep_model_loaded": True}},
    "5": {"class_type": "LivePortraitCropper", "inputs": {
        "pipeline": ["3", 0], "cropper": ["4", 0], "source_image": ["1", 0],
        "dsize": 512, "scale": 2.3, "vx_ratio": 0.0, "vy_ratio": -0.125,
        "face_index": 0, "face_index_order": "large-small", "rotate": True}},
    "6": {"class_type": "LivePortraitCropper", "inputs": {
        "pipeline": ["3", 0], "cropper": ["4", 0], "source_image": ["2", 0],
        "dsize": 512, "scale": 2.3, "vx_ratio": 0.0, "vy_ratio": -0.125,
        "face_index": 0, "face_index_order": "large-small", "rotate": True}},
}

PROCESS_INPUTS = {
    "pipeline": ["3", 0], "crop_info": ["5", 1], "source_image": ["5", 0],
    "driving_images": ["6", 0], "lip_zero": False, "lip_zero_threshold": 0.03,
    "stitching": True, "delta_multiplier": 1.0, "mismatch_method": "constant",
    "relative_motion_mode": "relative",
    "driving_smooth_observation_variance": 3e-06,
}


def build(retarget: bool) -> dict:
    wf = json.loads(json.dumps(BASE))
    if retarget:
        # Hinweis: driving_crop_info ist das CROPINFO des DRIVING-Clips (Slot 1 von Node 6)
        wf["7"] = {"class_type": "LivePortraitRetargeting", "inputs": {
            "driving_crop_info": ["6", 1],
            "eye_retargeting": True, "eyes_retargeting_multiplier": MULT,
            "lip_retargeting": True, "lip_retargeting_multiplier": MULT}}
    inputs = dict(PROCESS_INPUTS)
    if retarget:
        inputs["opt_retargeting_info"] = ["7", 0]
    wf["8"] = {"class_type": "LivePortraitProcess", "inputs": inputs}
    wf["9"] = {"class_type": "LivePortraitComposite", "inputs": {
        "source_image": ["1", 0], "cropped_image": ["8", 0],
        "liveportrait_out": ["8", 1]}}
    wf["10"] = {"class_type": "VHS_VideoCombine", "inputs": {
        "images": ["9", 0], "frame_rate": 25.0, "loop_count": 0,
        "filename_prefix": "lp_retarget" if retarget else "lp_baseline",
        "format": "video/h264-mp4", "pingpong": False, "save_output": True}}
    return wf


def post(path, payload):
    req = urllib.request.Request(API + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))


def get(path):
    return json.load(urllib.request.urlopen(API + path, timeout=60))


def run(name: str, workflow: dict) -> str | None:
    print(f"\n=== {name} (multiplier={MULT}) ===", flush=True)
    t0 = time.time()
    try:
        pid = post("/prompt", {"client_id": f"rt-{name}", "prompt": workflow})["prompt_id"]
    except urllib.error.HTTPError as e:
        print(f"  SUBMIT FEHLER {e.code}: {e.read().decode()[:500]}")
        return None
    while True:
        hist = get(f"/history/{pid}")
        if pid in hist:
            status = hist[pid].get("status", {})
            dur = time.time() - t0
            if status.get("status_str") == "error":
                msgs = [m for m in status.get("messages", []) if m[0] == "execution_error"]
                print(f"  STATUS: error nach {dur:.0f}s")
                print("  ", json.dumps(msgs, default=str)[:1500])
                return None
            files = []
            for out in hist[pid].get("outputs", {}).values():
                for item in out.get("gifs", []):
                    files.append(item["filename"])
            print(f"  STATUS: success nach {dur:.0f}s -> {files}")
            return files[0] if files else None
        if time.time() - t0 > 1200:
            print("  TIMEOUT")
            return None
        time.sleep(4)


if __name__ == "__main__":
    if not ensure_assets():
        sys.exit(2)
    print("Health:", get("/system_stats")["system"]["comfyui_version"])
    base_file = run("baseline", build(False))
    rt_file = run("retarget", build(True))
    print("\n=== Ergebnis ===")
    print(f"  baseline: {base_file}")
    print(f"  retarget: {rt_file}")
    if base_file and rt_file:
        print(f"  Dateien: /workspace/ComfyUI/output/{base_file} , /workspace/ComfyUI/output/{rt_file}")
        sys.exit(0)
    sys.exit(1)
