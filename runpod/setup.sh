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

# ---- Generative Modelle (Wan/InfiniteTalk + Qwen-Image/-Edit) ---------------
# Der Host-Renderer und die Bildgenerierung brauchen diese Modelle (zusammen
# ~65 GB). Die Gen-Phase ist:
#   * abschaltbar mit INSTALL_GEN=0
#   * token-OPTIONAL: die genutzten Repos (Comfy-Org, Kijai, lightx2v) sind
#     öffentlich; ein Token wird nur für gated Repos gebraucht (Lightricks/LTX-2.5)
#   * rein additiv — sie startet als eigene Hintergrund-Phase, damit der
#     Fast-Boot auf intaktem Volume unverändert schnell bleibt (hf_get prüft
#     mit -s und lädt nur fehlende Dateien).
INSTALL_GEN="${INSTALL_GEN:-1}"
# ---- Qwen-Block optional ----------------------------------------------------
# Der Qwen-Image/-Edit-Satz ist ~52 GB. Auf einem reinen Host-Render-Pod wird er
# nicht gebraucht (nur fuer Avatare, Kanon und Charakter-Datensaetze), und auf
# kleinen Volumes passt er nicht neben den Wan-Satz (~52 GB).
#   INSTALL_QWEN=0 -> Qwen ueberspringen; Boot ~20 statt ~35 Min, -52 GB
# Gemessen 18.09.2026: Volumen mit 100 GB lief beim Qwen-Block voll.
INSTALL_QWEN="${INSTALL_QWEN:-1}"
HF_TOKEN_FILE="${HF_TOKEN_FILE:-$BASE_DIR/.hf_token}"
GEN_STAGE="$BASE_DIR/gen_models"          # hf download --local-dir (Staging)
GEN_STATUS="$BASE_DIR/gen_models_status.json"

# ---- TTS / Charakterstimme (Qwen3-TTS VoiceDesign + Chatterbox) -------------
# Zwei Pakete, ZWEI venvs — zwei Konflikte sind auf dem Pod real aufgetreten:
#  1. chatterbox-tts 0.1.7 verlangt transformers==5.2.0, qwen-tts verlangt 4.57.3.
#     In einem venv unlösbar ("requirements are unsatisfiable") -> getrennte venvs.
#  2. chatterbox-tts stuft torch auf 2.6.0+cu124 herunter, torchvision bleibt auf
#     0.24.0+cu128 -> "operator torchvision::nms does not exist" -> transformers
#     stirbt beim Lazy-Import ("Could not import module 'LlamaModel'"). Reparatur:
#     das gepinnte Triple NACH chatterbox erneut installieren.
#   INSTALL_TTS=0 -> überspringen (spart ~6 GB Pakete + ~18 GB Modelle)
INSTALL_TTS="${INSTALL_TTS:-1}"
TTS_VENV="$BASE_DIR/ttsvenv"              # Chatterbox
QWEN_VENV="$BASE_DIR/qwenvenv"            # Qwen3-TTS VoiceDesign
TTS_STAGE="$BASE_DIR/tts_models"
TTS_STATUS="$BASE_DIR/tts_models_status.json"
GEN_DOWNLOAD_PID=""
TTS_DOWNLOAD_PID=""

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

# PHASE_RESULTS-Einträge: "OK|<sekunden>|<label>" bzw. "FAIL|<sekunden>|<label>".
# WICHTIG: mark_now muss als BEFEHL im aktuellen Shell-Kontext laufen — in einer
# $( )-Substitution ginge die Zuweisung PHASE_MARK=… verloren und alle Phasen
# meldeten die kumulierte Zeit seit dem Start (real passiert).
PHASE_DELTA=0
mark_now() {
    local now; now=$(date +%s)
    PHASE_DELTA=$(( now - PHASE_MARK ))
    PHASE_MARK=$now
}
phase_ok()   { if [ -n "${2:-}" ]; then PHASE_DELTA="$2"; else mark_now; fi
               PHASE_RESULTS+=("OK|$PHASE_DELTA|$1");   c_ok  "$1 (${PHASE_DELTA}s)"; }
phase_fail() { if [ -n "${2:-}" ]; then PHASE_DELTA="$2"; else mark_now; fi
               PHASE_RESULTS+=("FAIL|$PHASE_DELTA|$1"); FAILED_PHASES+=("$1"); c_err "$1 (${PHASE_DELTA}s)"; }

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
# Hugging Face: Token + Download-Helfer für die Gen-Modelle
# ------------------------------------------------------------
# Ohne Token antwortet HF inzwischen auch auf öffentliche Repos mit 401
# (gemessen 18.09.2026: 401 + x-pow-Header auf Comfy-Org/FLUX.1-schnell),
# deshalb läuft der Gen-Download über die hf-CLI statt über aria2c/curl-URLs.
hf_token() {
    if [ -n "${HF_TOKEN:-}" ]; then printf '%s' "$HF_TOKEN"; return 0; fi
    if [ -s "$HF_TOKEN_FILE" ]; then tr -d '[:space:]' < "$HF_TOKEN_FILE"; return 0; fi
    return 1
}

