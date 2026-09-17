#!/usr/bin/env bash
# ============================================================
# RunPod Master Entrypoint (Dynamic Setup Loader + Fast-Boot)
# Repo: kuberqu/templates/runpod/entrypoint.sh
#
# Läuft bei JEDEM Pod-Start (wird vom Container-Kommando von GitHub geladen).
# Aufgaben:
#   1. SSH + DNS + Systempakete (auch Chromium-Libs für Remotion)
#   2. venv sicherstellen
#   3. IMMER die aktuelle setup.sh von GitHub holen (lokale Kopie als Fallback)
#   4. Nur wenn der Zustand kaputt/unvollständig ist: setup.sh ausführen
#      -> Zustandsprüfung ist eine echte Import-Prüfung, nicht nur "Datei da"
#   5. Runtime-Patches + Symlinks (idempotent, billig)
#   6. ComfyUI GENAU EINMAL starten, auf Bereitschaft warten,
#      LipSync-Nodes verifizieren, Status nach /workspace/lipsync_status.json
#
# Wichtig: KEIN `set -e` — ein fehlgeschlagener Teilschritt darf den Pod
# nicht unbenutzbar machen; Fehler werden laut geloggt und im Statusfile
# festgehalten.
# ============================================================
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
export DEBIAN_FRONTEND=noninteractive

# Hinweis: Setup-/Test-Skripte werden NICHT über raw.githubusercontent.com geholt
# (CDN mit max-age=300 liefert bis zu 5 Minuten den alten Stand, Query-Strings als
# Cache-Buster werden ignoriert). Stattdessen codeload-Tarball, Fallback GitHub-API
# — siehe Schritt "Skripte aktualisieren" weiter unten.
REPO_TARBALL="https://codeload.github.com/kuberqu/templates/tar.gz/refs/heads/main"

BASE_DIR="/workspace"
VENV_DIR="$BASE_DIR/venv"
COMFY_DIR="$BASE_DIR/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"
NODES_DIR="$COMFY_DIR/custom_nodes"
OM_DIR="$BASE_DIR/OpenMontage"
LOG="$BASE_DIR/comfyui_boot.log"
SERVER_LOG="$BASE_DIR/comfyui_server.log"
PIDFILE="$BASE_DIR/.comfyui.pid"
STATUS_FILE="$BASE_DIR/lipsync_status.json"

mkdir -p "$BASE_DIR"
exec > >(tee -a "$LOG") 2>&1

c_ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
c_err()  { printf '\033[31m✗ %s\033[0m\n' "$*"; }
step()   { printf '\n--- %s ---\n' "$*"; }

# Zeitmessung: macht Boot-Tests vergleichbar (Fast-Boot vs. Volleinrichtung)
BOOT_T0=$(date +%s)
dur() { echo "$(( $(date +%s) - ${1:-$BOOT_T0} ))"; }

echo "=== $(date -u '+%Y-%m-%d %H:%M:%S UTC') Initialisiere Pod-Umgebung ==="

# ------------------------------------------------------------
# 1. SSH
# ------------------------------------------------------------
step "SSH"
ssh-keygen -A >/dev/null 2>&1 || true
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys

# Nur echte Keys aufnehmen — kein Platzhalter-Default (der würde bei fehlendem
# PUBLIC_KEY einen ungültigen Key schreiben).
for k in "${PUBLIC_KEY:-}" "${SSH_PUBLIC_KEY:-}"; do
    if [ -n "${k:-}" ] && ! grep -qF "$k" /root/.ssh/authorized_keys; then
        echo "$k" >> /root/.ssh/authorized_keys
        c_ok "SSH-Key hinterlegt"
    fi
done

if ! pgrep -x sshd >/dev/null 2>&1; then
    service ssh start >/dev/null 2>&1 || /usr/sbin/sshd >/dev/null 2>&1 || true
    pgrep -x sshd >/dev/null 2>&1 && c_ok "SSH-Daemon läuft" || c_err "SSH-Daemon Start fehlgeschlagen"
fi

