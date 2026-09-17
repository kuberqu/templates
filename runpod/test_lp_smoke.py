#!/usr/bin/env python3
"""LivePortrait-Smoke-Test über die ComfyUI-API.

Beweist, dass die Node-Kette ZUR LAUFZEIT funktioniert — insbesondere der
mediapipe-Cropper (mediapipe 1.0.x bricht erst hier, nicht beim Import).

Aufruf: /workspace/venv/bin/python /workspace/test_lp_smoke.py [frames]
"""
import json
import sys
import time
import urllib.request

API = "http://127.0.0.1:8188"
FRAMES = int(sys.argv[1]) if len(sys.argv) > 1 else 78

WORKFLOW = {
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
    "7": {"class_type": "LivePortraitProcess", "inputs": {
        "pipeline": ["3", 0], "crop_info": ["5", 1], "source_image": ["5", 0],
        "driving_images": ["6", 0], "lip_zero": False, "lip_zero_threshold": 0.03,
        "stitching": True, "delta_multiplier": 1.0, "mismatch_method": "constant",
        "relative_motion_mode": "relative",
        "driving_smooth_observation_variance": 3e-06}},
    "8": {"class_type": "LivePortraitComposite", "inputs": {
        "source_image": ["1", 0], "cropped_image": ["7", 0],
        "liveportrait_out": ["7", 1]}},
    "9": {"class_type": "VHS_VideoCombine", "inputs": {
        "images": ["8", 0], "frame_rate": 25.0, "loop_count": 0,
        "filename_prefix": "lp_smoke", "format": "video/h264-mp4",
        "pingpong": False, "save_output": True}},
}


def post(path, payload):
    req = urllib.request.Request(
        API + path, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))


def get(path):
    return json.load(urllib.request.urlopen(API + path, timeout=60))


if __name__ == "__main__":
    print(f"--> Submit LivePortrait-Workflow ({FRAMES} Frames)")
    res = post("/prompt", {"client_id": "lp-smoke", "prompt": WORKFLOW})
    prompt_id = res["prompt_id"]
    print(f"    prompt_id: {prompt_id}")
    t0 = time.time()
    while True:
        hist = get(f"/history/{prompt_id}")
        if prompt_id in hist:
            entry = hist[prompt_id]
            status = entry.get("status", {})
            print(f"\n--> Status: {status.get('status_str')} nach {time.time()-t0:.1f}s")
            if status.get("status_str") == "error":
                for m in status.get("messages", []):
                    print("   ", m)
                sys.exit(1)
            outputs = entry.get("outputs", {})
            print("--> Outputs:")
            for node_id, out in outputs.items():
                print(f"    Node {node_id}: {json.dumps(out, default=str)[:400]}")
            sys.exit(0)
        if time.time() - t0 > 900:
            print("TIMEOUT nach 900s")
            sys.exit(1)
        time.sleep(5)