# hf_fetch <zielpfad> <repo> <repo-pfad>   (Resume inklusive)
# Lädt eine (auch GATED) Datei direkt per aria2c/curl mit Authorization-Header.
# Bewusst NICHT über die hf-CLI: die steckt im frischen venv nicht drin, und ein
# `uv pip install` in Phase 2 würde mit den parallel laufenden Installationen
# kollidieren (zwei uv-Läufe im selben venv). Header-Download umgeht das.
hf_fetch() {
    local target="$1" repo="$2" sub="$3" tok url
    if [ -s "$target" ]; then echo "   vorhanden: $(basename "$target")"; return 0; fi
    tok="$(hf_token)" || return 3
    url="https://huggingface.co/$repo/resolve/main/$sub"
    mkdir -p "$(dirname "$target")"
    if command -v aria2c >/dev/null 2>&1; then
        aria2c -q -c -x 16 -s 16 -k 1M --timeout=60 --connect-timeout=20 \
            --max-tries=5 --retry-wait=5 --check-certificate=false \
            --header="Authorization: Bearer $tok" \
            -d "$(dirname "$target")" -o "$(basename "$target")" "$url" \
        || curl -k -L -f --retry 5 --connect-timeout 20 \
             -H "Authorization: Bearer $tok" -o "$target" "$url"
    else
        curl -k -L -f --retry 5 --connect-timeout 20 \
             -H "Authorization: Bearer $tok" -o "$target" "$url"
    fi
}

# hf_get <zielpfad> <repo> <repo-pfad>
# Wie hf_fetch, aber mit OPTIONALEM Token. Alle hier genutzten Repos
# (Comfy-Org/Wan_*, Comfy-Org/Qwen-*, Kijai/*, lightx2v/*) sind oeffentlich —
# am 18.09.2026 mit reinem curl ohne Authorization-Header verifiziert (~70 MB/s).
# Nur GATED Repos (z.B. Lightricks/LTX-2.5) brauchen zwingend einen Token.
hf_get() {
    local target="$1" repo="$2" sub="$3" tok url args=()
    if [ -s "$target" ]; then echo "   vorhanden: $(basename "$target")"; return 0; fi
    tok="$(hf_token 2>/dev/null || true)"
    [ -n "$tok" ] && args=(-H "Authorization: Bearer $tok")
    url="https://huggingface.co/$repo/resolve/main/$sub"
    mkdir -p "$(dirname "$target")"
    if command -v aria2c >/dev/null 2>&1; then
        aria2c -q -c -x 16 -s 16 -k 1M --timeout=60 --connect-timeout=20 \
            --max-tries=5 --retry-wait=5 --check-certificate=false \
            -d "$(dirname "$target")" -o "$(basename "$target")" "$url" \
        || curl -k -L -f --retry 5 --connect-timeout 20 ${args[@]+"${args[@]}"} -o "$target" "$url"
    else
        curl -k -L -f --retry 5 --connect-timeout 20 ${args[@]+"${args[@]}"} -o "$target" "$url"
    fi
}

