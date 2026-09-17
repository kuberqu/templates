#!/usr/bin/env bash
# ============================================================
# RunPod LipSync-ComfyUI Setup (uv + aria2c + Parallel-Downloads)
# Repo: kuberqu/templates/runpod/setup.sh
#
# DESIGN-REGELN (nach dem Totalausfall vom 17.09.2026):
#  1. KEIN `set -e`: eine fehlschlagende Phase darf den Rest nicht killen.
#     Fehler werden gesammelt und am Ende als Zusammenfassung gemeldet.
#  2. JEDER uv-Aufruf zielt explizit auf $VENV (via --python). Niemals auf
#     "das aktive venv" — VIRTUAL_ENV kann von außen gefälscht/gesetzt sein.
#  3. OpenMontage läuft in einer SUB-SHELL mit gelöschter VIRTUAL_ENV/
#     CONDA_PREFIX/PYTHONPATH-Umgebung. Sein `make setup` schreibt sonst per
#     `$(PIP) install -r requirements.txt` in den ComfyUI-venv und zerschießt
#     numpy/torch (genau das ist am 17.09. passiert).
#  4. Der Pin-Satz (numpy==1.26.4, mediapipe==0.10.21, ...) wird ZULETZT
#     gesetzt, nach ALLEN Node-Requirements, und danach hart verifiziert.
#  5. ComfyUI wird hier NICHT gestartet — das macht der Fast-Boot in
#     entrypoint.sh (verhindert Doppelstart/Port-Konflikt).
# ============================================================
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
export DEBIAN_FRONTEND=noninteractive
# Hängende Netz-Downloads verhindern (der 17.09.-Run hing ~40 Min in uv fest)
export UV_HTTP_TIMEOUT=120
export UV_CONCURRENT_DOWNLOADS=16

BASE_DIR="/workspace"
VENV="$BASE_DIR/venv"
COMFY_DIR="$BASE_DIR/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"
NODES_DIR="$COMFY_DIR/custom_nodes"
OM_DIR="$BASE_DIR/OpenMontage"
LOG="$BASE_DIR/comfyui_setup.log"
STATUS_FILE="$BASE_DIR/setup_status.json"

# GPU-Wahl: Template-Driver 570.x kann max. CUDA 12.8 -> cu128-Wheels.
# Neuere Treiber (595.x) sind abwärtskompatibel, cu128 läuft dort ebenfalls.
TORCH_INDEX="https://download.pytorch.org/whl/cu128"
TORCH_PIN=("torch==2.9.0+cu128" "torchvision==0.24.0+cu128" "torchaudio==2.9.0+cu128")

# Endgültige Pin-Liste — MUSS nach allen Node-Requirements kommen.
# onnxruntime (CPU-Wheel) statt onnxruntime-gpu: entspricht dem am 16.09.
# verifizierten Zustand (LivePortrait-Cropper läuft darüber einwandfrei, GPU
# wird nur für die Torch-Modelle gebraucht) und verträgt sich mit
# mediapipe 0.10.21 -> protobuf 4.25.9. Beide Wheels gleichzeitig zu haben
# führt zu Dateikollisionen im Paketordner 'onnxruntime'.
PIN_NUMPY="numpy==1.26.4"
PIN_MEDIAPIPE="mediapipe==0.10.21"
EXTRA_PKGS=(insightface onnxruntime soundfile scipy "librosa<0.11" "tifffile<2024.5")

FAILED_PHASES=()
PHASE_RESULTS=()

mkdir -p "$BASE_DIR"
exec > >(tee -a "$LOG") 2>&1

# ------------------------------------------------------------
# Helfer
# ------------------------------------------------------------
c_ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
c_err()  { printf '\033[31m✗ %s\033[0m\n' "$*"; }

# ---- Zeitmessung (macht Boot-Tests vergleichbar) ----------------------------
# PHASE_MARK wird nach JEDER gemeldeten Phase nachgezogen -> jede Phase bekommt
# ihre EIGENE Dauer, auch wenn mehrere Phasen im selben step-Block laufen.
T0=$(date +%s)
STEP_START=$T0
PHASE_MARK=$T0
dur()   { echo "$(( $(date +%s) - ${1:-$T0} ))"; }
step()  { STEP_START=$(date +%s); printf '\n=== %s ===\n' "$*"; }

