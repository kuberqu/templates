#!/usr/bin/env bash
# Wartet auf die Modell-Downloads und faehrt danach den Talking-Head-Bakeoff.
# Laeuft auf dem POD im Hintergrund (setsid), Log: /workspace/bakeoff.log
set -u
echo "===== CHAIN START $(date -u) ====="

while pgrep -f "bash /workspace/dl_wan.sh" >/dev/null 2>&1; do sleep 20; done
echo "Downloads beendet: $(date -u)"
grep -a '^>>>' /workspace/dl_wan.log | tail -20

echo "--- Datei-Check ---"
for f in /workspace/ComfyUI/models/diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors \
         /workspace/ComfyUI/models/model_patches/wan2.1_infiniteTalk_single_fp16.safetensors \
         /workspace/ComfyUI/models/diffusion_models/wan2.2_s2v_14B_bf16.safetensors \
         /workspace/ComfyUI/models/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors \
         /workspace/ComfyUI/models/text_encoders/umt5_xxl_fp16.safetensors \
         /workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors \
         /workspace/ComfyUI/models/clip_vision/clip_vision_h.safetensors \
         /workspace/ComfyUI/models/audio_encoders/wav2vec2-chinese-base_fp16.safetensors ; do
  if [ -s "$f" ]; then echo "OK    $(basename $f) $(du -h $f | cut -f1)"
  else echo "FEHLT $f"; fi
done

cd /workspace
echo "===== TEST 1: INFINITETALK $(date -u) ====="
/workspace/venv/bin/python run_wan_talk.py it --audio szene_01.wav --bild host_ref.png --sekunden 3.072

echo "===== TEST 2: WAN 2.2 S2V $(date -u) ====="
/workspace/venv/bin/python run_wan_talk.py s2v --audio szene_01.wav --bild host_ref.png --sekunden 3.072

echo "===== CHAIN ENDE $(date -u) ====="
ls -la /workspace/ComfyUI/output/ | grep -iE "talk_it|talk_s2v"
