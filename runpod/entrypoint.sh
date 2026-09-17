#!/usr/bin/env bash
# ============================================================
# RunPod Master Entrypoint (Dynamic Setup Loader + Fast-Boot)
# Repository: kuberqu/templates/runpod/entrypoint.sh
# ============================================================
set -euo pipefail
export GIT_TERMINAL_PROMPT=0

SETUP_URL="https://raw.githubusercontent.com/kuberqu/templates/main/runpod/setup.sh"

DEFAULT_SSH_KEY=*** AAAAC3NzaC1lZDI1NTE5AAAAI... deinkey@beispiel"
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
# 2. DNS & Systempakete (inkl. Remotion/Chromium Libs)
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
 libnspr4 libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
 libgbm1 libasound2t64 libpango-1.0-0 libcairo2 libatspi2.0-0 libxshmfence1 \
 fonts-liberation libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 openssh-server >/dev/null 2>&1 || true

 if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
 ln -sf /usr/bin/batcat /usr/local/bin/bat
 fi
fi

COMFY_DIR="/workspace/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"
VENV_DIR="/workspace/venv"

# ------------------------------------------------------------
# 3. Persistentes venv aktivieren (OHNE --system-site-packages!)
# ------------------------------------------------------------
if [ ! -d "$VENV_DIR" ]; then
 echo "--> Erstelle persistentes Virtual Environment in $VENV_DIR..."
 python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

# ------------------------------------------------------------
# 4. Setup.sh laden & ausführen (idempotent, nur beim ersten Boot)
# ------------------------------------------------------------
if [ ! -f "/workspace/comfyui_setup.log" ] || ! grep -q "SETUP ERFOLGREICH BEENDET" /workspace/comfyui_setup.log; then
 echo "--> Lade und führe setup.sh aus..."
 curl -fsSL "$SETUP_URL" -o /workspace/setup.sh
 chmod +x /workspace/setup.sh
 /workspace/setup.sh
else
 echo "✓ Setup bereits durchgeführt — überspringe."
fi

# ------------------------------------------------------------
# 5. Fast-Boot: ComfyUI starten (einmalig, nach Setup)
# ------------------------------------------------------------
echo "=== Starte ComfyUI Server (Fast-Boot) ==="
cd /workspace

# Prüfen ob schon läuft (PID-Datei vermeiden Doppelstart)
if pgrep -f "ComfyUI/main.py" >/dev/null 2>&1; then
 echo "⚠ ComfyUI läuft bereits — überspringe Start."
else
 nohup ./venv/bin/python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188 >> /workspace/comfyui_boot.log 2>&1 < /dev/null &
 COMFY_PID=$!
 echo "✓ ComfyUI gestartet (PID $COMFY_PID), warte auf Bereitschaft..."

 # Warte auf HTTP-Readiness (max 180s)
 for i in {1..36}; do
   if curl -sf -m 5 http://127.0.0.1:8188/system_stats >/dev/null 2>&1; then
     echo "✓ ComfyUI HTTP erreichbar"
     break
   fi
   sleep 5
 done

 # Verifikation: LipSync-Nodes + mediapipe
 echo "--> Verifiziere LipSync-Nodes..."
 if curl -sf -m 30 http://127.0.0.1:8188/object_info | /workspace/venv/bin/python -c "
import sys, json
data = json.load(sys.stdin)
required = ['Wav2Lip', 'SadTalker', 'LivePortraitProcess', 'LivePortraitCropper', 'LivePortraitComposite', 'LivePortraitRetargeting']
missing = [n for n in required if n not in data]
if missing:
    print('FEHLEND:', missing)
    sys.exit(1)
print('✓ Alle LipSync-Nodes registriert:', [n for n in required if n in data])
"; then
   echo "✓ Node-Verifikation OK"
 else
   echo "✗ Node-Verifikation FEHLGESCHLAGEN"
   exit 1
 fi

 /workspace/venv/bin/python -c "
import mediapipe
from mediapipe.framework.formats import landmark_pb2
print('✓ mediapipe framework.formats Import OK')
"
fi

echo "=== Pod bereit ==="
