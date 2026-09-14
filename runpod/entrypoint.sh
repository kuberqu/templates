#!/usr/bin/env bash
# ============================================================
# RunPod Master Entrypoint: ComfyUI LipSync Suite (Persistent venv)
# Repository: kuberqu/templates/runpod/entrypoint.sh
# ============================================================
set -euo pipefail
export GIT_TERMINAL_PROMPT=0

# Optional: Trage hier deinen Key als Fallback ein
DEFAULT_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... deinkey@beispiel"
PUBLIC_KEY="${SSH_PUBLIC_KEY:-$DEFAULT_SSH_KEY}"

LOG="/workspace/comfyui_boot.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date) Initialisiere Pod-Umgebung ==="

# ------------------------------------------------------------
# 1. SSH-Key Injection (/root/.ssh/authorized_keys)
# ------------------------------------------------------------
if [ -n "$PUBLIC_KEY" ] && [[ "$PUBLIC_KEY" != *"AAAAC3NzaC1lZDI1NTE5AAAAI..."* ]]; then
    echo "--> Konfiguriere SSH-Zugriff..."
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
    if ! grep -qF "$PUBLIC_KEY" /root/.ssh/authorized_keys; then
        echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
        echo "✓ SSH-Key hinterlegt."
    fi
    if command -v service >/dev/null 2>&1 && service ssh status >/dev/null 2>&1; then
        service ssh start >/dev/null 2>&1 || true
    fi
fi

# ------------------------------------------------------------
# 2. DNS-Sicherheit & Flüchtige Systempakete
# ------------------------------------------------------------
if ! curl -s -I --connect-timeout 2 https://github.com >/dev/null 2>&1; then
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
fi

if ! command -v ffmpeg >/dev/null 2>&1 || ! dpkg -s libgl1 >/dev/null 2>&1; then
    echo "--> Installiere Systembibliotheken..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        git curl wget ffmpeg unzip build-essential python3-venv \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 openssh-server >/dev/null 2>&1
fi

COMFY_DIR="/workspace/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"
VENV_DIR="/workspace/venv"

# ------------------------------------------------------------
# 3. Persistente Python-Umgebung (venv)
# ------------------------------------------------------------
if [ ! -d "$VENV_DIR" ]; then
    echo "--> Erstelle persistentes Virtual Environment in $VENV_DIR..."
    python3 -m venv --system-site-packages "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

# venv automatisch in interaktiven Shells laden
grep -qF "/workspace/venv/bin/activate" /root/.bashrc || echo "source /workspace/venv/bin/activate" >> /root/.bashrc

# ------------------------------------------------------------
# 4. setup.sh automatisch generieren (falls nicht vorhanden)
# ------------------------------------------------------------
if [ ! -f "/workspace/setup.sh" ]; then
    echo "--> Erzeuge /workspace/setup.sh..."
    cat << 'EOF_SETUP' > /workspace/setup.sh
#!/usr/bin/env bash
set -euo pipefail
export GIT_TERMINAL_PROMPT=0

source /workspace/venv/bin/activate
BASE_DIR="/workspace"
COMFY_DIR="$BASE_DIR/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"

LOG="/var/log/comfyui_setup.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date) Starting ComfyUI LipSync Setup ==="

# ComfyUI Core
if [ ! -d "$COMFY_DIR" ]; then
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
    (cd "$COMFY_DIR" && git pull)
fi

echo "--> Installiere ComfyUI Abhängigkeiten..."
pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt"

# Nodes
NODES_DIR="$COMFY_DIR/custom_nodes"
mkdir -p "$NODES_DIR"

install_node() {
    local repo_url="$1"
    local dir_name="$2"
    echo "--> Installing / Updating $dir_name..."
    if [ ! -d "$NODES_DIR/$dir_name" ]; then
        git clone "$repo_url" "$NODES_DIR/$dir_name"
    else
        (cd "$NODES_DIR/$dir_name" && git pull)
    fi

    if [ "$dir_name" = "Comfyui-SadTalker" ] && [ -f "$NODES_DIR/$dir_name/requirements.txt" ]; then
        sed -i 's/==/>=/g' "$NODES_DIR/$dir_name/requirements.txt"
        sed -i '/numpy/d' "$NODES_DIR/$dir_name/requirements.txt"
    fi

    if [ -f "$NODES_DIR/$dir_name/requirements.txt" ]; then
        pip install --no-cache-dir -r "$NODES_DIR/$dir_name/requirements.txt" || true
    fi
}

