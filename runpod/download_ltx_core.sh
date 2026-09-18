#!/usr/bin/env bash
# Einmaliger Download des LTX-2.5-Kerns (~40 GB) in den laufenden Pod, damit der
# nächste Pod (mehr Volume/VRAM) die Dateien schon vorfindet. Spiegelt exakt die
# Dateiliste aus setup.sh (dort per HfApi verifiziert).
set -uo pipefail
BASE=/workspace
MODELS="$BASE/ComfyUI/models"
STAGE="$BASE/gen_models"
LOG="$BASE/gen_download_ltx.log"
TOK_FILE="$BASE/.hf_token"

log() { echo "[$(date -u '+%H:%M:%S')] $*" | tee -a "$LOG"; }

if [ ! -s "$TOK_FILE" ]; then log "FEHLER: $TOK_FILE fehlt"; exit 1; fi
export HF_TOKEN="$(tr -d '[:space:]' < "$TOK_FILE")"
mkdir -p "$STAGE" "$MODELS"/{diffusion_models,vae,text_encoders,loras,latent_upscale_models,model_patches}

FILES=(
  "diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors"
  "text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors"
  "vae/ltx-2.5-video-vae-bf16.safetensors"
  "vae/ltx-2.5-audio-vae-bf16.safetensors"
  "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
  "latent_upscale_models/ltx-2.5-latent-temporal-upscaler-x2-bf16-1.0.safetensors"
  "model_patches/ltx-2.5-duration-head-bf16.safetensors"
)

log "=== LTX-2.5 Kern-Download startet (${#FILES[@]} Dateien, ~40 GB) ==="
ok=0; fail=0
for f in "${FILES[@]}"; do
  t0=$(date +%s)
  if "$BASE/venv/bin/hf" download "Lightricks/LTX-2.5" --include "$f" --local-dir "$STAGE" >>"$LOG" 2>&1; then
    sz=$(du -h "$STAGE/$f" 2>/dev/null | cut -f1)
    log "OK   $f ($sz, $(( $(date +%s) - t0 ))s)"
    ok=$((ok + 1))
  else
    log "FAIL $f"
    fail=$((fail + 1))
  fi
  df -h /workspace | tail -1 | awk '{print "     Volume belegt: "$3" ("$5")"}' >> "$LOG"
done

log "=== Verlinken nach $MODELS ==="
n=0
for d in diffusion_models vae text_encoders loras latent_upscale_models model_patches; do
  [ -d "$STAGE/$d" ] || continue
  for f in "$STAGE/$d"/*; do
    [ -f "$f" ] || continue
    mkdir -p "$MODELS/$d"
    ln -sfn "$f" "$MODELS/$d/$(basename "$f")" && n=$((n + 1))
  done
done
log "verlinkt: $n Dateien"
log "=== FERTIG: $ok ok, $fail fehlgeschlagen ==="
du -sh "$STAGE" | awk '{print "Staging-Groesse: "$1}' | tee -a "$LOG"
