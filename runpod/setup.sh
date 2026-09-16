#!/usr/bin/env bash
# ============================================================
# High-Speed ComfyUI Setup Script (uv + aria2c + Parallelism)
# Repository: kuberqu/templates/runpod/setup.sh
# ============================================================
set -euo pipefail
export GIT_TERMINAL_PROMPT=0

source /workspace/venv/bin/activate
BASE_DIR="/workspace"
COMFY_DIR="$BASE_DIR/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"

LOG="/workspace/comfyui_setup.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date) Starting High-Speed Setup ==="

# ------------------------------------------------------------
# 1. ComfyUI Core klonen & Ordner vorbereiten
# ------------------------------------------------------------
echo "--> Klone / Aktualisiere ComfyUI Core..."
if [ ! -d "$COMFY_DIR/.git" ]; then
    rm -rf "$COMFY_DIR"
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
    (cd "$COMFY_DIR" && git pull)
fi

mkdir -p "$MODELS_DIR"/{checkpoints,vae,clip,loras,upscale_models,insightface/models,wav2lip,sadtalker,liveportrait,gfpgan,facexlib,diffusion_models}

# ------------------------------------------------------------
# 2. Download-Helfer (aria2c mit Fallback auf curl)
# ------------------------------------------------------------
fast_download() {
    local target="$1"
    local url="$2"
    if [ ! -s "$target" ]; then
        mkdir -p "$(dirname "$target")"
        echo "Lade $(basename "$target")..."
        if command -v aria2c >/dev/null 2>&1; then
            aria2c -q -c -x 16 -s 16 -k 1M \
                --header="User-Agent: Mozilla/5.0" \
                --check-certificate=false \
                -d "$(dirname "$target")" \
                -o "$(basename "$target")" "$url" || \
            curl -k -L -f -A "Mozilla/5.0" -o "$target" "$url"
        else
            curl -k -L -f -A "Mozilla/5.0" -o "$target" "$url"
        fi
    else
        echo "$(basename "$target") bereits vorhanden."
    fi
}

# ------------------------------------------------------------
# 3. Parallel-Task A: Modell-Downloads im Hintergrund
# ------------------------------------------------------------
download_models_background() {
    echo "--> [Background] Starte parallele Modell-Downloads..."

    # Wav2Lip
    fast_download "$MODELS_DIR/wav2lip/wav2lip.pth" "https://huggingface.co/camenduru/Wav2Lip/resolve/main/checkpoints/wav2lip.pth"
    fast_download "$MODELS_DIR/wav2lip/wav2lip_gan.pth" "https://huggingface.co/camenduru/Wav2Lip/resolve/main/checkpoints/wav2lip_gan.pth"
    fast_download "$MODELS_DIR/wav2lip/s3fd-619a316847.pth" "https://huggingface.co/camenduru/Wav2Lip/resolve/main/checkpoints/s3fd-619a316812.pth"

    # LivePortrait
    for file in appearance_feature_extractor.safetensors motion_extractor.safetensors spade_generator.safetensors warping_module.safetensors stitching_retargeting_module.safetensors landmark.onnx; do
        fast_download "$MODELS_DIR/liveportrait/$file" "https://huggingface.co/Kijai/LivePortrait_safetensors/resolve/main/$file"
    done

    # InsightFace Buffalo_L
    if [ ! -f "$MODELS_DIR/insightface/models/buffalo_l/det_10g.onnx" ]; then
        mkdir -p "$MODELS_DIR/insightface/models"
        curl -k -L -f -o "$MODELS_DIR/insightface/models/buffalo_l.zip" "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip"
        unzip -o -q "$MODELS_DIR/insightface/models/buffalo_l.zip" -d "$MODELS_DIR/insightface/models/buffalo_l"
        rm -f "$MODELS_DIR/insightface/models/buffalo_l.zip"
    fi

    # SadTalker
    fast_download "$MODELS_DIR/sadtalker/SadTalker_V0.0.2_256.safetensors" "https://huggingface.co/camenduru/SadTalker/resolve/main/new/checkpoints/SadTalker_V0.0.2_256.safetensors"
    fast_download "$MODELS_DIR/sadtalker/SadTalker_V0.0.2_512.safetensors" "https://huggingface.co/camenduru/SadTalker/resolve/main/new/checkpoints/SadTalker_V0.0.2_512.safetensors"
    fast_download "$MODELS_DIR/sadtalker/mapping_00109-model.pth.tar" "https://huggingface.co/vinthony/SadTalker/resolve/main/mapping_00109-model.pth.tar"
    fast_download "$MODELS_DIR/sadtalker/mapping_00229-model.pth.tar" "https://huggingface.co/vinthony/SadTalker/resolve/main/mapping_00229-model.pth.tar"

    # GFPGAN & FaceXLib
    fast_download "$MODELS_DIR/gfpgan/GFPGANv1.4.pth" "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth"
    fast_download "$MODELS_DIR/facexlib/detection_Resnet50_Final.pth" "https://github.com/xinntao/facexlib/releases/download/v0.1.0/detection_Resnet50_Final.pth"
    fast_download "$MODELS_DIR/facexlib/parsing_parsenet.pth" "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/parsing_parsenet.pth"

    # Diffusion & VAE
    fast_download "$MODELS_DIR/diffusion_models/ltx-video-2b-v0.9.5.safetensors" "https://huggingface.co/Lightricks/LTX-Video/resolve/main/ltx-video-2b-v0.9.5.safetensors"
    fast_download "$MODELS_DIR/vae/vae-ft-mse-840000-ema-pruned.safetensors" "https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors"

    echo "✓ [Background] Alle Modell-Downloads abgeschlossen."
}

