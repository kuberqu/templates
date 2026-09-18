#!/usr/bin/env bash
# Zweiter Download-Lauf: nur was noch fehlt — S2V in fp8_scaled (16,4 GB) statt
# bf16 (32,6 GB), weil das Pod-Volume bei 200 GB Quota fast voll ist.
set -u
M=/workspace/ComfyUI/models
HF=https://huggingface.co
R22=$HF/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files
R21=$HF/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files

echo "===== LAUF 2 START $(date -u) ====="
df -h /workspace | tail -1

get() {  # get <url> <zieldatei> <mindestgroesse-in-GB>
  local url="$1" out="$2" min="${3:-0.01}" have
  have=$(stat -c%s "$out" 2>/dev/null || echo 0)
  if awk -v h="$have" -v m="$min" 'BEGIN{exit !(h/1e9 > m)}'; then
    echo "SKIP (komplett): $(basename $out) $((have/1000000))MB"; return 0
  fi
  echo ">>> $(date -u +%H:%M:%S) START $(basename $out) (habe $((have/1000000))MB)"
  if curl -L --fail --retry 3 --retry-delay 5 -C - -o "$out" "$url"; then
    echo ">>> $(date -u +%H:%M:%S) OK    $(basename $out) $(du -h "$out" | cut -f1)"
  else
    echo ">>> $(date -u +%H:%M:%S) FEHLER $(basename $out)"
  fi
}

# InfiniteTalk-Patch zu Ende bringen (war beim Stopp bei ~5,0 von 5,13 GB)
get $R21/model_patches/wan2.1_infiniteTalk_single_fp16.safetensors \
    $M/model_patches/wan2.1_infiniteTalk_single_fp16.safetensors 5.0
# Lightning-LoRA fuer InfiniteTalk
get $HF/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors \
    $M/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors 0.7
# Wan 2.2 S2V in fp8_scaled
get $R22/diffusion_models/wan2.2_s2v_14B_fp8_scaled.safetensors \
    $M/diffusion_models/wan2.2_s2v_14B_fp8_scaled.safetensors 15.0

echo "===== LAUF 2 ENDE $(date -u) ====="
du -sh /workspace; df -h /workspace | tail -1
ls -la $M/diffusion_models/*.safetensors $M/model_patches/wan*.safetensors | awk '{printf "%.2fGB %s\n", $5/1e9, $9}'