# Verlinkt alle gestagten Dateien in die ComfyUI-Modellordner (flach, wie die
# Symlink-Konvention der LipSync-Modelle). Erkennt auch split_files/-Layouts
# des Comfy-Org-Repackagings, weil nach dem Elternordner-Namen zugeordnet wird.
link_gen_models() {
    local n=0 d f base target
    for d in diffusion_models vae text_encoders clip loras unet latent_upscale_models model_patches audio_encoders clip_vision; do
        [ -d "$GEN_STAGE/$d" ] || continue
        for f in "$GEN_STAGE/$d"/*; do
            [ -f "$f" ] || continue
            mkdir -p "$MODELS_DIR/$d"
            ln -sfn "$f" "$MODELS_DIR/$d/$(basename "$f")" && n=$((n + 1))
        done
    done
    while IFS= read -r f; do
        base="$(basename "$(dirname "$f")")"
        case "$base" in
            diffusion_models|vae|text_encoders|clip|loras|unet|latent_upscale_models|model_patches|audio_encoders|clip_vision)
                mkdir -p "$MODELS_DIR/$base"
                ln -sfn "$f" "$MODELS_DIR/$base/$(basename "$f")" && n=$((n + 1)) ;;
        esac
    done < <(find "$GEN_STAGE" -mindepth 3 -maxdepth 3 -type f -name "*.safetensors" 2>/dev/null)

    # Hinweis: Der frühere LTX-2.5-Block (zusaetzliche Symlinks nach
    # models/checkpoints/) ist am 18.09.2026 entfallen — LTX-2.5 wird nicht mehr
    # auf dem Pod vorgehalten (Volume-Quota 200 GB). Wer LTX wieder braucht:
    # Repo Lightricks/LTX-2.5, siehe RESTORE_LTX.txt.
    # Tote Symlinks entfernen: zeigen auf geloeschte Ziele (z.B. nach dem
    # LTX-Rueckbau). ComfyUI listet sie sonst in der Modellauswahl und scheitert
    # erst beim Laden ("file not found" beim Render statt beim Start).
    find "$MODELS_DIR" -xtype l -delete 2>/dev/null
    echo "$n"
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
        # faster-whisper: Wort-Timings fuer die Untertitel im Schnitt (compose.py).
        # Fehlte nach dem Volume-Wechsel komplett -> Untertitel fielen auf die
        # Szenentexte zurueck (unlesbar lang).
        "$UV_BIN" pip install --python "$OM_DIR/.venv/bin/python" -q aiohttp pydub edge-tts piper-tts faster-whisper \
            && echo "✓ aiohttp/pydub/edge-tts/piper-tts/faster-whisper" \
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
        "$OM_DIR/.venv/bin/python" -c "import aiohttp, pydub, edge_tts, faster_whisper; print('✓ OM Runtime-Deps OK (inkl. faster-whisper)')" \
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

mkdir -p "$MODELS_DIR"/{checkpoints,vae,clip,loras,upscale_models,insightface/models,gfpgan,facexlib,diffusion_models,text_encoders,audio_encoders,clip_vision,model_patches,latent_upscale_models}

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
    # ---- Am 18.09.2026 ausgeduennt (Volume-Quota 200 GB) -----------------------
    # ENTFERNT: Wav2Lip (96x96-Mundregion -> Brei beim Hochskalieren),
    #           SadTalker (Qualitaet weit unter allen Alternativen),
    #           LivePortrait (videogetrieben, unser Weg ist audiogetrieben),
    #           LTX-Video-2b + SD-VAE (alte LTX-Phase, ersetzt durch LTX-2.5/Wan).
    # Der Host-Renderer ist jetzt InfiniteTalk (siehe download_gen_models_background).
    # ---- InsightFace Buffalo_L (Gesichtserkennung/Pruefung, h3_lipsync.py) ----
    if [ ! -f "$MODELS_DIR/insightface/models/buffalo_l/det_10g.onnx" ]; then
        mkdir -p "$MODELS_DIR/insightface/models"
        curl -k -L -f --retry 5 -o "$MODELS_DIR/insightface/models/buffalo_l.zip" \
            "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip" \
        && unzip -o -q "$MODELS_DIR/insightface/models/buffalo_l.zip" -d "$MODELS_DIR/insightface/models/buffalo_l" \
        && rm -f "$MODELS_DIR/insightface/models/buffalo_l.zip"
    fi
    # ---- GFPGAN & FaceXLib (~0,4 GB): optionale Gesichts-Restauration ----------
    fast_download "$MODELS_DIR/gfpgan/GFPGANv1.4.pth" "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth"
    fast_download "$MODELS_DIR/facexlib/detection_Resnet50_Final.pth" "https://github.com/xinntao/facexlib/releases/download/v0.1.0/detection_Resnet50_Final.pth"
    fast_download "$MODELS_DIR/facexlib/parsing_parsenet.pth" "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/parsing_parsenet.pth"
    fast_download "$MODELS_DIR/facexlib/alignment_WFLW_4HG.pth" "https://github.com/xinntao/facexlib/releases/download/v0.1.0/alignment_WFLW_4HG.pth"
    echo "✓ [parallel] Modell-Downloads abgeschlossen"
}

# ------------------------------------------------------------
# Generative Modelle: Qwen-Image/Edit (Kanon + Avatare) + Wan/InfiniteTalk
# (Host-Talking-Head). Läuft als ZWEITE parallele Phase. Bewusst defensiv:
#   * kein Token -> WARNUNG, aber die öffentlichen Repos laufen trotzdem
#     (siehe hf_get) — nur gated Repos würden scheitern
#   * INSTALL_GEN=0 -> skip
#   * Größenprüfung erst nach dem Download (Phase 7)
# Reihenfolge nach Nutzen: Host-Renderer zuerst (Wan 2.1 + InfiniteTalk, ~50 GB),
# dann Qwen-Image/-Edit für Kanon und die weiblichen Avatar-Varianten.
# Am 18.09.2026 wurde der LTX-2.5-Block entfernt (Volume-Quota 200 GB); LTX wird
# nur noch für B-Roll gebraucht und bei Bedarf über setup.sh nachgeholt
# (Repo Lightricks/LTX-2.5, gated -> braucht HF_TOKEN).
# ------------------------------------------------------------
download_gen_models_background() {
    local t0; t0=$(date +%s)
    local ok=0 fail=0 linked=0
    printf '{"installed": false, "reason": "started", "files": []}\n' > "$GEN_STATUS"

    if [ "$INSTALL_GEN" != "1" ]; then
        echo "--> [gen] übersprungen: INSTALL_GEN=$INSTALL_GEN"
        printf '{"installed": false, "reason": "INSTALL_GEN=%s"}\n' "$INSTALL_GEN" > "$GEN_STATUS"
        return 0
    fi
    if ! hf_token >/dev/null; then
        echo "--> [gen] WARNUNG: kein HF-Token (HF_TOKEN oder $HF_TOKEN_FILE)"
        echo "    Öffentliche Repos (Comfy-Org, Kijai, lightx2v) werden trotzdem geladen."
        echo "    Nur GATED Repos (Lightricks/LTX-2.5) würden scheitern."
    fi
    if ! command -v aria2c >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        echo "--> [gen] weder aria2c noch curl vorhanden -> übersprungen"
        printf '{"installed": false, "reason": "no_downloader"}\n' > "$GEN_STATUS"
        return 0
    fi

    echo "--> [gen] Wan/InfiniteTalk + Qwen-Image/-Edit gestartet (Staging: $GEN_STAGE)"
    mkdir -p "$GEN_STAGE" "$MODELS_DIR"/{diffusion_models,vae,text_encoders,clip,loras,unet,latent_upscale_models,model_patches,audio_encoders,clip_vision}

    # ---- Wan 2.1 I2V 480p + InfiniteTalk (Host-Talking-Head) --------------------
    # Ersetzt Wav2Lip: Wav2Lip erzeugt nur eine 96x96-Mundregion, die beim
    # Hochskalieren in 832x1216 zu Brei wird. InfiniteTalk generiert den ganzen
    # Kopf mit natürlicher Kopfbewegung und stabiler Identität.
    # Werte = offizielles ComfyUI-Template (video_wan2_1_infinitetalk.json):
    #   ModelSamplingSD3 shift 8, KSamplerSelect euler, CFGGuider 1.0,
    #   BasicScheduler "normal" 6 Steps, negativ = ConditioningZeroOut(positiv),
    #   25 fps. Dateinamen am 18.09.2026 gegen die Repos verifiziert.
    local wan_ok=0 wan_fail=0
    local wan_files=(
        "split_files/diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors"
        "split_files/model_patches/wan2.1_infiniteTalk_single_fp16.safetensors"
        "split_files/text_encoders/umt5_xxl_fp16.safetensors"
        "split_files/vae/wan_2.1_vae.safetensors"
        "split_files/clip_vision/clip_vision_h.safetensors"
    )
    for f in "${wan_files[@]}"; do
        if hf_get "$GEN_STAGE/$f" "Comfy-Org/Wan_2.1_ComfyUI_repackaged" "$f"; then
            wan_ok=$((wan_ok + 1))
        else
            wan_fail=$((wan_fail + 1)); echo "   ⚠ Wan $(basename "$f") fehlgeschlagen"
        fi
    done
    # Audio-Encoder: das offizielle InfiniteTalk-Template nutzt den chinesischen
    # wav2vec2-base. Der mitgelieferte englische large-Encoder ist NICHT die
    # Template-Wahl (deutsche Phoneme sind mit dem chinesischen Modell im Test
    # sauber synchron gelaufen).
    hf_get "$GEN_STAGE/audio_encoders/wav2vec2-chinese-base_fp16.safetensors" \
        "Kijai/wav2vec2_safetensors" "wav2vec2-chinese-base_fp16.safetensors" \
        && wan_ok=$((wan_ok + 1)) || { wan_fail=$((wan_fail + 1)); echo "   ⚠ wav2vec2-chinese-base fehlgeschlagen"; }
    # 4-Step-Distill-LoRA (lightx2v) — Template-Wert: LoRA @1.0, 6 Steps, cfg 1.0
    hf_get "$GEN_STAGE/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" \
        "Kijai/WanVideo_comfy" "Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" \
        && wan_ok=$((wan_ok + 1)) || { wan_fail=$((wan_fail + 1)); echo "   ⚠ lightx2v-I2V-LoRA fehlgeschlagen"; }
    ok=$((ok + wan_ok)); fail=$((fail + wan_fail))
    echo "   Wan/InfiniteTalk: $wan_ok/$((wan_ok + wan_fail)) Dateien"

    # ---- Qwen-Image 2512 + Qwen-Image-Edit 2511 (beide Apache-2.0, also
    # kommerziell frei). Edit + Multiple-Angles-LoRA ist der Weg zur
    # konsistenten Host-Figur (gleiche Identität, andere Blickwinkel/Szenen).
    # Abschaltbar (INSTALL_QWEN=0), weil der Satz ~52 GB belegt.
    local qwen_ok=0 qwen_fail=0
    if [ "$INSTALL_QWEN" = "1" ]; then
    local qwen_img=(
        "split_files/diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors"
        "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
        "split_files/vae/qwen_image_vae.safetensors"
    )
    for f in "${qwen_img[@]}"; do
        if hf_get "$GEN_STAGE/$f" "Comfy-Org/Qwen-Image_ComfyUI" "$f"; then qwen_ok=$((qwen_ok + 1)); else qwen_fail=$((qwen_fail + 1)); fi
    done
    local qwen_edit=(
        "split_files/diffusion_models/qwen_image_edit_2511_int8_convrot.safetensors"
        "split_files/loras/Qwen-Edit-2509-Multiple-angles.safetensors"
        "split_files/loras/Qwen-Image-Edit-2509-Relight.safetensors"
    )
    for f in "${qwen_edit[@]}"; do
        if hf_get "$GEN_STAGE/$f" "Comfy-Org/Qwen-Image-Edit_ComfyUI" "$f"; then qwen_ok=$((qwen_ok + 1)); else qwen_fail=$((qwen_fail + 1)); fi
    done
    # 4-Step-Lightning-LoRA für Edit-2511: liegt NICHT im Comfy-Org-Repo, sondern
    # in einem eigenen Repo. Ohne sie laufen die Edit-Graphen mit 40 Steps / cfg 4
    # (Faktor 10 langsamer) — alle Host-/Kanon-Skripte setzen steps=4, cfg=1.0.
    hf_get "$GEN_STAGE/loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors" \
        "lightx2v/Qwen-Image-Edit-2511-Lightning" \
        "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors" \
        && qwen_ok=$((qwen_ok + 1)) || { qwen_fail=$((qwen_fail + 1)); echo "   ⚠ Lightning-LoRA fehlgeschlagen"; }
    ok=$((ok + qwen_ok)); fail=$((fail + qwen_fail))
    echo "   Qwen (Image+Edit): $qwen_ok/$((qwen_ok + qwen_fail)) Dateien"
    else
        echo "   Qwen-Block uebersprungen (INSTALL_QWEN=0) — Avatare, Kanon und"
        echo "   Charakter-Datensaetze brauchen ihn, Host-Render nicht."
    fi
    # FLUX.1-schnell wurde bewusst NICHT aufgenommen: Stand 08/2024, überholt
    # durch Qwen-Image 2512 (Apache-2.0). FLUX.2 [dev] wäre qualitativ stärker,
    # ist aber Non-Commercial lizenziert — für monetarisierte Kanäle ein Risiko.

    linked=$(link_gen_models)
    local dur_s=$(( $(date +%s) - t0 ))
    local total; total=$(du -sh "$GEN_STAGE" 2>/dev/null | cut -f1)
    if [ "$fail" -eq 0 ] && [ "$linked" -gt 0 ]; then
        printf '{"installed": true, "linked": %s, "staging": "%s", "seconds": %s, "patterns_ok": %s}\n' \
            "$linked" "$total" "$dur_s" "$ok" > "$GEN_STATUS"
        echo "✓ [gen] fertig: $linked Dateien verlinkt, $total, ${dur_s}s"
    else
        printf '{"installed": false, "reason": "partial", "linked": %s, "failed_patterns": %s, "seconds": %s}\n' \
            "$linked" "$fail" "$dur_s" > "$GEN_STATUS"
        echo "⚠ [gen] unvollständig: $linked verlinkt, $fail Muster fehlgeschlagen, ${dur_s}s"
        # Haeufigste Ursache: das Volume ist voll. Die RunPod-QUOTA ist NICHT in
        # df sichtbar (df zeigt den Shared-Pool mit Petabytes), deshalb hier der
        # Klartext statt einer kryptischen aria2c-Meldung.
        echo "   HINWEIS: meist ist das Volume voll (Quota, in df nicht sichtbar)."
        echo "   Pruefen:  du -sh $BASE_DIR"
        echo "   Bedarf:   Wan/InfiniteTalk ~52 GB + Qwen ~52 GB + venv ~16 GB + OpenMontage"
        echo "   Abhilfe:  groesseres Volume ODER INSTALL_QWEN=0 (spart ~52 GB, Boot ~20 Min)"
    fi
    return 0
}

# ------------------------------------------------------------
# TTS-Modelle + Charakterstimme (eigene venvs, läuft parallel)
# ------------------------------------------------------------
# Läuft als eigene Hintergrund-Phase, damit der Fast-Boot auf intaktem Volume
# unverändert schnell bleibt. Ein Fehlschlag degradiert nur den Stimmbau, nicht
# den LipSync-Kern.
install_tts_background() {
    local t0 ok=0 fail=0
    t0=$(date +%s)
    printf '{"installed": false, "reason": "started"}\n' > "$TTS_STATUS"

    if [ "$INSTALL_TTS" != "1" ]; then
        echo "--> [tts] übersprungen: INSTALL_TTS=$INSTALL_TTS"
        printf '{"installed": false, "reason": "INSTALL_TTS=%s"}\n' "$INSTALL_TTS" > "$TTS_STATUS"
        return 0
    fi

    mk_tts_venv() {   # mk_tts_venv <pfad>
        if [ -x "$1/bin/python" ]; then echo "   venv vorhanden: $1"; return 0; fi
        "$UV_BIN" venv "$1" --python "$VENV/bin/python" >/dev/null 2>&1 || return 1
        return 0
    }
    # Gepinntes Triple — MUSS nach chatterbox erneut laufen (siehe Konflikt 2 oben)
    tts_torch() {     # tts_torch <venv-python>
        "$UV_BIN" pip install --python "$1" --index-url "$TORCH_INDEX" "${TORCH_PIN[@]}" \
            >/dev/null 2>&1
    }

    echo "--> [tts] Chatterbox + Qwen3-TTS (zwei venvs)"
    mk_tts_venv "$TTS_VENV" && tts_torch "$TTS_VENV/bin/python" \
        && "$UV_BIN" pip install --python "$TTS_VENV/bin/python" -q \
             chatterbox-tts soundfile "huggingface_hub[cli]" >/dev/null 2>&1 \
        && { echo "   ✓ chatterbox-tts"; ok=$((ok + 1)); } || { echo "   ⚠ chatterbox-tts fehlgeschlagen"; fail=$((fail + 1)); }
    tts_torch "$TTS_VENV/bin/python" \
        && echo "   ✓ torch-Triple nach chatterbox wiederhergestellt" || echo "   ⚠ Triple-Reparatur fehlgeschlagen"

    mk_tts_venv "$QWEN_VENV" && tts_torch "$QWEN_VENV/bin/python" \
        && "$UV_BIN" pip install --python "$QWEN_VENV/bin/python" -q qwen-tts soundfile \
             >/dev/null 2>&1 \
        && { echo "   ✓ qwen-tts"; ok=$((ok + 1)); } || { echo "   ⚠ qwen-tts fehlgeschlagen"; fail=$((fail + 1)); }
    tts_torch "$QWEN_VENV/bin/python" >/dev/null 2>&1 || true

    # Modelle vorladen (VoiceDesign = Identität, chatterbox = Klangfarbe/Vortrag)
    mkdir -p "$TTS_STAGE"
    export HF_HOME="$TTS_STAGE/.hf"
    local tok; tok="$(hf_token 2>/dev/null || true)"
    tts_hf() {        # tts_hf <repo> <ziel> <hf-binary>
        local repo="$1" dir="$2" tool="$3" args=()
        [ -n "$tok" ] && args=(--token "$tok")
        if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then echo "   vorhanden: $repo"; return 0; fi
        "$tool" download "$repo" --local-dir "$dir" ${args[@]+"${args[@]}"} >/dev/null 2>&1
    }
    if [ -x "$QWEN_VENV/bin/hf" ]; then
        tts_hf "Qwen/Qwen3-TTS-Tokenizer-12Hz"        "$TTS_STAGE/qwen3tts-tokenizer" "$QWEN_VENV/bin/hf" \
            && ok=$((ok + 1)) || { echo "   ⚠ Tokenizer fehlgeschlagen"; fail=$((fail + 1)); }
        tts_hf "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign" "$TTS_STAGE/qwen3tts-voicedesign" "$QWEN_VENV/bin/hf" \
            && ok=$((ok + 1)) || { echo "   ⚠ VoiceDesign fehlgeschlagen"; fail=$((fail + 1)); }
    fi
    if [ -x "$TTS_VENV/bin/hf" ]; then
        tts_hf "ResembleAI/chatterbox" "$TTS_STAGE/chatterbox" "$TTS_VENV/bin/hf" \
            && ok=$((ok + 1)) || { echo "   ⚠ chatterbox-Modelle fehlgeschlagen"; fail=$((fail + 1)); }
    fi

    local secs; secs=$(dur "$t0")
    local size; size=$(du -sh "$TTS_STAGE" 2>/dev/null | cut -f1)
    echo "   [tts] $ok Schritte ok, $fail fehlgeschlagen, Modelle: ${size:-0}"
    printf '{"installed": %s, "schritte_ok": %s, "fehlgeschlagen": %s, "stage": "%s", "seconds": %s}\n' \
        "$([ "$fail" -eq 0 ] && echo true || echo false)" "$ok" "$fail" "$TTS_STAGE" "$secs" > "$TTS_STATUS"
    return 0
}

step "2. Modell-Downloads (parallel)"
download_models_background &
DOWNLOAD_PID=$!
if [ "$INSTALL_GEN" = "1" ]; then
    download_gen_models_background &
    GEN_DOWNLOAD_PID=$!
fi
if [ "$INSTALL_TTS" = "1" ]; then
    install_tts_background &
    TTS_DOWNLOAD_PID=$!
fi

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

step "4b. Node-Requirements (gebündelt, gefiltert)"
# EINE Installation statt einer pro Node: jede Einzel-Installation löst das
# komplette Environment (~150 Pakete) neu auf und prüft es -> 5x Overhead.
# Filter pro Node (beides gemessen bzw. verifiziert):
#   Comfyui-SadTalker  : 'gradio' raus (nur für SadTalkers eigene Web-UI, zieht
#                        fastapi/uvicorn/…), '==' -> '>=', numpy raus
#   ComfyUI-LivePortrait: 'onnxruntime-gpu' raus — wir nutzen das CPU-Wheel aus
#                        dem Pin-Satz, das -gpu-Wheel (235 MB) wurde bisher
#                        geladen und danach wieder ersetzt
MERGED_REQ=/tmp/req_all_nodes.txt
: > "$MERGED_REQ"
for req in "$NODES_DIR"/*/requirements.txt; do
    [ -f "$req" ] || continue
    node_name=$(basename "$(dirname "$req")")
    {
        echo "# --- $node_name ---"
        case "$node_name" in
            Comfyui-SadTalker)    sed 's/==/>=/g' "$req" | grep -viE '^\s*numpy|^\s*gradio' ;;
            ComfyUI-LivePortrait) grep -viE '^\s*onnxruntime-gpu' "$req" ;;
            *)                    cat "$req" ;;
        esac
    } >> "$MERGED_REQ"