# PHASE_RESULTS-Einträge: "OK|<sekunden>|<label>" bzw. "FAIL|<sekunden>|<label>"
phase_mark() { local now; now=$(date +%s); echo "$(( now - PHASE_MARK ))"; PHASE_MARK=$now; }
phase_ok()   { local s=${2:-$(phase_mark)}; PHASE_RESULTS+=("OK|$s|$1");   c_ok  "$1 (${s}s)"; }
phase_fail() { local s=${2:-$(phase_mark)}; PHASE_RESULTS+=("FAIL|$s|$1"); FAILED_PHASES+=("$1"); c_err "$1 (${s}s)"; }

# non-fatal ausführen: verbose_fail "Beschreibung" cmd args...
nf() {
    local desc="$1"; shift
    if "$@"; then
        phase_ok "$desc"
        return 0
    fi
    phase_fail "$desc"
    return 1
}

# uv-Binary robust finden (venv-uv -> PATH -> pip -> astral-Installer)
find_uv() {
    if [ -x "$VENV/bin/uv" ]; then echo "$VENV/bin/uv"; return 0; fi
    if command -v uv >/dev/null 2>&1; then command -v uv; return 0; fi
    if [ -x /root/.local/bin/uv ]; then echo /root/.local/bin/uv; return 0; fi
    echo "--> uv fehlt, installiere..." >&2
    "$VENV/bin/python" -m pip install --no-cache-dir -q uv >/dev/null 2>&1 \
        || curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
        || true
    if [ -x "$VENV/bin/uv" ]; then echo "$VENV/bin/uv"; return 0; fi
    if [ -x /root/.local/bin/uv ]; then echo /root/.local/bin/uv; return 0; fi
    return 1
}

# uv-Install IMMER gegen den ComfyUI-venv — unabhängig von VIRTUAL_ENV
uv_install() {
    "$UV_BIN" pip install --python "$VENV/bin/python" "$@"
}

