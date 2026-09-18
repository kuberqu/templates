#!/usr/bin/env bash
# Wartet auf das Ende des S2V-fp8-Downloads und rendert danach Arm 2 des Bakeoffs.
set -u
echo "===== S2V-CHAIN START $(date -u) ====="
while pgrep -f "bash /workspace/dl_wan2[.]sh" >/dev/null 2>&1; do sleep 15; done
echo "Download beendet: $(date -u)"
ls -la /workspace/ComfyUI/models/diffusion_models/wan2.2_s2v_14B_fp8_scaled.safetensors
du -sh /workspace
cd /workspace
/workspace/venv/bin/python run_wan_talk.py s2v \
  --audio szene_01.wav --bild host_ref.png --sekunden 3.072 \
  --prefix talk_s2v --unet wan2.2_s2v_14B_fp8_scaled.safetensors
echo "===== S2V-CHAIN ENDE $(date -u) ====="
ls -la /workspace/ComfyUI/output/talk_s2v* 2>/dev/null