done
if uv_install -r "$MERGED_REQ"; then
    phase_ok "Node-Requirements gebündelt ($(grep -cve '^#' "$MERGED_REQ") Zeilen)"
else
    c_warn "gebündelte Installation fehlgeschlagen — Fallback: pro Node (isoliert)"
    for req in "$NODES_DIR"/*/requirements.txt; do
        [ -f "$req" ] || continue
        node_name=$(basename "$(dirname "$req")")
        case "$node_name" in
            Comfyui-SadTalker)    sed 's/==/>=/g' "$req" | grep -viE '^\s*numpy|^\s*gradio' > "/tmp/req_$node_name.txt" ;;
            ComfyUI-LivePortrait) grep -viE '^\s*onnxruntime-gpu' "$req" > "/tmp/req_$node_name.txt" ;;
            *)                    cp "$req" "/tmp/req_$node_name.txt" ;;
        esac
        if uv_install -r "/tmp/req_$node_name.txt"; then
            phase_ok "req: $node_name"
        else
            phase_fail "req: $node_name"
        fi
    done
fi

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

# Gen-Modelle einsammeln. Ein Skip (kein Token/INSTALL_GEN=0) ist KEIN Fehler;
# ein Teilausfall degradiert nur die Video-Generierung, nicht den LipSync-Kern.
if [ -n "$GEN_DOWNLOAD_PID" ]; then
    wait "$GEN_DOWNLOAD_PID" || true
    if grep -q '"installed": true' "$GEN_STATUS" 2>/dev/null; then
        phase_ok "Gen-Modelle (Wan/InfiniteTalk + Qwen-Image/-Edit)"
    else
        GEN_REASON=$(sed -n 's/.*"reason": "\([^"]*\)".*/\1/p' "$GEN_STATUS" 2>/dev/null)
        phase_ok "Gen-Modelle uebersprungen (${GEN_REASON:-unbekannt})"
    fi