# ------------------------------------------------------------
# OpenMontage-Installation — läuft PARALLEL im Hintergrund (Start in Phase 3b).
# Isoliert in Sub-Shell ohne VIRTUAL_ENV: `make setup` würde sonst in den
# ComfyUI-venv installieren (das Makefile bevorzugt ein gesetztes VIRTUAL_ENV)
# und numpy/torch zerschießen.
# ------------------------------------------------------------
install_openmontage() {
    (
        set -uo pipefail
        # Komplett von der ComfyUI-Umgebung entkoppeln
        unset VIRTUAL_ENV VIRTUAL_ENV_PROMPT CONDA_PREFIX CONDA_DEFAULT_ENV PYTHONPATH PYTHONHOME
        export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export DEBIAN_FRONTEND=noninteractive

        # 8a. Systempakete für Remotion/Chromium (sonst: libnspr4.so fehlt, exit 127)
        CHROME_LIBS="libnspr4 libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2
                     libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1
                     libasound2t64 libpango-1.0-0 libcairo2 libatspi2.0-0 libxshmfence1 fonts-liberation"
        if ! dpkg -s libnspr4 >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq $CHROME_LIBS >/dev/null 2>&1 \
                && echo "✓ Chromium-Systemlibs installiert" \
                || echo "⚠ Chromium-Systemlibs: apt-Install fehlgeschlagen"
        else
            echo "✓ Chromium-Systemlibs vorhanden"
        fi

        # 8b. Node.js 22 (Remotion/HyperFrames brauchen modernes Node)
        if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -lt 20 ]; then
            curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh 2>/dev/null \
                && bash /tmp/nodesource_setup.sh >/dev/null 2>&1 \
                && apt-get install -y -qq nodejs >/dev/null 2>&1 \
                && echo "✓ Node $(node -v) installiert" \
                || echo "⚠ Node 22 Installation fehlgeschlagen"
        else
            echo "✓ Node $(node -v) vorhanden"
        fi

        # 8c. Clone (idempotent)
        [ -d "$OM_DIR/.git" ] || git clone --depth=1 https://github.com/calesthio/OpenMontage.git "$OM_DIR" \
            || { echo "✗ OpenMontage-Clone fehlgeschlagen"; exit 1; }

        # 8c2. Bekannter OM-Bug (verifiziert 17.09.): remotion_caption_burn setzt
        #      videoSrc mit "public/"-Präfix, aber Remotions staticFile() VERBIETET
        #      dieses Präfix -> TalkingHead-Render bricht mit
        #      "Do not include the public/ prefix when using staticFile()" ab.
        CB="$OM_DIR/tools/video/remotion_caption_burn.py"
        if [ -f "$CB" ] && grep -q 'public/talking-head/{video_filename}' "$CB"; then
            sed -i 's|public/talking-head/{video_filename}|talking-head/{video_filename}|' "$CB"
            echo "✓ caption-burn staticFile-Patch angewendet"
        else
            echo "✓ caption-burn staticFile-Patch nicht nötig (schon gefixt)"
        fi

        cd "$OM_DIR" || exit 1

        # 8d. Eigener venv EXPLIZIT mit uv (nicht "das aktive venv"!)
        if [ ! -x "$OM_DIR/.venv/bin/python" ]; then
            "$UV_BIN" venv --python 3.10 "$OM_DIR/.venv" || { echo "✗ OM-venv fehlgeschlagen"; exit 1; }
        fi
        echo "✓ OM-venv: $("$OM_DIR/.venv/bin/python" -V)"

        # 8e. make setup — doppelt abgesichert: Umgebung entkoppelt UND VENV_DIR gesetzt.
        #     Läuft parallel zu den ComfyUI-Installationen -> bei Netz-/Cache-Konkurrenz
        #     gibt es einen zweiten Versuch.
        if [ ! -d "$OM_DIR/remotion-composer/node_modules" ] || [ ! -f "$OM_DIR/.om_installed" ]; then
            if ! make setup VENV_DIR="$OM_DIR/.venv"; then
                echo "⚠ make setup fehlgeschlagen — zweiter Versuch"
                make setup VENV_DIR="$OM_DIR/.venv" || echo "⚠ make setup mit Fehlern beendet (siehe oben)"
            fi
            # Nur als installiert markieren, wenn node_modules wirklich da ist
            [ -d "$OM_DIR/remotion-composer/node_modules" ] && touch "$OM_DIR/.om_installed"
        else
            echo "✓ OM-Abhängigkeiten bereits installiert"
        fi

        # 8f. Fehlende Runtime-Deps (make setup installiert sie NICHT)
        "$UV_BIN" pip install --python "$OM_DIR/.venv/bin/python" -q aiohttp pydub edge-tts piper-tts \
            && echo "✓ aiohttp/pydub/edge-tts/piper-tts" \
            || echo "⚠ OM Runtime-Deps fehlgeschlagen"

        # 8g. Piper-Voice (1.8.x: --download-dir existiert nicht mehr -> --data-dir)
        "$OM_DIR/.venv/bin/python" -m piper.download_voices en_US-lessac-medium --data-dir /root/.piper/voices >/dev/null 2>&1 \
            && echo "✓ Piper-Voice en_US-lessac-medium" \
            || echo "⚠ Piper-Voice Download fehlgeschlagen"

        # 8h. .env: COMFYUI auf den lokalen Server zeigen lassen (idempotent)
        [ -f "$OM_DIR/.env" ] || cp "$OM_DIR/.env.example" "$OM_DIR/.env" 2>/dev/null || true
        export OM_DIR
        "$OM_DIR/.venv/bin/python" - <<'PYEOF' || echo "⚠ .env-Anpassung fehlgeschlagen"
import re, os
p = os.path.join(os.environ.get("OM_DIR", "/workspace/OpenMontage"), ".env")
src = open(p).read()
def setvar(src, name, val):
    pat = re.compile(r"^([ \t]*#?[ \t]*" + name + r"=).*$", re.M)
    if pat.search(src):
        return pat.sub(name + "=" + val, src)
    return src.rstrip() + "\n" + name + "=" + val + "\n"
for n in ("COMFYUI_SERVER_URL", "COMFYUI_VIDEO_SERVER_URL"):
    src = setvar(src, n, "http://127.0.0.1:8188")
open(p, "w").write(src)
print("✓ .env: COMFYUI-URLs = http://127.0.0.1:8188")
PYEOF

        # 8i. Verifikation OM
        "$OM_DIR/.venv/bin/python" -c "import aiohttp, pydub, edge_tts; print('✓ OM Runtime-Deps OK')" \
            || echo "⚠ OM Runtime-Deps-Verifikation fehlgeschlagen"
        echo "hello" | "$OM_DIR/.venv/bin/piper" -m en_US-lessac-medium --data-dir /root/.piper/voices -f /tmp/piper_check.wav >/dev/null 2>&1 \
            && { echo "✓ Piper TTS OK"; rm -f /tmp/piper_check.wav; } \
            || echo "⚠ Piper-TTS-Test fehlgeschlagen"
        exit 0
    ) 2>&1 | sed 's/^/    [OM] /'
    return "${PIPESTATUS[0]}"
}

# ------------------------------------------------------------
step "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ComfyUI/OpenMontage Setup Start"
echo "GPU: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo 'nicht gefunden')"
echo "Log: $LOG"

if [ ! -x "$VENV/bin/python" ]; then
    c_err "venv fehlt: $VENV/bin/python — entrypoint.sh muss ihn anlegen (python3 -m venv --system-site-packages)"
    exit 1
