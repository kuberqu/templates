#!/usr/bin/env bash
# Wan-Talking-Head-Modelle fuer den A/B-Test (InfiniteTalk + Wan2.2 S2V).
# Laeuft auf dem POD. Quelle: Comfy-Org Repackaged + Kijai.
set -u
M=/workspace/ComfyUI/models
mkdir -p "$M"/{diffusion_models,model_patches,clip_vision,vae,text_encoders,audio_encoders,loras}
HF=https://huggingface.co
R21=$HF/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files
R22=$HF/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files

get() {  # get <url> <zieldatei>
  local url="$1" out="$2"
  if [ -s "$out" ]; then echo "SKIP (vorhanden): $out"; return 0; fi
  echo ">>> $(date -u +%H:%M:%S) START $(basename "$out")"
  if curl -L --fail --retry 3 --retry-delay 5 -C - -o "$out" "$url"; then
    echo ">>> $(date -u +%H:%M:%S) OK    $(basename "$out") $(du -h "$out" | cut -f1)"
  else
    echo ">>> $(date -u +%H:%M:%S) FEHLER $(basename "$out")"
  fi
}

echo "===== START $(date -u) ====="

# --- gemeinsam ---
get $R21/vae/wan_2.1_vae.safetensors                          $M/vae/wan_2.1_vae.safetensors
get $R21/text_encoders/umt5_xxl_fp16.safetensors               $M/text_encoders/umt5_xxl_fp16.safetensors
get $R22/audio_encoders/wav2vec2_large_english_fp16.safetensors $M/audio_encoders/wav2vec2_large_english_fp16.safetensors
get $R21/clip_vision/clip_vision_h.safetensors                 $M/clip_vision/clip_vision_h.safetensors

# --- InfiniteTalk (Wan 2.1 I2V 480p + Audio-Patch) ---
get $R21/diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors $M/diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors
get $R21/model_patches/wan2.1_infiniteTalk_single_fp16.safetensors $M/model_patches/wan2.1_infiniteTalk_single_fp16.safetensors
get $HF/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors \
    $M/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors

# --- Wan 2.2 S2V (Speech-to-Video, nativ) ---
get $R22/diffusion_models/wan2.2_s2v_14B_bf16.safetensors      $M/diffusion_models/wan2.2_s2v_14B_bf16.safetensors

echo "===== ENDE $(date -u) ====="
ls -la $M/diffusion_models $M/model_patches $M/audio_encoders
