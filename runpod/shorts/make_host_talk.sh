#!/usr/bin/env bash
# Neutrales Host-Portrait erzeugen -> Wav2Lip -> Telegram
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"
DIR=/home/claw/workspace/runpod-lipsync/shorts/hummer_lobster
LOG=/home/claw/workspace/runpod-lipsync/shorts/w2l_neutral.log
: > "$LOG"

echo "1) neutrales Host-Portrait (Qwen-Image)" | tee -a "$LOG"
$POD 'cd /workspace && /workspace/venv/bin/python - <<PY
import json, time, urllib.request
UNET="qwen_image_2512_fp8_e4m3fn.safetensors"; CLIP="qwen_2.5_vl_7b_fp8_scaled.safetensors"; VAE="qwen_image_vae.safetensors"
P=("Studio portrait photograph of a man in his mid-thirties with short dark brown hair, light stubble and brown eyes, "
   "wearing a dark blue suit over a white shirt, looking directly into the camera with a calm neutral expression, "
   "mouth fully closed, lips relaxed and together, dark blue seamless studio background, soft even lighting, "
   "head and shoulders framing, sharp focus on the face, 85mm lens")
N="open mouth, teeth, cartoon, anime, deformed, watermark, text, blurry"
g={"37":{"class_type":"UNETLoader","inputs":{"unet_name":UNET,"weight_dtype":"default"}},
   "38":{"class_type":"CLIPLoader","inputs":{"clip_name":CLIP,"type":"qwen_image","device":"default"}},
   "39":{"class_type":"VAELoader","inputs":{"vae_name":VAE}},
   "66":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["37",0],"shift":3.1}},
   "6":{"class_type":"CLIPTextEncode","inputs":{"text":P,"clip":["38",0]}},
   "7":{"class_type":"CLIPTextEncode","inputs":{"text":N,"clip":["38",0]}},
   "58":{"class_type":"EmptySD3LatentImage","inputs":{"width":832,"height":1216,"batch_size":1}},
   "3":{"class_type":"KSampler","inputs":{"model":["66",0],"positive":["6",0],"negative":["7",0],
        "latent_image":["58",0],"seed":777,"steps":20,"cfg":4.0,"sampler_name":"euler","scheduler":"simple","denoise":1.0}},
   "8":{"class_type":"VAEDecode","inputs":{"samples":["3",0],"vae":["39",0]}},
   "60":{"class_type":"SaveImage","inputs":{"images":["8",0],"filename_prefix":"host_neutral/"}}}
r=urllib.request.Request("http://127.0.0.1:8188/prompt",data=json.dumps({"prompt":g}).encode(),headers={"Content-Type":"application/json"})
pid=json.loads(urllib.request.urlopen(r,timeout=60).read())["prompt_id"]
for _ in range(120):
    time.sleep(5)
    h=json.loads(urllib.request.urlopen(f"http://127.0.0.1:8188/history/{pid}",timeout=30).read())
    if pid in h:
        print("Bild:", h[pid].get("status",{}).get("status_str"), [i["filename"] for o in (h[pid].get("outputs") or {}).values() for i in o.get("images",[])])
        break
PY' 2>&1 | tail -3 | tee -a "$LOG"

F=$($POD 'ls -t /workspace/ComfyUI/output/host_neutral/*.png 2>/dev/null | head -1' | tr -d "\r")
[ -z "$F" ] && { echo "KEIN BILD" | tee -a "$LOG"; exit 1; }
scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 "root@194.68.245.49:$F" "$DIR/host_neutral.png"
echo "   geholt: $DIR/host_neutral.png ($(stat -c%s "$DIR/host_neutral.png") Bytes)" | tee -a "$LOG"

echo "2) Wav2Lip mit neutralem Portrait" | tee -a "$LOG"
cd /home/claw/workspace/kuberqu-templates/runpod
LIPSYNC_POD=root@194.68.245.49 LIPSYNC_PORT=22014 python3 h3_lipsync.py \
  --audio "$DIR/audio/szene_01.wav" --face "$DIR/host_neutral.png" \
  --mode presenter --duration 3.2 --out "$DIR/host_talk_01.mp4" >> "$LOG" 2>&1
tail -4 "$LOG"

if [ -f "$DIR/host_talk_01.mp4" ]; then
  echo "3) Telegram" | tee -a "$LOG"
  hermes send --to telegram:27900483 "MEDIA:$DIR/host_talk_01.mp4" 2>&1 | tail -1 | tee -a "$LOG"
fi
echo "W2L_FERTIG"