fi

UV_BIN="$(find_uv)" || { c_err "uv konnte nicht installiert werden"; exit 1; }
c_ok "uv: $UV_BIN ($("$UV_BIN" --version 2>/dev/null || echo '?'))"

# ------------------------------------------------------------
# 1. ComfyUI Core
# ------------------------------------------------------------
step "1. ComfyUI Core"
if [ ! -d "$COMFY_DIR/.git" ]; then
    rm -rf "$COMFY_DIR"
    if git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"; then
        phase_ok "ComfyUI geklont"
    else
        phase_fail "ComfyUI klonen"
    fi
else
    # Lokale Anpassungen nicht verlieren -> nur versuchen, Fehler tolerieren
    (cd "$COMFY_DIR" && git pull --ff-only >/dev/null 2>&1) \
        && phase_ok "ComfyUI aktualisiert" \
        || c_warn "ComfyUI git pull übersprungen (lokale Änderungen/offline) — fahre fort"
fi

mkdir -p "$MODELS_DIR"/{checkpoints,vae,clip,loras,upscale_models,insightface/models,wav2lip,sadtalker,liveportrait,gfpgan,facexlib,diffusion_models}

# ------------------------------------------------------------
# 2. Modell-Downloads (aria2c mit curl-Fallback)
# ------------------------------------------------------------
fast_download() {
    local target="$1" url="$2"
    if [ -s "$target" ]; then
        echo "   vorhanden: $(basename "$target")"
        return 0
    fi
    mkdir -p "$(dirname "$target")"
    echo "   lade $(basename "$target")..."
    if command -v aria2c >/dev/null 2>&1; then
        aria2c -q -c -x 16 -s 16 -k 1M --timeout=60 --connect-timeout=20 \
            --max-tries=5 --retry-wait=5 \
            --header="User-Agent: Mozilla/5.0" --check-certificate=false \
            -d "$(dirname "$target")" -o "$(basename "$target")" "$url" \
        || curl -k -L -f --retry 5 --connect-timeout 20 -A "Mozilla/5.0" -o "$target" "$url"
    else
        curl -k -L -f --retry 5 --connect-timeout 20 -A "Mozilla/5.0" -o "$target" "$url"
    fi
}

download_models_background() {
    echo "--> [parallel] Modell-Downloads gestartet"
    # Wav2Lip
    fast_download "$MODELS_DIR/wav2lip/wav2lip.pth"           "https://huggingface.co/camenduru/Wav2Lip/resolve/main/checkpoints/wav2lip.pth"
    fast_download "$MODELS_DIR/wav2lip/wav2lip_gan.pth"       "https://huggingface.co/camenduru/Wav2Lip/resolve/main/checkpoints/wav2lip_gan.pth"
    fast_download "$MODELS_DIR/wav2lip/s3fd-619a316847.pth"   "https://huggingface.co/camenduru/Wav2Lip/resolve/main/checkpoints/s3fd-619a316812.pth"
    # LivePortrait
    for file in appearance_feature_extractor.safetensors motion_extractor.safetensors \
                spade_generator.safetensors warping_module.safetensors \
                stitching_retargeting_module.safetensors landmark.onnx; do
        fast_download "$MODELS_DIR/liveportrait/$file" "https://huggingface.co/Kijai/LivePortrait_safetensors/resolve/main/$file"
    done
    # InsightFace Buffalo_L
    if [ ! -f "$MODELS_DIR/insightface/models/buffalo_l/det_10g.onnx" ]; then
        mkdir -p "$MODELS_DIR/insightface/models"
        curl -k -L -f --retry 5 -o "$MODELS_DIR/insightface/models/buffalo_l.zip" \
            "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip" \
        && unzip -o -q "$MODELS_DIR/insightface/models/buffalo_l.zip" -d "$MODELS_DIR/insightface/models/buffalo_l" \
        && rm -f "$MODELS_DIR/insightface/models/buffalo_l.zip"
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
    # alignment_WFLW_4HG wird von SadTalker (facexlib Landmark-Alignment) gebraucht.
    # Fehlte in der Liste -> facexlib lud beim ersten Render 185 MB nach.
    fast_download "$MODELS_DIR/facexlib/alignment_WFLW_4HG.pth" "https://github.com/xinntao/facexlib/releases/download/v0.1.0/alignment_WFLW_4HG.pth"
    # LTX-Video + VAE
    fast_download "$MODELS_DIR/diffusion_models/ltx-video-2b-v0.9.5.safetensors" "https://huggingface.co/Lightricks/LTX-Video/resolve/main/ltx-video-2b-v0.9.5.safetensors"
    fast_download "$MODELS_DIR/vae/vae-ft-mse-840000-ema-pruned.safetensors" "https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors"
    echo "✓ [parallel] Modell-Downloads abgeschlossen"
}