install_node "https://github.com/kijai/ComfyUI-LivePortrait.git" "ComfyUI-LivePortrait"
install_node "https://github.com/ShmuelRonen/ComfyUI_wav2lip.git" "ComfyUI_wav2lip"
install_node "https://github.com/haomole/Comfyui-SadTalker.git" "Comfyui-SadTalker"
install_node "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" "ComfyUI-VideoHelperSuite"
install_node "https://github.com/city96/ComfyUI-GGUF.git" "ComfyUI-GGUF"

pip install --no-cache-dir "librosa<0.11" "tifffile<2024.5" "numpy==1.26.4"

# Models
mkdir -p "$MODELS_DIR"/{checkpoints,vae,clip,loras,upscale_models,insightface/models,wav2lip,sadtalker,liveportrait,gfpgan,facexlib,diffusion_models}

download_file() {
    local target="$1"
    local url1="$2"
    local url2="${3:-}"
    if [ ! -s "$target" ]; then
        echo "Lade $(basename "$target")..."
        curl -k -L -f -A "Mozilla/5.0" -o "$target" "$url1" 2>/dev/null || \
        ([ -n "$url2" ] && curl -k -L -f -A "Mozilla/5.0" -o "$target" "$url2") || \
        { echo "Fehler beim Download von $(basename "$target")"; return 1; }
    else
        echo "$(basename "$target") bereits vorhanden."
    fi
}

# 3a. Wav2Lip
download_file "$MODELS_DIR/wav2lip/wav2lip.pth" "https://huggingface.co/camenduru/Wav2Lip/resolve/main/checkpoints/wav2lip.pth" "https://huggingface.co/numz/wav2lip_uhq/resolve/main/wav2lip.pth"
download_file "$MODELS_DIR/wav2lip/wav2lip_gan.pth" "https://huggingface.co/camenduru/Wav2Lip/resolve/main/checkpoints/wav2lip_gan.pth" "https://huggingface.co/numz/wav2lip_uhq/resolve/main/wav2lip_gan.pth"
download_file "$MODELS_DIR/wav2lip/s3fd-619a316847.pth" "https://huggingface.co/camenduru/Wav2Lip/resolve/main/checkpoints/s3fd-619a316812.pth"

# 3b. LivePortrait
for file in appearance_feature_extractor.safetensors motion_extractor.safetensors spade_generator.safetensors warping_module.safetensors stitching_retargeting_module.safetensors landmark.onnx; do
    download_file "$MODELS_DIR/liveportrait/$file" "https://huggingface.co/Kijai/LivePortrait_safetensors/resolve/main/$file"
done

if [ ! -f "$MODELS_DIR/insightface/models/buffalo_l/det_10g.onnx" ]; then
    curl -L -f -o "$MODELS_DIR/insightface/models/buffalo_l.zip" "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip"
    unzip -o -q "$MODELS_DIR/insightface/models/buffalo_l.zip" -d "$MODELS_DIR/insightface/models/buffalo_l"
    rm -f "$MODELS_DIR/insightface/models/buffalo_l.zip"
fi

# 3c. SadTalker
download_file "$MODELS_DIR/sadtalker/SadTalker_V0.0.2_256.safetensors" "https://huggingface.co/camenduru/SadTalker/resolve/main/new/checkpoints/SadTalker_V0.0.2_256.safetensors"
download_file "$MODELS_DIR/sadtalker/SadTalker_V0.0.2_512.safetensors" "https://huggingface.co/camenduru/SadTalker/resolve/main/new/checkpoints/SadTalker_V0.0.2_512.safetensors"
download_file "$MODELS_DIR/sadtalker/mapping_00109-model.pth.tar" "https://huggingface.co/vinthony/SadTalker/resolve/main/mapping_00109-model.pth.tar"
download_file "$MODELS_DIR/sadtalker/mapping_00229-model.pth.tar" "https://huggingface.co/vinthony/SadTalker/resolve/main/mapping_00229-model.pth.tar"

# 3d. GFPGAN & FaceXLib
download_file "$MODELS_DIR/gfpgan/GFPGANv1.4.pth" "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth"
download_file "$MODELS_DIR/facexlib/detection_Resnet50_Final.pth" "https://github.com/xinntao/facexlib/releases/download/v0.1.0/detection_Resnet50_Final.pth"
download_file "$MODELS_DIR/facexlib/parsing_parsenet.pth" "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/parsing_parsenet.pth" "https://github.com/xinntao/facexlib/releases/download/v0.2.2/parsing_parsenet.pth"

