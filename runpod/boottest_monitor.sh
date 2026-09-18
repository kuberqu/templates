#!/usr/bin/env bash
# Boot-Test des zweiten Pods überwachen (Script-Test, schwache GPU).
# Wartet, bis setup.sh UND entrypoint.sh fertig sind, und prüft dann:
#   Statusfiles, Gen-Modelle (Soll-Werte), Symlinks, Node-Registrierung,
#   ComfyUI-HTTP, Python-Importe (mediapipe.framework.formats), boot_report.sh
set -u
SSH2="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=25 -o ServerAliveInterval=30 -i /home/claw/.ssh/id_ed25519 -p 23001 root@157.157.221.29"
LOG=/home/claw/workspace/runpod-lipsync/shorts/boottest_pod2.log
printf '\n========== BOOT-TEST %s ==========\n' "$(date -u +%H:%M:%SZ)" >> "$LOG"

echo "1) warte auf setup.sh + entrypoint.sh" | tee -a "$LOG"
for i in $(seq 1 120); do
  RUN=$($SSH2 'pgrep -f "setup[.]sh" >/dev/null || pgrep -f "entrypoin[t].sh" >/dev/null; echo $?' 2>/dev/null)
  if [ "$RUN" = "1" ]; then echo "   beide beendet: $(date -u +%H:%M:%SZ)" | tee -a "$LOG"; break; fi
  if [ $((i % 5)) = 0 ]; then
    P=$($SSH2 'grep -ac "✓" /workspace/comfyui_setup.log 2>/dev/null; du -sh /workspace 2>/dev/null | cut -f1' 2>/dev/null | tr '\n' ' ')
    echo "   [$i] Phasen-Häkchen/Volume: $P" | tee -a "$LOG"
  fi
  sleep 30
done

echo "2) Statusfiles" | tee -a "$LOG"
$SSH2 'cat /workspace/lipsync_status.json 2>/dev/null; echo; cat /workspace/setup_status.json 2>/dev/null; echo; echo "--- Gen-Status ---"; cat /workspace/gen_models_status.json 2>/dev/null' 2>&1 | tee -a "$LOG"

echo "3) Gen-Modelle (Soll laut setup.sh)" | tee -a "$LOG"
$SSH2 'for f in \
  diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors \
  model_patches/wan2.1_infiniteTalk_single_fp16.safetensors \
  text_encoders/umt5_xxl_fp16.safetensors \
  vae/wan_2.1_vae.safetensors \
  clip_vision/clip_vision_h.safetensors \
  audio_encoders/wav2vec2-chinese-base_fp16.safetensors \
  loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors \
  loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors \
  diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors \
  diffusion_models/qwen_image_edit_2511_int8_convrot.safetensors \
  text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors \
  vae/qwen_image_vae.safetensors ; do
  if [ -L /workspace/ComfyUI/models/$f ]; then
    t=$(readlink -f /workspace/ComfyUI/models/$f)
    [ -s "$t" ] && printf "  OK    %-62s %.2fGB (symlink ok)\n" "$(basename $f)" "$(stat -Lc%s $t | awk "{print \$1/1e9}")" \
                 || printf "  TOT   %-62s -> %s\n" "$(basename $f)" "$t"
  elif [ -s /workspace/ComfyUI/models/$f ]; then
    printf "  OK*   %-62s %.2fGB (Datei, kein Symlink)\n" "$(basename $f)" "$(stat -Lc%s /workspace/ComfyUI/models/$f | awk "{print \$1/1e9}")"
  else
    printf "  FEHLT %s\n" "$f"
  fi
done' 2>&1 | tee -a "$LOG"

echo "4) Phasen + Fehler aus dem Setup" | tee -a "$LOG"
$SSH2 'grep -aE "^(✓|⚠|✗)|FEHLER|failed|zu klein" /workspace/comfyui_setup.log | tail -30; echo "--- Gesamt-Phasen ---"; grep -ac "phase_ok\|\"OK|" /workspace/comfyui_setup.log' 2>&1 | tee -a "$LOG"

echo "5) ComfyUI + Nodes + Importe" | tee -a "$LOG"
$SSH2 'curl -s -o /dev/null -w "HTTP=%{http_code}\n" http://127.0.0.1:8188/system_stats; pgrep -af "ComfyUI/mai[n].py" | wc -l; /workspace/venv/bin/python -c "
import json,urllib.request
d=json.load(urllib.request.urlopen(\"http://127.0.0.1:8188/object_info\",timeout=60))
print(\"Nodes registriert:\", len(d))
for n in [\"WanInfiniteTalkToVideo\",\"AudioEncoderLoader\",\"UpscaleModelLoader\",\"VHS_LoadVideo\",\"CreateVideo\",\"SaveVideo\",\"ModelPatchLoader\"]:
    print(\"  \", n, \"OK\" if n in d else \"FEHLT\")
"; /workspace/venv/bin/python -c "from mediapipe.framework.formats import landmark_pb2; print(\"mediapipe.framework OK\")" 2>&1 | tail -2' 2>&1 | tee -a "$LOG"

echo "6) boot_report.sh" | tee -a "$LOG"
$SSH2 'bash /workspace/boot_report.sh 2>&1 | tail -35; echo "EXIT=$?"' 2>&1 | tee -a "$LOG"
echo "BOOTTEST_FERTIG" | tee -a "$LOG"