step "2. Modell-Downloads (parallel)"
download_models_background &
DOWNLOAD_PID=$!

# ------------------------------------------------------------
# 3. Custom Nodes (parallel klonen)
# ------------------------------------------------------------
step "3. Custom Nodes"
declare -A REPOS=(
    ["ComfyUI-LivePortrait"]="https://github.com/kijai/ComfyUI-LivePortrait.git"
    ["ComfyUI_wav2lip"]="https://github.com/ShmuelRonen/ComfyUI_wav2lip.git"
    ["Comfyui-SadTalker"]="https://github.com/haomole/Comfyui-SadTalker.git"
    ["ComfyUI-VideoHelperSuite"]="https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
    ["ComfyUI-GGUF"]="https://github.com/city96/ComfyUI-GGUF.git"
)
mkdir -p "$NODES_DIR"
CLONE_PIDS=()
for name in "${!REPOS[@]}"; do
    if [ ! -d "$NODES_DIR/$name" ]; then
        git clone --depth 1 "${REPOS[$name]}" "$NODES_DIR/$name" &
        CLONE_PIDS+=($!)
    fi
done
if [ ${#CLONE_PIDS[@]} -gt 0 ]; then
    for p in "${CLONE_PIDS[@]}"; do wait "$p" || phase_fail "Node-Clone (pid $p)"; done
fi
# Nur echte Node-Repos zählen (custom_nodes/ enthält auch __pycache__ und lose .py-Dateien,
# die den Zähler sonst verfälschen)
count=0
node_names=""
for d in "$NODES_DIR"/*/; do
    if [ -e "$d/.git" ]; then
        count=$((count + 1))
        node_names="${node_names:+$node_names, }$(basename "$d")"
    fi
done
[ "$count" -eq 0 ] && node_names="keine"
phase_ok "$count Custom-Nodes: $node_names"

# ------------------------------------------------------------
# 3b. OpenMontage PARALLEL im Hintergrund starten
#     Eigener venv, eigene Umgebung -> kann den ComfyUI-venv nicht anfassen.
#     Läuft während der kompletten Python-Installation (Phase 4) mit, statt
#     wie früher erst danach. Ergebnis wird in Phase 8 abgeholt.
# ------------------------------------------------------------
OM_PID=""
OM_START=$(date +%s)
if [ "${INSTALL_OPENMONTAGE:-1}" = "1" ]; then
    install_openmontage &
    OM_PID=$!
    c_ok "OpenMontage-Installation parallel gestartet (pid $OM_PID) — läuft im Hintergrund"
else
    c_warn "OpenMontage übersprungen (INSTALL_OPENMONTAGE != 1)"
fi
# SadTalker-Requirements anpassen? Original-Repo NICHT verändern (git pull-Konflikt),
# stattdessen gefilterte Kopie im /tmp verwenden -> siehe Phase 4b.

# ------------------------------------------------------------
# 4. Python-Abhängigkeiten (immer explizit auf $VENV)
# ------------------------------------------------------------
step "4a. ComfyUI Core-Requirements"
if uv_install "${TORCH_PIN[@]}" --extra-index-url "$TORCH_INDEX"; then
    phase_ok "torch ${TORCH_PIN[*]}"
else
    phase_fail "torch-Install"
fi

if uv_install -r "$COMFY_DIR/requirements.txt"; then
    phase_ok "ComfyUI requirements.txt"
else
    phase_fail "ComfyUI requirements.txt"
fi

step "4b. Node-Requirements (non-fatal pro Node)"
for req in "$NODES_DIR"/*/requirements.txt; do
    [ -f "$req" ] || continue
    node_name=$(basename "$(dirname "$req")")
    # SadTalker: harte ==-Pins und numpy-Zeilen entfernen (kollidieren mit torch/cu128-Stack)
    tmp_req="/tmp/req_${node_name}.txt"
    if [ "$node_name" = "Comfyui-SadTalker" ]; then
        sed 's/==/>=/g' "$req" | grep -viE '^\s*numpy' > "$tmp_req"
    else
        cp "$req" "$tmp_req"
    fi
    if uv_install -r "$tmp_req"; then
        phase_ok "req: $node_name"
    else
        phase_fail "req: $node_name"
    fi
done

# ------------------------------------------------------------
# 4c. PIN-SATZ ZULETZT — überschreibt alles, was Node-Requirements
#     an numpy/mediapipe hochgezogen haben. Reihenfolge ist kritisch!
# ------------------------------------------------------------
step "4c. Pin-Satz + Zusatzpakete (numpy 1.26.4 / mediapipe 0.10.21)"
echo "    Grund: mediapipe 1.0.x hat mediapipe.framework entfernt -> LivePortrait"
echo "    bricht zur LAUFZEIT; numpy 2.x ist mit dem cu128-Torch-Stack unverträglich."
if uv_install "${EXTRA_PKGS[@]}" "$PIN_NUMPY" "$PIN_MEDIAPIPE"; then
    phase_ok "Pin-Satz (${EXTRA_PKGS[*]} $PIN_NUMPY $PIN_MEDIAPIPE)"
else
    phase_fail "Pin-Satz"
fi

# ------------------------------------------------------------
# 5. Runtime-Patches (idempotent + verifiziert)
# ------------------------------------------------------------
step "5. Runtime-Patches"

# 5.1 basicsr/torchvision
patched=0
while IFS= read -r f; do
    if grep -q "functional_tensor" "$f" 2>/dev/null; then
        sed -i 's|from torchvision.transforms.functional_tensor import rgb_to_grayscale|from torchvision.transforms.functional import rgb_to_grayscale|g' "$f"
        patched=1
    fi
done < <(find "$VENV" -path "*/basicsr/data/degradations.py" 2>/dev/null)
phase_ok "basicsr/torchvision degradations (gepatcht: $patched)"

# 5.2 Wav2Lip: torchaudio.save -> soundfile (torchaudio 2.9 braucht torchcodec)
W2L_NODE="$NODES_DIR/ComfyUI_wav2lip/wav2lip.py"
if [ -f "$W2L_NODE" ]; then
    if grep -q "_sf.write(temp_audio_path" "$W2L_NODE"; then
        phase_ok "Wav2Lip soundfile-Export (bereits gepatcht)"
    elif grep -q "torchaudio.save(temp_audio_path" "$W2L_NODE"; then
        sed -i 's|torchaudio.save(temp_audio_path, waveform_tensor, sample_rate)|import soundfile as _sf\n            _sf.write(temp_audio_path, waveform_tensor.squeeze(0).cpu().numpy(), sample_rate)|' "$W2L_NODE"
        grep -q "_sf.write(temp_audio_path" "$W2L_NODE" \
            && phase_ok "Wav2Lip soundfile-Export gepatcht" \
            || phase_fail "Wav2Lip Patch (Muster nicht gefunden)"
    else
        c_warn "Wav2Lip Patch übersprungen (Stelle im Code nicht gefunden — Node-Update?)"
    fi
fi

# 5.3 SadTalker ShowVideo: None-Guard für API-Modus
SHOWVIDEO="$NODES_DIR/Comfyui-SadTalker/nodes/ShowVideo.py"
if [ -f "$SHOWVIDEO" ]; then
    if grep -q "isinstance(extra_pnginfo\[0\], dict)" "$SHOWVIDEO"; then
        phase_ok "ShowVideo API-Guard (bereits gepatcht)"
    elif grep -q 'if unique_id and extra_pnginfo and "workflow" in extra_pnginfo\[0\]:' "$SHOWVIDEO"; then
        sed -i 's|if unique_id and extra_pnginfo and "workflow" in extra_pnginfo\[0\]:|if unique_id and extra_pnginfo and isinstance(extra_pnginfo[0], dict) and "workflow" in extra_pnginfo[0]:|' "$SHOWVIDEO"
        grep -q "isinstance(extra_pnginfo\[0\], dict)" "$SHOWVIDEO" \
            && phase_ok "ShowVideo API-Guard gepatcht" \
            || phase_fail "ShowVideo Patch (Muster nicht gefunden)"
    else
        c_warn "ShowVideo Patch übersprungen (Stelle im Code nicht gefunden — Node-Update?)"
    fi
fi

# ------------------------------------------------------------
# 6. Modell-Downloads abwarten + Checkpoint-Symlinks
# ------------------------------------------------------------
step "6. Downloads abwarten + Symlinks"
if wait "$DOWNLOAD_PID"; then
    phase_ok "Modell-Downloads"
else
    phase_fail "Modell-Downloads (einzelne Dateien fehlen?)"
fi

mkdir -p "$NODES_DIR/ComfyUI_wav2lip/Wav2Lip/checkpoints" \
         "$NODES_DIR/Comfyui-SadTalker/SadTalker/checkpoints"
ln -sf "$MODELS_DIR"/wav2lip/*   "$NODES_DIR/ComfyUI_wav2lip/Wav2Lip/checkpoints/" 2>/dev/null || true
ln -sf "$MODELS_DIR"/sadtalker/* "$NODES_DIR/Comfyui-SadTalker/SadTalker/checkpoints/" 2>/dev/null || true
ln -sfn "$MODELS_DIR/liveportrait" "$NODES_DIR/ComfyUI-LivePortrait/pretrained_weights" 2>/dev/null || true
ln -sfn "$MODELS_DIR/insightface"  "$NODES_DIR/ComfyUI-LivePortrait/insightface" 2>/dev/null || true

FACEXLIB_DIR=$(/workspace/venv/bin/python -c "import facexlib, os; print(os.path.dirname(facexlib.__file__))" 2>/dev/null || true)
GFPGAN_DIR=$(/workspace/venv/bin/python -c "import gfpgan, os; print(os.path.dirname(gfpgan.__file__))" 2>/dev/null || true)
if [ -n "$FACEXLIB_DIR" ]; then
    mkdir -p "$FACEXLIB_DIR/weights" && ln -sf "$MODELS_DIR"/facexlib/* "$FACEXLIB_DIR/weights/" 2>/dev/null || true
fi
if [ -n "$GFPGAN_DIR" ]; then
    mkdir -p "$GFPGAN_DIR/weights" && ln -sf "$MODELS_DIR/gfpgan/GFPGANv1.4.pth" "$GFPGAN_DIR/weights/" 2>/dev/null || true
fi
# WICHTIG: facexlib/gfpgan suchen ihre Weights RELATIV ZUM CWD (ComfyUI läuft mit
# cwd=/workspace -> /workspace/gfpgan/weights). Nur die venv-Symlinks oben reichen
# NICHT: dann lädt SadTalker beim ersten Render ~290 MB (alignment 185 MB +
# detection 104 MB) erneut aus dem Netz.
mkdir -p "$BASE_DIR/gfpgan/weights"
ln -sf "$MODELS_DIR"/facexlib/* "$BASE_DIR/gfpgan/weights/" 2>/dev/null || true
ln -sf "$MODELS_DIR/gfpgan/GFPGANv1.4.pth" "$BASE_DIR/gfpgan/weights/" 2>/dev/null || true
phase_ok "Checkpoint-Symlinks"

# ------------------------------------------------------------
# 7. Verifikation des ComfyUI-Stacks (ohne Serverstart)
# ------------------------------------------------------------
step "7. Verifikation ComfyUI-Stack"

# Smoke-/Test-Skripte bereitstellen (siehe runpod/commands.md) — non-fatal, einzeln
for t in test_lp_smoke.py test_lipsync_smokes.py test_lp_retargeting.py; do
    if curl -fsSL -k --retry 3 --connect-timeout 15 \
        "https://raw.githubusercontent.com/kuberqu/templates/main/runpod/$t" \
        -o "/workspace/$t" 2>/dev/null; then
        echo "   $t bereitgestellt"
    else
        c_warn "$t konnte nicht geladen werden (non-fatal)"
    fi
done

if "$VENV/bin/python" - <<'PYEOF'
import sys

problems = []

def check(label, fn):
    try:
        fn()
        print(f"  ok   {label}")
    except Exception as e:
        problems.append(f"{label}: {e!r}")
        print(f"  FAIL {label}: {e!r}")

import torch, numpy, mediapipe

def _cuda():
    if not torch.cuda.is_available():
        raise RuntimeError("torch.cuda.is_available() == False")

def _mp():
    # mediapipe 1.0.x hat mediapipe.framework entfernt -> LivePortrait bricht zur Laufzeit
    from mediapipe.framework.formats import landmark_pb2  # noqa: F401
    if mediapipe.__version__ != "0.10.21":
        raise AssertionError(f"mediapipe {mediapipe.__version__} != 0.10.21")

def _np():
    if not numpy.__version__.startswith("1.26"):
        raise AssertionError(f"numpy {numpy.__version__} != 1.26.x")

def _ort():
    import onnxruntime
    if not onnxruntime.get_available_providers():
        raise RuntimeError("onnxruntime ohne Provider")
    print(f"       onnxruntime {onnxruntime.__version__}: {', '.join(onnxruntime.get_available_providers())}")

def _sf():
    import soundfile  # noqa: F401

def _if():
    import insightface  # noqa: F401

check("torch CUDA verfügbar", _cuda)
check("mediapipe 0.10.21 + framework.formats", _mp)
check("numpy 1.26.x", _np)
check("onnxruntime Provider", _ort)
check("soundfile", _sf)
check("insightface", _if)

import onnxruntime  # noqa: E402
print(f"  torch {torch.__version__} | CUDA {torch.version.cuda} | GPU {torch.cuda.get_device_name(0) if torch.cuda.is_available() else '-'}")
print(f"  mediapipe {mediapipe.__version__} | numpy {numpy.__version__} | onnxruntime {onnxruntime.__version__}")

if problems:
    print("PROBLEME:")
    for p in problems:
        print("  -", p)
    sys.exit(1)
sys.exit(0)
PYEOF
then
    phase_ok "Stack-Verifikation"
else
    phase_fail "Stack-Verifikation (siehe Ausgabe oben)"
fi

# ------------------------------------------------------------
# 8. OpenMontage — Ergebnis des PARALLEL gestarteten Hintergrund-Laufs (Phase 3b)
# ------------------------------------------------------------
step "8. OpenMontage (Ergebnis des Parallel-Laufs)"
if [ "${INSTALL_OPENMONTAGE:-1}" != "1" ]; then
    c_warn "OpenMontage übersprungen (INSTALL_OPENMONTAGE != 1)"
elif [ -n "${OM_PID:-}" ]; then
    if wait "$OM_PID"; then
        phase_ok "OpenMontage (parallel)" "$(( $(date +%s) - OM_START ))"
    else
        rc=$?
        phase_fail "OpenMontage (parallel, rc=$rc)" "$(( $(date +%s) - OM_START ))"
    fi
else
    c_warn "OpenMontage wurde nicht gestartet (OM_PID leer)"
fi


# ------------------------------------------------------------
# 9. Sicherheitsnetz: ComfyUI-Pins erneut erzwingen
#    (falls der OM-Block trotz Isolation etwas angefasst hat)
# ------------------------------------------------------------
step "9. Sicherheitsnetz: ComfyUI-Pins"
if "$VENV/bin/python" - <<'PYEOF' >/dev/null 2>&1
import numpy, mediapipe
raise SystemExit(0 if (numpy.__version__.startswith("1.26") and mediapipe.__version__ == "0.10.21") else 1)
PYEOF
then
    phase_ok "Pins unverändert (numpy/mediapipe)"
else
    c_warn "Pins wurden verändert — stelle sie wieder her"
    uv_install "$PIN_NUMPY" "$PIN_MEDIAPIPE" && phase_ok "Pins wiederhergestellt" || phase_fail "Pins wiederherstellen"
fi

# ------------------------------------------------------------
# 10. Zusammenfassung + Statusfile für entrypoint.sh
# ------------------------------------------------------------
step "10. Zusammenfassung"
TOTAL=$(dur "$T0")
for r in "${PHASE_RESULTS[@]}"; do
    IFS='|' read -r st secs label <<< "$r"
    if [ "$st" = "OK" ]; then c_ok "$label (${secs}s)"; else c_err "$label (${secs}s)"; fi
done

echo
echo "--- Laufzeit ---"
for r in "${PHASE_RESULTS[@]}"; do
    IFS='|' read -r st secs label <<< "$r"
    printf '%6ss  %s\n' "$secs" "$label"
done | sort -rn | head -5 | sed 's/^/  langsamste Phase: /' || true
printf '  GESAMT: %s Min %ss (%s Phasen)\n' "$((TOTAL / 60))" "$((TOTAL % 60))" "${#PHASE_RESULTS[@]}"

printf '%s\n' "${FAILED_PHASES[@]}" > /tmp/setup_failed_phases.txt
"$VENV/bin/python" - "$STATUS_FILE" /tmp/setup_failed_phases.txt "$TOTAL" <<'PYEOF' 2>/dev/null || true
import json, sys, datetime
path, listfile, total = sys.argv[1], sys.argv[2], int(sys.argv[3])
failed = [l.strip() for l in open(listfile) if l.strip()]
with open(path, "w") as f:
    json.dump({
        "finished_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "duration_seconds": total,
        "failed_phases": failed,
        "ok": not failed,
    }, f, indent=2)
print(f"Status geschrieben: {path} (ok={not failed}, {total}s)")
PYEOF

if [ ${#FAILED_PHASES[@]} -eq 0 ]; then
    echo "=== SETUP ERFOLGREICH BEENDET ==="
    echo "Status: $STATUS_FILE"
    exit 0
else
    echo "=== SETUP MIT FEHLERN BEENDET (${#FAILED_PHASES[@]}): ${FAILED_PHASES[*]} ==="
    echo "Status: $STATUS_FILE"
    exit 2
fi