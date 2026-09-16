#!/usr/bin/env bash
# ============================================================
# RunPod Master Entrypoint (Dynamic Setup Loader + Fast-Boot)
# Repository: kuberqu/templates/runpod/entrypoint.sh
# ============================================================
set -euo pipefail
export GIT_TERMINAL_PROMPT=0

SETUP_URL="https://raw.githubusercontent.com/kuberqu/templates/main/runpod/setup.sh"

DEFAULT_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... deinkey@beispiel"
USER_KEY="${PUBLIC_KEY:-${SSH_PUBLIC_KEY:-$DEFAULT_SSH_KEY}}"

LOG="/workspace/comfyui_boot.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date) Initialisiere Pod-Umgebung ==="

# ------------------------------------------------------------
# 1. SSH-Dienst & Key Injection
# ------------------------------------------------------------
echo "--> Konfiguriere SSH..."
ssh-keygen -A >/dev/null 2>&1 || true
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys

if [ -n "$USER_KEY" ] && [[ "$USER_KEY" != *"AAAAC3NzaC1lZDI1NTE5AAAAI..."* ]]; then
    if ! grep -qF "$USER_KEY" /root/.ssh/authorized_keys; then
        echo "$USER_KEY" >> /root/.ssh/authorized_keys
        echo "✓ SSH-Key hinterlegt."
    fi
fi

if ! pgrep -x "sshd" >/dev/null 2>&1; then
    service ssh start >/dev/null 2>&1 || /usr/sbin/sshd >/dev/null 2>&1 || true
    echo "✓ SSH-Daemon gestartet."
fi

# ------------------------------------------------------------
# 2. DNS & Flüchtige Systempakete nachinstallieren
# ------------------------------------------------------------
if ! curl -s -I --connect-timeout 2 https://github.com >/dev/null 2>&1; then
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
fi

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v aria2c >/dev/null 2>&1 || ! dpkg -s libgl1 >/dev/null 2>&1; then
    echo "--> Installiere Basis- & Monitoring-Pakete (apt)..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        git curl wget aria2 ffmpeg unzip build-essential python3-venv \
        btop ncdu duf bat nvtop \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 openssh-server >/dev/null 2>&1 || true

    if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
        ln -sf /usr/bin/batcat /usr/local/bin/bat
    fi
fi

COMFY_DIR="/workspace/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"
VENV_DIR="/workspace/venv"

# ------------------------------------------------------------
# 3. Persistentes venv aktivieren
# ------------------------------------------------------------
if [ ! -d "$VENV_DIR" ]; then
    echo "--> Erstelle persistentes Virtual Environment in $VENV_DIR..."
    python3 -m venv --system-site-packages "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
grep -qF "/workspace/venv/bin/activate" /root/.bashrc || echo "source /workspace/venv/bin/activate" >> /root/.bashrc

# ------------------------------------------------------------
# 4. Erstinstallation via setup.sh / Fast-Repair nach Reset
# ------------------------------------------------------------
if [ ! -d "$COMFY_DIR" ] || [ ! -f "$MODELS_DIR/wav2lip/s3fd-619a316847.pth" ]; then
    echo "--> Lade setup.sh von GitHub nach..."
    curl -f -k -L "$SETUP_URL" -o /workspace/setup.sh
    chmod +x /workspace/setup.sh
    echo "--> Starte Erstinstallation..."
    /bin/bash /workspace/setup.sh
elif ! python3 -c "import alembic, sqlalchemy, scipy, insightface, soundfile" >/dev/null 2>&1; then
    echo "--> Fehlende Pakete nach Reset erkannt. Repariere via uv..."
    pip install --no-cache-dir -q uv
    uv pip install -r "$COMFY_DIR/requirements.txt"
    for req in "$COMFY_DIR"/custom_nodes/*/requirements.txt; do
        [ -f "$req" ] && uv pip install -r "$req" || true
    done
    uv pip install insightface onnxruntime soundfile scipy "librosa<0.11" "tifffile<2024.5" "numpy==1.26.4"
fi

echo "--> Workspace intakt. Führe Fast-Boot aus..."

# ------------------------------------------------------------
# 5. Laufzeit-Patches & Symlinks prüfen
# ------------------------------------------------------------
find /workspace/venv -path "*/basicsr/data/degradations.py" -exec sed -i 's|from torchvision.transforms.functional_tensor import rgb_to_grayscale|from torchvision.transforms.functional import rgb_to_grayscale|g' {} + 2>/dev/null || true

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
# 6. Server Start & Live-Verifikation
# ------------------------------------------------------------
echo "=== Starte ComfyUI Server ==="
pkill -9 -f "python.*main.py" 2>/dev/null || true
sleep 1

nohup python3 "$COMFY_DIR/main.py" --listen 0.0.0.0 --port 8188 > /workspace/comfyui_server.log 2>&1 &
SERVER_PID=$!

echo "--> Warte auf Serverbereitschaft (max. 180s für Migrationen)..."
SERVER_READY=false
for i in {1..180}; do
    if curl -s -f http://127.0.0.1:8188/object_info >/dev/null 2>&1; then
        SERVER_READY=true
        break
    fi
    sleep 1
done

if [ "$SERVER_READY" = false ]; then
    echo "FEHLER: Server antwortet nach 180s nicht. Letzte Logs:"
    tail -n 30 /workspace/comfyui_server.log
    exit 1
fi

echo "--> Verifiziere LipSync-Nodes..."
curl -s -f http://127.0.0.1:8188/object_info | python3 -c "
import sys, json
data = json.load(sys.stdin)
required = ['Wav2Lip', 'SadTalker', 'LivePortraitProcess']
missing = [n for n in required if n not in data]
if missing:
    sys.exit(f'WARNUNG: Folgende Nodes wurden nicht registriert: {missing}')
print('✓ Alle Kern-LipSync-Nodes erfolgreich geladen:', required)
"

echo "✓ ComfyUI läuft stabil auf Port 8188."

if [ "${RUN_IN_BACKGROUND:-false}" != "true" ]; then
    wait "$SERVER_PID"
fi