# ------------------------------------------------------------
# 2. DNS
# ------------------------------------------------------------
if ! curl -s -I --connect-timeout 3 https://github.com >/dev/null 2>&1; then
    c_warn "DNS/GitHub nicht erreichbar — setze Resolver"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi

# ------------------------------------------------------------
# 3. Systempakete (Basis + Chromium-Libs für Remotion)
#    Chromium-Libs sind nötig, sonst: libnspr4.so not found / exit 127
# ------------------------------------------------------------
step "Systempakete"
CHROME_LIBS="libnspr4 libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2
             libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1
             libasound2t64 libpango-1.0-0 libcairo2 libatspi2.0-0 libxshmfence1 fonts-liberation"

need_apt=0
command -v ffmpeg  >/dev/null 2>&1 || need_apt=1
command -v aria2c  >/dev/null 2>&1 || need_apt=1
command -v git     >/dev/null 2>&1 || need_apt=1
dpkg -s libgl1     >/dev/null 2>&1 || need_apt=1
dpkg -s libnspr4   >/dev/null 2>&1 || need_apt=1

if [ "$need_apt" = "1" ]; then
    echo "--> apt-get update + install (Basis + Chromium-Libs)..."
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        git curl wget aria2 ffmpeg unzip build-essential python3-venv \
        btop ncdu duf bat nvtop \
        $CHROME_LIBS \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 openssh-server >/dev/null 2>&1 \
        && c_ok "Systempakete installiert" \
        || c_warn "apt-Install unvollständig (non-fatal)"
    command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1 && ln -sf /usr/bin/batcat /usr/local/bin/bat
else
    c_ok "Systempakete vorhanden"
fi

# ------------------------------------------------------------
# 4. venv
# ------------------------------------------------------------
step "venv"
if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "--> Erstelle persistentes venv: $VENV_DIR"
    python3 -m venv --system-site-packages "$VENV_DIR" || c_err "venv-Erstellung fehlgeschlagen"
fi
[ -x "$VENV_DIR/bin/python" ] && c_ok "venv: $("$VENV_DIR/bin/python" -V)"
grep -qF "source $VENV_DIR/bin/activate" /root/.bashrc 2>/dev/null \
    || echo "source $VENV_DIR/bin/activate" >> /root/.bashrc

# ------------------------------------------------------------
# 5. Zustandsprüfung — echte Import-Prüfung statt "Datei existiert"
# ------------------------------------------------------------
venv_ok() {
    "$VENV_DIR/bin/python" - <<'PYEOF' >/dev/null 2>&1
import torch, numpy, mediapipe, soundfile, insightface, onnxruntime
from mediapipe.framework.formats import landmark_pb2  # noqa
assert torch.cuda.is_available(), "CUDA nicht verfügbar"
assert mediapipe.__version__ == "0.10.21", f"mediapipe {mediapipe.__version__}"
assert numpy.__version__.startswith("1.26"), f"numpy {numpy.__version__}"
assert onnxruntime.get_available_providers(), "onnxruntime ohne Provider"
PYEOF
}

models_ok() {
    [ -s "$MODELS_DIR/wav2lip/s3fd-619a316847.pth" ] \
    && [ -s "$MODELS_DIR/liveportrait/landmark.onnx" ] \
    && [ -s "$MODELS_DIR/sadtalker/SadTalker_V0.0.2_256.safetensors" ]
}

nodes_ok() {
    [ -d "$NODES_DIR/ComfyUI-LivePortrait" ] && [ -d "$NODES_DIR/ComfyUI_wav2lip" ] && [ -d "$NODES_DIR/Comfyui-SadTalker" ]
}

# ------------------------------------------------------------
# Skripte aktualisieren
# WICHTIG: NICHT mehr über raw.githubusercontent.com! Das liefert mit
#   cache-control: max-age=300   (x-cache: HIT, via: varnish)
# bis zu 5 Minuten lang den ALTEN Stand, und Query-Strings als Cache-Buster
# werden ignoriert -> ein Boot kurz nach einem Push lief schon mit veraltetem
# setup.sh. codeload.github.com liefert dagegen immer den aktuellen Stand
# (komplettes Repo als Tarball, hier nur ~30 KB, ein einziger Request).
# ------------------------------------------------------------
REPO_TARBALL="${REPO_TARBALL:-https://codeload.github.com/kuberqu/templates/tar.gz/refs/heads/main}"