fi

# TTS/Charakterstimme: eigener venv-Satz, Fehlschlag degradiert nur den Stimmbau
if [ -n "$TTS_DOWNLOAD_PID" ]; then
    wait "$TTS_DOWNLOAD_PID" || true
    if grep -q '"installed": true' "$TTS_STATUS" 2>/dev/null; then
        phase_ok "TTS (Chatterbox + Qwen3-TTS VoiceDesign, zwei venvs)"
    else
        TTS_INFO=$(tr -d '\n' < "$TTS_STATUS" 2>/dev/null | head -c 120)
        phase_ok "TTS teilweise/uebersprungen: ${TTS_INFO:-unbekannt}"
    fi
fi

mkdir -p "$NODES_DIR/ComfyUI_wav2lip/Wav2Lip/checkpoints" \
         "$NODES_DIR/Comfyui-SadTalker/SadTalker/checkpoints"
ln -sf "$MODELS_DIR"/wav2lip/*   "$NODES_DIR/ComfyUI_wav2lip/Wav2Lip/checkpoints/" 2>/dev/null || true
ln -sf "$MODELS_DIR"/sadtalker/* "$NODES_DIR/Comfyui-SadTalker/SadTalker/checkpoints/" 2>/dev/null || true
ln -sfn "$MODELS_DIR/liveportrait" "$NODES_DIR/ComfyUI-LivePortrait/pretrained_weights" 2>/dev/null || true
ln -sfn "$MODELS_DIR/insightface"  "$NODES_DIR/ComfyUI-LivePortrait/insightface" 2>/dev/null || true

# Pfade direkt aus dem Dateisystem bestimmen: ein `python -c "import facexlib"`
# importiert torch/opencv und kostete in der Messung ~130s — für zwei Symlinks.
FACEXLIB_DIR=$(ls -d "$VENV"/lib/python*/site-packages/facexlib 2>/dev/null | head -1)
GFPGAN_DIR=$(ls -d "$VENV"/lib/python*/site-packages/gfpgan 2>/dev/null | head -1)
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