# 3e. Video & Checkpoints
download_file "$MODELS_DIR/diffusion_models/ltx-video-2b-v0.9.5.safetensors" "https://huggingface.co/Lightricks/LTX-Video/resolve/main/ltx-video-2b-v0.9.5.safetensors"
download_file "$MODELS_DIR/vae/vae-ft-mse-840000-ema-pruned.safetensors" "https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors"

echo "=== SETUP ABGESCHLOSSEN ==="
EOF_SETUP
    chmod +x /workspace/setup.sh
fi

# ------------------------------------------------------------
# 5. Installationsprüfung & Environment-Check
# ------------------------------------------------------------
if [ ! -d "$COMFY_DIR" ] || [ ! -f "$MODELS_DIR/wav2lip/s3fd-619a316847.pth" ]; then
    echo "--> Erstinstallation erforderlich. Führe setup.sh aus..."
    /bin/bash /workspace/setup.sh
elif ! python3 -c "import alembic, sqlalchemy" >/dev/null 2>&1; then
    echo "--> Fehlende Pip-Pakete nach Container-Reset. Installiere nach..."
    pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt"
    for req in "$COMFY_DIR"/custom_nodes/*/requirements.txt; do
        [ -f "$req" ] && pip install --no-cache-dir -r "$req" || true
    done
    pip install --no-cache-dir "librosa<0.11" "tifffile<2024.5" "numpy==1.26.4"
fi

echo "--> Workspace intakt. Führe Fast-Boot aus..."

# ------------------------------------------------------------
# 6. Runtime-Patches & Symlinks
# ------------------------------------------------------------
BASICSR_DEG=$(python3 -c "import basicsr, os; print(os.path.join(os.path.dirname(basicsr.__file__), 'data', 'degradations.py'))" 2>/dev/null || true)
if [ -n "$BASICSR_DEG" ] && [ -f "$BASICSR_DEG" ]; then
    sed -i "s/from torchvision.transforms.functional_tensor import rgb_to_grayscale/from torchvision.transforms.functional import rgb_to_grayscale/g" "$BASICSR_DEG"
fi

WAV2LIP_PATH="$COMFY_DIR/custom_nodes/ComfyUI_wav2lip"
SADTALKER_PATH="$COMFY_DIR/custom_nodes/Comfyui-SadTalker"

mkdir -p "$WAV2LIP_PATH/Wav2Lip/checkpoints" "$SADTALKER_PATH/SadTalker/checkpoints"
ln -sf "$MODELS_DIR"/wav2lip/* "$WAV2LIP_PATH/Wav2Lip/checkpoints/" 2>/dev/null || true
ln -sf "$MODELS_DIR"/sadtalker/* "$SADTALKER_PATH/SadTalker/checkpoints/" 2>/dev/null || true
ln -sfn "$MODELS_DIR/liveportrait" "$COMFY_DIR/custom_nodes/ComfyUI-LivePortrait/pretrained_weights" 2>/dev/null || true
ln -sfn "$MODELS_DIR/insightface" "$COMFY_DIR/custom_nodes/ComfyUI-LivePortrait/insightface" 2>/dev/null || true

FACEXLIB_DIR=$(python3 -c "import facexlib, os; print(os.path.dirname(facexlib.__file__))" 2>/dev/null || true)
GFPGAN_DIR=$(python3 -c "import gfpgan, os; print(os.path.dirname(gfpgan.__file__))" 2>/dev/null || true)
[ -n "$FACEXLIB_DIR" ] && mkdir -p "$FACEXLIB_DIR/weights" && ln -sf "$MODELS_DIR"/facexlib/* "$FACEXLIB_DIR/weights/" 2>/dev/null || true
[ -n "$GFPGAN_DIR" ] && mkdir -p "$GFPGAN_DIR/weights" && ln -sf "$MODELS_DIR/gfpgan/GFPGANv1.4.pth" "$GFPGAN_DIR/weights/" 2>/dev/null || true

# ------------------------------------------------------------
# 7. Server Start
# ------------------------------------------------------------
echo "=== Starte ComfyUI Server ==="
pkill -f "python.*main.py" || true

if [ "${RUN_IN_BACKGROUND:-false}" = "true" ]; then
    nohup python3 "$COMFY_DIR/main.py" --listen 0.0.0.0 --port 8188 > /workspace/comfyui_server.log 2>&1 &
    echo "✓ ComfyUI im Hintergrund gestartet (Port 8188)."
else
    exec python3 "$COMFY_DIR/main.py" --listen 0.0.0.0 --port 8188
fi