fetch_repo_files() {
    # Holt alle runpod-Dateien frisch und legt sie in $1 ab. 0 = Erfolg.
    local dest="$1" tmpdir tarball f ok=0
    tmpdir=$(mktemp -d) || return 1
    tarball="$tmpdir/repo.tgz"
    if ! curl -fsSL -k --retry 3 --retry-delay 2 --connect-timeout 15 -o "$tarball" "$REPO_TARBALL" 2>/dev/null; then
        rm -rf "$tmpdir"; return 1
    fi
    for f in setup.sh boot_report.sh test_lp_smoke.py test_lipsync_smokes.py \
             test_lp_retargeting.py om_talking_head.py presenter_example.srt commands.md; do
        if tar -xzOf "$tarball" "templates-main/runpod/$f" > "$tmpdir/$f" 2>/dev/null && [ -s "$tmpdir/$f" ]; then
            ok=$((ok + 1))
        else
            rm -f "$tmpdir/$f"
        fi
    done
    if [ "$ok" -eq 0 ]; then rm -rf "$tmpdir"; return 1; fi
    mv "$tmpdir"/* "$dest"/ 2>/dev/null || true
    rm -rf "$tmpdir"
    return 0
}

# Fallback 1: GitHub-API pro Datei (auch nicht CDN-gecacht, aber 60 Req/h)
fetch_via_api() {  # $1 = Dateiname, $2 = Ziel
    curl -fsSL -k --retry 2 --connect-timeout 15 \
        -H 'Accept: application/vnd.github.raw' \
        "https://api.github.com/repos/kuberqu/templates/contents/runpod/$1?ref=main" \
        -o "$2" 2>/dev/null && [ -s "$2" ]
}

step "Skripte aktualisieren"
STAGE=$(mktemp -d)
if fetch_repo_files "$STAGE"; then
    c_ok "Repo-Tarball geholt (codeload, immer aktuell)"
else
    c_warn "codeload nicht erreichbar — versuche GitHub-API"
    if fetch_via_api setup.sh "$STAGE/setup.sh"; then
        c_ok "setup.sh via GitHub-API geholt"
    else
        c_warn "Auch die API nicht erreichbar — behalte vorhandene Skripte"
    fi
fi

# setup.sh nur ersetzen, wenn sie syntaktisch heil ist
if [ -s "$STAGE/setup.sh" ] && bash -n "$STAGE/setup.sh" 2>/dev/null; then
    cp "$STAGE/setup.sh" "$BASE_DIR/setup.sh" && chmod +x "$BASE_DIR/setup.sh"
    c_ok "setup.sh aktualisiert ($(wc -l < "$BASE_DIR/setup.sh") Zeilen)"
elif [ -f "$BASE_DIR/setup.sh" ]; then
    c_warn "setup.sh nicht aktualisiert — nutze vorhandene ($(wc -l < "$BASE_DIR/setup.sh") Zeilen)"
else
    c_err "Keine setup.sh verfügbar!"
fi

# Diagnose-/Test-Skripte installieren (mit Syntaxprüfung, sonst alte behalten)
for t in boot_report.sh test_lp_smoke.py test_lipsync_smokes.py test_lp_retargeting.py \
         om_talking_head.py presenter_example.srt commands.md; do
    [ -s "$STAGE/$t" ] || continue
    case "$t" in
        *.py) "$VENV_DIR/bin/python" -m py_compile "$STAGE/$t" 2>/dev/null || { c_warn "$t: Syntaxprüfung fehlgeschlagen, behalte alte Version"; continue; } ;;
        *.sh) bash -n "$STAGE/$t" 2>/dev/null || { c_warn "$t: Syntaxprüfung fehlgeschlagen, behalte alte Version"; continue; } ;;
    esac
    cp "$STAGE/$t" "$BASE_DIR/$t" && chmod +x "$BASE_DIR/$t" 2>/dev/null || true
done
rm -rf "$STAGE"
c_ok "Diagnose-/Test-Skripte aktuell (boot_report.sh, Smokes, om_talking_head.py, commands.md)"

step "Zustandsprüfung"
NEED_SETUP=0
if [ ! -d "$COMFY_DIR/.git" ]; then echo "   ComfyUI fehlt"; NEED_SETUP=1; fi
if ! models_ok;  then echo "   Modelle unvollständig"; NEED_SETUP=1; fi
if ! nodes_ok;   then echo "   Custom Nodes fehlen"; NEED_SETUP=1; fi
if ! venv_ok;    then echo "   Python-Stack unvollständig/inkonsistent (Import-Prüfung fehlgeschlagen)"; NEED_SETUP=1; fi

if [ "$NEED_SETUP" = "1" ]; then
    echo "--> Setup/Reparatur wird ausgeführt (Log: $BASE_DIR/comfyui_setup.log)"
    SETUP_T0=$(date +%s)
    set +u
    INSTALL_OPENMONTAGE="${INSTALL_OPENMONTAGE:-1}" bash "$BASE_DIR/setup.sh"
    SETUP_RC=$?
    set -u
    SETUP_SECS=$(dur "$SETUP_T0")
    if [ "$SETUP_RC" = "0" ]; then
        c_ok "setup.sh erfolgreich (rc=0, ${SETUP_SECS}s)"
    else
        c_warn "setup.sh mit rc=$SETUP_RC beendet (${SETUP_SECS}s) — siehe comfyui_setup.log / setup_status.json"
    fi
    BOOT_MODE="full"

    # Gezielte Nachreparatur, falls nur die Pins gekippt sind
    if ! venv_ok; then
        c_warn "Stack weiterhin inkonsistent — erzwinge Pins (numpy 1.26.4 / mediapipe 0.10.21)"
        UV="$VENV_DIR/bin/uv"; [ -x "$UV" ] || UV="$(command -v uv || true)"
        if [ -n "$UV" ]; then
            "$UV" pip install --python "$VENV_DIR/bin/python" "numpy==1.26.4" "mediapipe==0.10.21" \
                && c_ok "Pins erzwungen" || c_err "Pin-Reparatur fehlgeschlagen"
        fi
    fi
else
    c_ok "Workspace intakt — Fast-Boot"
    BOOT_MODE="fast"
fi

# ------------------------------------------------------------
# 6. Patches + Symlinks (idempotent, bei jedem Start)
# ------------------------------------------------------------
step "Runtime-Patches & Symlinks"

while IFS= read -r f; do
    grep -q "functional_tensor" "$f" 2>/dev/null && \
        sed -i 's|from torchvision.transforms.functional_tensor import rgb_to_grayscale|from torchvision.transforms.functional import rgb_to_grayscale|g' "$f"
done < <(find "$VENV_DIR" -path "*/basicsr/data/degradations.py" 2>/dev/null)

W2L_NODE="$NODES_DIR/ComfyUI_wav2lip/wav2lip.py"
if [ -f "$W2L_NODE" ] && grep -q "torchaudio.save(temp_audio_path" "$W2L_NODE"; then
    sed -i 's|torchaudio.save(temp_audio_path, waveform_tensor, sample_rate)|import soundfile as _sf\n            _sf.write(temp_audio_path, waveform_tensor.squeeze(0).cpu().numpy(), sample_rate)|' "$W2L_NODE"
    grep -q "_sf.write(temp_audio_path" "$W2L_NODE" && c_ok "Wav2Lip-Patch" || c_warn "Wav2Lip-Patch fehlgeschlagen"
fi

SHOWVIDEO="$NODES_DIR/Comfyui-SadTalker/nodes/ShowVideo.py"
if [ -f "$SHOWVIDEO" ] && grep -q 'if unique_id and extra_pnginfo and "workflow" in extra_pnginfo\[0\]:' "$SHOWVIDEO"; then
    sed -i 's|if unique_id and extra_pnginfo and "workflow" in extra_pnginfo\[0\]:|if unique_id and extra_pnginfo and isinstance(extra_pnginfo[0], dict) and "workflow" in extra_pnginfo[0]:|' "$SHOWVIDEO"
    grep -q "isinstance(extra_pnginfo\[0\], dict)" "$SHOWVIDEO" && c_ok "ShowVideo-Patch" || c_warn "ShowVideo-Patch fehlgeschlagen"
fi

mkdir -p "$NODES_DIR/ComfyUI_wav2lip/Wav2Lip/checkpoints" \
         "$NODES_DIR/Comfyui-SadTalker/SadTalker/checkpoints"
ln -sf "$MODELS_DIR"/wav2lip/*   "$NODES_DIR/ComfyUI_wav2lip/Wav2Lip/checkpoints/" 2>/dev/null || true
ln -sf "$MODELS_DIR"/sadtalker/* "$NODES_DIR/Comfyui-SadTalker/SadTalker/checkpoints/" 2>/dev/null || true
ln -sfn "$MODELS_DIR/liveportrait" "$NODES_DIR/ComfyUI-LivePortrait/pretrained_weights" 2>/dev/null || true
ln -sfn "$MODELS_DIR/insightface"  "$NODES_DIR/ComfyUI-LivePortrait/insightface" 2>/dev/null || true

# facexlib/gfpgan suchen ihre Weights im venv-Paketordner UND relativ zum CWD
# (ComfyUI startet mit cwd=/workspace -> /workspace/gfpgan/weights). Beide Pfade
# verlinken, sonst lädt SadTalker bei jedem frischen Volume ~290 MB nach.
FACEXLIB_DIR=$("$VENV_DIR/bin/python" -c "import facexlib, os; print(os.path.dirname(facexlib.__file__))" 2>/dev/null || true)
GFPGAN_DIR=$("$VENV_DIR/bin/python" -c "import gfpgan, os; print(os.path.dirname(gfpgan.__file__))" 2>/dev/null || true)
if [ -n "$FACEXLIB_DIR" ]; then
    mkdir -p "$FACEXLIB_DIR/weights" && ln -sf "$MODELS_DIR"/facexlib/* "$FACEXLIB_DIR/weights/" 2>/dev/null || true
fi
if [ -n "$GFPGAN_DIR" ]; then
    mkdir -p "$GFPGAN_DIR/weights" && ln -sf "$MODELS_DIR/gfpgan/GFPGANv1.4.pth" "$GFPGAN_DIR/weights/" 2>/dev/null || true
fi
mkdir -p "$BASE_DIR/gfpgan/weights"
ln -sf "$MODELS_DIR"/facexlib/* "$BASE_DIR/gfpgan/weights/" 2>/dev/null || true
ln -sf "$MODELS_DIR/gfpgan/GFPGANv1.4.pth" "$BASE_DIR/gfpgan/weights/" 2>/dev/null || true
c_ok "Symlinks gesetzt"

# ------------------------------------------------------------
# 7. ComfyUI starten — genau einmal
# ------------------------------------------------------------
step "ComfyUI Start"

stop_comfyui() {
    # 1) bevorzugt per PID-File
    if [ -f "$PIDFILE" ]; then
        local pid; pid=$(cat "$PIDFILE" 2>/dev/null || true)
        if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true; sleep 2; kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PIDFILE"
    fi
    # 2) Fallback: Prozesse am absoluten Pfad finden.
    #    Eigene/Scanner-Prozesse ausschließen (sonst killt sich der Aufrufer selbst).
    for pid in $(pgrep -f "$COMFY_DIR/main\\.py" 2>/dev/null || true); do
        [ "$pid" = "$$" ] && continue
        grep -qa "pgrep\|entrypoint.sh" "/proc/$pid/cmdline" 2>/dev/null && continue
        kill "$pid" 2>/dev/null || true
    done
    sleep 1
}

port_free() { ! curl -s -m 2 http://127.0.0.1:8188/system_stats >/dev/null 2>&1; }

stop_comfyui

if ! port_free; then
    c_warn "Port 8188 noch belegt — warte kurz"
    sleep 5
fi

cd "$BASE_DIR" || exit 1
nohup "$VENV_DIR/bin/python" "$COMFY_DIR/main.py" --listen 0.0.0.0 --port 8188 \
    > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > "$PIDFILE"
c_ok "ComfyUI gestartet (PID $SERVER_PID, Log: $SERVER_LOG)"

echo "--> Warte auf Serverbereitschaft (max. 300s)..."
SERVER_READY=0
for i in $(seq 1 300); do
    if curl -sf -m 3 http://127.0.0.1:8188/object_info >/dev/null 2>&1; then
        SERVER_READY=1
        READY_SECS=$i
        echo "   bereit nach ${i}s"
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        c_err "ComfyUI-Prozess ist beim Start gestorben. Letzte Logs:"
        tail -n 40 "$SERVER_LOG"
        break
    fi
    sleep 1
done

# ------------------------------------------------------------
# 8. Verifikation + Statusfile
# ------------------------------------------------------------
if [ "$SERVER_READY" = "1" ]; then
    step "Node-Verifikation"
    "$VENV_DIR/bin/python" - > /tmp/node_check.txt 2>&1 <<'PYEOF' || true
import json, urllib.request
data = json.load(urllib.request.urlopen("http://127.0.0.1:8188/object_info", timeout=60))
required = ["Wav2Lip", "SadTalker", "LivePortraitProcess"]
missing = [n for n in required if n not in data]
print("MISSING=" + ",".join(missing))
print("COUNT=" + str(len(data)))
PYEOF
    cat /tmp/node_check.txt
    MISSING=$(sed -n 's/^MISSING=//p' /tmp/node_check.txt)
    NODE_COUNT=$(sed -n 's/^COUNT=//p' /tmp/node_check.txt)
    if [ -z "$MISSING" ]; then
        c_ok "Alle Kern-LipSync-Nodes registriert (Wav2Lip, SadTalker, LivePortraitProcess) — $NODE_COUNT Nodes total"
        NODES_STATUS="ok"
    else
        c_err "Fehlende Nodes: $MISSING"
        NODES_STATUS="missing:$MISSING"
    fi
    GPU_INFO=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)
    OM_INFO="-"
    [ -x "$OM_DIR/.venv/bin/python" ] && OM_INFO=$("$OM_DIR/.venv/bin/python" -c "import sys;print('.'.join(map(str,sys.version_info[:3])))" 2>/dev/null || echo "vorhanden")

    "$VENV_DIR/bin/python" - "$STATUS_FILE" "$SERVER_PID" "$GPU_INFO" "$NODES_STATUS" "$OM_INFO" \
        "$BOOT_MODE" "${READY_SECS:-0}" "$(dur "$BOOT_T0")" <<'PYEOF' || true
import json, sys, datetime
path, pid, gpu, nodes, om, mode, ready, total = sys.argv[1:9]
with open(path, "w") as f:
    json.dump({
        "booted_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "comfyui_pid": pid,
        "comfyui_url": "http://127.0.0.1:8188",
        "gpu": gpu,
        "nodes": nodes,
        "openmontage_python": om,
        "boot_mode": mode,                    # "full" (setup.sh lief) oder "fast"
        "server_ready_seconds": int(ready),   # bis ComfyUI antwortet
        "boot_seconds": int(total),           # entrypoint gesamt
    }, f, indent=2)
print(f"Status: {path}")
PYEOF

    echo
    echo "================================================"
    echo " ComfyUI läuft auf Port 8188 — Web-UI via RunPod-Port-Mapping"
    echo " GPU: ${GPU_INFO:-unbekannt}"
    echo " Boot: ${BOOT_MODE} | Server bereit nach ${READY_SECS:-?}s | entrypoint gesamt $(dur "$BOOT_T0")s"
    echo " Verify: curl -sf http://127.0.0.1:8188/system_stats"
    echo "================================================"
else
    c_err "ComfyUI antwortet nicht. Letzte 40 Zeilen $SERVER_LOG:"
    tail -n 40 "$SERVER_LOG" 2>/dev/null || true
    c_warn "Pod bleibt benutzbar (SSH) — Reparatur: bash $BASE_DIR/setup.sh && bash $BASE_DIR/entrypoint.sh"
fi

if [ "${RUN_IN_BACKGROUND:-false}" != "true" ]; then
    wait "$SERVER_PID"
fi