# Test-/Diagnose-Skripte bereitstellen — non-fatal.
# NICHT über raw.githubusercontent.com: das liefert mit cache-control: max-age=300
# bis zu 5 Minuten den alten Stand (Query-Strings als Cache-Buster wirkungslos).
# codeload.github.com liefert immer aktuell (Repo-Tarball, hier ~30 KB).
step "Test-Skripte aktualisieren"
TARBALL_URL="https://codeload.github.com/kuberqu/templates/tar.gz/refs/heads/main"
TMPD=$(mktemp -d)
if curl -fsSL -k --retry 3 --retry-delay 2 --connect-timeout 15 -o "$TMPD/repo.tgz" "$TARBALL_URL" 2>/dev/null; then
    for t in boot_report.sh test_lp_smoke.py test_lipsync_smokes.py test_lp_retargeting.py; do
        if tar -xzOf "$TMPD/repo.tgz" "templates-main/runpod/$t" > "$TMPD/$t" 2>/dev/null && [ -s "$TMPD/$t" ]; then
            case "$t" in
                *.py) "$VENV/bin/python" -m py_compile "$TMPD/$t" 2>/dev/null || { c_warn "$t: Syntaxprüfung fehlgeschlagen"; continue; } ;;
                *.sh) bash -n "$TMPD/$t" 2>/dev/null || { c_warn "$t: Syntaxprüfung fehlgeschlagen"; continue; } ;;
            esac
            cp "$TMPD/$t" "/workspace/$t" && chmod +x "/workspace/$t" 2>/dev/null || true
            echo "   $t bereitgestellt"
        else
            c_warn "$t nicht im Tarball gefunden (non-fatal)"
        fi
    done