download_models_background &
DOWNLOAD_PID=$!

# ------------------------------------------------------------
# 4. Parallel-Task B: Custom Nodes & Python-Pakete via uv
# ------------------------------------------------------------
echo "--> Installiere uv Package-Manager..."
pip install --no-cache-dir -q uv

NODES_DIR="$COMFY_DIR/custom_nodes"
mkdir -p "$NODES_DIR"

declare -A REPOS=(
    ["ComfyUI-LivePortrait"]="https://github.com/kijai/ComfyUI-LivePortrait.git"
    ["ComfyUI_wav2lip"]="https://github.com/ShmuelRonen/ComfyUI_wav2lip.git"
    ["Comfyui-SadTalker"]="https://github.com/haomole/Comfyui-SadTalker.git"
    ["ComfyUI-VideoHelperSuite"]="https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
    ["ComfyUI-GGUF"]="https://github.com/city96/ComfyUI-GGUF.git"
)

echo "--> Klone Custom Nodes parallel..."
CLONE_PIDS=()
for name in "${!REPOS[@]}"; do
    if [ ! -d "$NODES_DIR/$name" ]; then
        git clone --depth 1 "${REPOS[$name]}" "$NODES_DIR/$name" &
        CLONE_PIDS+=($!)
    fi
done

if [ ${#CLONE_PIDS[@]} -gt 0 ]; then
    wait "${CLONE_PIDS[@]}"
fi

if [ -f "$NODES_DIR/Comfyui-SadTalker/requirements.txt" ]; then
    sed -i 's/==/>=/g' "$NODES_DIR/Comfyui-SadTalker/requirements.txt"
    sed -i '/numpy/d' "$NODES_DIR/Comfyui-SadTalker/requirements.txt"
fi

echo "--> Installiere Python-Abhängigkeiten via uv..."
# Torch auf CUDA 12.8 pinnen (Driver im Template = 570.195.03, max. CUDA 12.8)
uv pip install \
    "torch==2.9.0+cu128" \
    "torchvision==0.24.0+cu128" \
    "torchaudio==2.9.0+cu128" \
    --extra-index-url https://download.pytorch.org/whl/cu128
uv pip install -r "$COMFY_DIR/requirements.txt"
for req in "$NODES_DIR"/*/requirements.txt; do
    [ -f "$req" ] && uv pip install -r "$req" || true
done

uv pip install insightface onnxruntime soundfile scipy "librosa<0.11" "tifffile<2024.5" "numpy==1.26.4"

# ------------------------------------------------------------
# 5. Runtime Patches (BasicsR, Wav2Lip, SadTalker)
# ------------------------------------------------------------
echo "--> Wende Runtime-Patches an..."

# BasicsR torchvision Fix (direkt über Dateisystem ohne Python-Import)
find /workspace/venv -path "*/basicsr/data/degradations.py" -exec sed -i 's|from torchvision.transforms.functional_tensor import rgb_to_grayscale|from torchvision.transforms.functional import rgb_to_grayscale|g' {} + 2>/dev/null || true
echo "✓ BasicsR Degradations gepatcht."

# Wav2Lip torchaudio / soundfile Fix
W2L_NODE="$NODES_DIR/ComfyUI_wav2lip/wav2lip.py"
if [ -f "$W2L_NODE" ]; then
    python3 -c '
path = "'"$W2L_NODE"'"
with open(path, "r") as f:
    code = f.read()
old = "torchaudio.save(temp_audio_path, waveform_tensor, sample_rate)"
new = "import soundfile as _sf\n            _sf.write(temp_audio_path, waveform_tensor.squeeze(0).cpu().numpy(), sample_rate)"
if old in code:
    with open(path, "w") as f:
        f.write(code.replace(old, new))
'
    echo "✓ Wav2Lip Soundfile-Export gepatcht."
fi

# SadTalker ShowVideo extra_pnginfo None-Fix
SHOWVIDEO="$NODES_DIR/Comfyui-SadTalker/nodes/ShowVideo.py"
if [ -f "$SHOWVIDEO" ]; then
    sed -i 's|if unique_id and extra_pnginfo and "workflow" in extra_pnginfo\[0\]:|if unique_id and extra_pnginfo and isinstance(extra_pnginfo[0], dict) and "workflow" in extra_pnginfo[0]:|' "$SHOWVIDEO"
    echo "✓ ShowVideo API-Modus gepatcht."
fi

# ------------------------------------------------------------
# 6. Synchronisation & Checkpoint Symlinks
# ------------------------------------------------------------
echo "--> Warte auf Fertigstellung der Modell-Downloads..."
wait "$DOWNLOAD_PID"

mkdir -p "$NODES_DIR/ComfyUI_wav2lip/Wav2Lip/checkpoints" "$NODES_DIR/Comfyui-SadTalker/SadTalker/checkpoints"
ln -sf "$MODELS_DIR"/wav2lip/* "$NODES_DIR/ComfyUI_wav2lip/Wav2Lip/checkpoints/" 2>/dev/null || true
ln -sf "$MODELS_DIR"/sadtalker/* "$NODES_DIR/Comfyui-SadTalker/SadTalker/checkpoints/" 2>/dev/null || true
ln -sfn "$MODELS_DIR/liveportrait" "$NODES_DIR/ComfyUI-LivePortrait/pretrained_weights" 2>/dev/null || true
ln -sfn "$MODELS_DIR/insightface" "$NODES_DIR/ComfyUI-LivePortrait/insightface" 2>/dev/null || true

echo "=== SETUP ERFOLGREICH BEENDET ==="
