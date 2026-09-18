#!/usr/bin/env bash
# ============================================================
# Gen-Modelle: Prüfbericht (LTX-2.5 + Qwen-Image/-Edit)
# Repo: kuberqu/templates/runpod/gen_report.sh
#
# Prüft die generativen Modelle, die setup.sh als zweite parallele Phase lädt.
# WICHTIG: Größen werden mit `stat -L` ermittelt — ohne -L liefert stat die
# Länge des SYMLINKS (~100 Byte) und meldet jedes Modell fälschlich als 0 MB.
#
# Aufruf: bash /workspace/gen_report.sh   → Exit 0 = alles grün
# ============================================================
set -uo pipefail
BASE=/workspace
MODELS="$BASE/ComfyUI/models"
STATUS="$BASE/gen_models_status.json"

ok=0; warn=0; fail=0
c_ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; ok=$((ok+1)); }
c_warn() { printf '\033[33m⚠ %s\033[0m\n' "$*"; warn=$((warn+1)); }
c_err()  { printf '\033[31m✗ %s\033[0m\n' "$*"; fail=$((fail+1)); }

# prüft eine Datei: <pfad> <mindest-MB> <label>
check() {
    local path="$1" min_mb="$2" label="$3" size
    if [ ! -e "$path" ]; then c_err "$label fehlt ($path)"; return; fi
    size=$(( $(stat -L -c %s "$path" 2>/dev/null || echo 0) / 1048576 ))
    if [ "$size" -ge "$min_mb" ]; then c_ok "$label (${size} MB)"
    else c_err "$label zu klein (${size} MB, erwartet ≥${min_mb} MB)"; fi
}

echo "=== Gen-Modelle: Prüfbericht $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo
echo "--- Download-Status (setup.sh Phase 2) ---"
if [ -s "$STATUS" ]; then cat "$STATUS"; else c_warn "keine $STATUS (Phase nie gelaufen?)"; fi
echo
echo "--- LTX-2.5 (Video + Audio) ---"
check "$MODELS/diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors" 10000 "LTX-2.5 Modell (int8)"
check "$MODELS/text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors" 5000 "Gemma4-12B Textencoder"
check "$MODELS/vae/ltx-2.5-video-vae-bf16.safetensors" 500 "LTX Video-VAE"
check "$MODELS/vae/ltx-2.5-audio-vae-bf16.safetensors" 100 "LTX Audio-VAE"
check "$MODELS/latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors" 300 "Spatial-Upscaler x2"
check "$MODELS/latent_upscale_models/ltx-2.5-latent-temporal-upscaler-x2-bf16-1.0.safetensors" 50 "Temporal-Upscaler x2"
check "$MODELS/model_patches/ltx-2.5-duration-head-bf16.safetensors" 1 "Auto-Duration-Head"
echo
echo "--- Qwen-Image / Qwen-Image-Edit (Apache-2.0) ---"
check "$MODELS/diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors" 10000 "Qwen-Image 2512 (fp8)"
check "$MODELS/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors" 4000 "Qwen2.5-VL Textencoder"
check "$MODELS/vae/qwen_image_vae.safetensors" 100 "Qwen-Image VAE"
check "$MODELS/diffusion_models/qwen_image_edit_2511_int8_convrot.safetensors" 10000 "Qwen-Image-Edit 2511 (int8)"
check "$MODELS/loras/Qwen-Edit-2509-Multiple-angles.safetensors" 100 "LoRA: Multiple Angles"
echo
echo "--- Reste abgebrochener Downloads (.aria2) ---"
AR=$(find "$BASE/gen_models" -name "*.aria2" 2>/dev/null | wc -l)
if [ "$AR" -eq 0 ]; then c_ok "keine Kontroll-Dateien"
else
    for a in $(find "$BASE/gen_models" -name "*.aria2" 2>/dev/null); do
        t="${a%.aria2}"
        if [ -s "$t" ]; then c_warn "$(basename "$t"): .aria2-Rest, aber Datei vorhanden (Größe prüfen!)"
        else c_err "$(basename "$t"): unvollständig"; fi
    done
fi
echo
echo "--- Laufzeit ---"
echo "  Volume belegt: $(du -sh "$BASE" 2>/dev/null | cut -f1) (Staging $(du -sh "$BASE/gen_models" 2>/dev/null | cut -f1))"
nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu --format=csv,noheader | sed 's/^/  GPU: /'
if curl -sf -m 5 -o /dev/null http://127.0.0.1:8188/system_stats; then
    c_ok "ComfyUI antwortet auf 8188"
    N=$(curl -sf -m 10 http://127.0.0.1:8188/object_info 2>/dev/null | head -c 200000 | grep -o '"LTXV[^"]*"' | sort -u | wc -l)
    echo "     LTX-bezogene Nodes registriert: $N"
else
    c_err "ComfyUI antwortet nicht auf 8188"
fi
echo
echo "=== ERGEBNIS: $ok ok, $warn Warnungen, $fail Fehler ==="
[ "$fail" -eq 0 ] && echo "GEN-REPORT: ALLES GRÜN" || echo "GEN-REPORT: FEHLER VORHANDEN"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