else
    c_warn "codeload nicht erreichbar — Test-Skripte bleiben auf altem Stand"
fi
rm -rf "$TMPD"

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

# --- Gen-Modelle: Existenz + Mindestgroesse (hashen bei 20-GB-Dateien waere
# unverhaeltnismaessig). Greift nur, wenn die Phase wirklich installiert hat.
if [ "$INSTALL_GEN" = "1" ] && grep -q '"installed": true' "$GEN_STATUS" 2>/dev/null; then
    gen_check() {
        # WICHTIG: stat -L (dereference). Ohne -L liefert stat die Laenge des
        # SYMLINKS (~100 Bytes) statt der Zieldatei -> der Check meldete am
        # 18.09.2026 fuer jedes Modell "zu klein (0 MB)" und setzte ok=false,
        # obwohl 85 GB korrekt geladen waren.
        local glob="$1" min_mb="$2" label="$3" f size
        f=$(ls -1 $glob 2>/dev/null | head -1)
        if [ -z "$f" ]; then phase_fail "Gen: $label fehlt"; return; fi
        size=$(( $(stat -L -c %s "$f" 2>/dev/null || echo 0) / 1048576 ))
        if [ "$size" -ge "$min_mb" ]; then phase_ok "Gen: $label (${size} MB)"
        else phase_fail "Gen: $label zu klein (${size} MB)"; fi
    }
    gen_check "$MODELS_DIR/diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors" 20000 "Wan 2.1 I2V 480p"
    gen_check "$MODELS_DIR/model_patches/wan2.1_infiniteTalk_single_fp16.safetensors" 3000 "InfiniteTalk-Patch"
    gen_check "$MODELS_DIR/text_encoders/umt5_xxl_fp16.safetensors" 6000 "umt5-Textencoder"
    gen_check "$MODELS_DIR/vae/wan_2.1_vae.safetensors" 100 "Wan 2.1 VAE"
    gen_check "$MODELS_DIR/clip_vision/clip_vision_h.safetensors" 500 "CLIP-Vision (Wan)"
    gen_check "$MODELS_DIR/audio_encoders/wav2vec2-chinese-base_fp16.safetensors" 100 "wav2vec2-Audioencoder"
    gen_check "$MODELS_DIR/loras/lightx2v_I2V_14B_480p*.safetensors" 300 "lightx2v-I2V-LoRA"
    # Qwen-Satz nur pruefen, wenn er installiert werden sollte — sonst meldet der
    # Boot bei INSTALL_QWEN=0 vier Fehler, obwohl nichts fehlt (real passiert).
    if [ "$INSTALL_QWEN" = "1" ]; then
        gen_check "$MODELS_DIR/diffusion_models/qwen_image_2512*.safetensors" 10000 "Qwen-Image 2512"
        gen_check "$MODELS_DIR/diffusion_models/qwen_image_edit_2511_int8*.safetensors" 10000 "Qwen-Image-Edit 2511"
        gen_check "$MODELS_DIR/loras/Qwen-Edit*-Multiple-angles.safetensors" 100 "Multiple-Angles-LoRA"
        gen_check "$MODELS_DIR/loras/Qwen-Image-Edit-2511-Lightning-4steps*.safetensors" 300 "Lightning-4steps-LoRA"
    else
        phase_ok "Gen: Qwen-Satz uebersprungen (INSTALL_QWEN=0)"
    fi
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