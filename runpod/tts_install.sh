#!/usr/bin/env bash
# TTS-Stack auf dem Pod installieren: eigener venv, damit die ComfyUI-Pins bleiben.
# Läuft als Hintergrundprozess mit Log: /workspace/tts_install.log
#
#   MODELS=1 bash tts_install.sh    # zusätzlich die Modelle vorladen (~14 GB)
#   MODELS=0 bash tts_install.sh    # nur Pakete
set -uo pipefail
LOG=/workspace/tts_install.log
TTS_VENV=/workspace/ttsvenv
TTS_STAGE=/workspace/tts_models
TORCH_INDEX="https://download.pytorch.org/whl/cu128"
MODELS="${MODELS:-0}"
UV=/usr/bin/uv

say() { echo "[$(date -u '+%H:%M:%S')] $*" | tee -a "$LOG"; }

say "=== TTS-Installation gestartet (MODELS=$MODELS) ==="

# 1) eigener venv auf demselben Interpreter wie ComfyUI (gleiche cu128-Wheels)
if [ ! -x "$TTS_VENV/bin/python" ]; then
    say "venv anlegen: $TTS_VENV"
    "$UV" venv "$TTS_VENV" --python /workspace/venv/bin/python >>"$LOG" 2>&1 \
        && say "venv ok" || say "WARNUNG: venv-Anlage fehlgeschlagen"
else
    say "venv vorhanden"
fi

# 2) torch zuerst und gepinnt — sonst ziehen chatterbox/qwen-tts eigene CUDA-Builds
if ! "$TTS_VENV/bin/python" -c "import torch" 2>/dev/null; then
    say "torch (cu128) installieren"
    "$UV" pip install --python "$TTS_VENV/bin/python" --index-url "$TORCH_INDEX" \
        "torch==2.9.0+cu128" "torchvision==0.24.0+cu128" "torchaudio==2.9.0+cu128" >>"$LOG" 2>&1 \
        && say "torch ok: $("$TTS_VENV/bin/python" -c 'import torch;print(torch.__version__, torch.cuda.is_available())')" \
        || say "WARNUNG: torch-Installation fehlgeschlagen"
else
    say "torch vorhanden"
fi

# 3) TTS-Pakete
say "chatterbox-tts + qwen-tts installieren"
"$UV" pip install --python "$TTS_VENV/bin/python" \
    chatterbox-tts qwen-tts soundfile "huggingface_hub[cli]" >>"$LOG" 2>&1 \
    && say "Pakete ok" || say "WARNUNG: Paketinstallation fehlgeschlagen"

say "Import-Test:"
"$TTS_VENV/bin/python" - <<'PY' 2>&1 | tee -a "$LOG"
import importlib, sys
for m in ("torch", "torchaudio", "soundfile", "chatterbox", "qwen_tts", "transformers"):
    try:
        mod = importlib.import_module(m)
        print(f"  ✓ {m} {getattr(mod, '__version__', '')}")
    except Exception as e:
        print(f"  ✗ {m}: {str(e)[:90]}")
PY

# 4) Modelle vorladen (optional)
if [ "$MODELS" = "1" ]; then
    mkdir -p "$TTS_STAGE"
    export HF_HOME="$TTS_STAGE/.hf"
    tok=""
    [ -s /workspace/.hf_token ] && tok="$(tr -d '[:space:]' < /workspace/.hf_token)"
    hfdl() {
        local repo="$1" dir="$2" args=()
        [ -n "$tok" ] && args=(--token "$tok")
        if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
            say "   vorhanden: $repo"; return 0; fi
        say "   lade: $repo"
        "$TTS_VENV/bin/hf" download "$repo" --local-dir "$dir" ${args[@]+"${args[@]}"} >>"$LOG" 2>&1 \
            && say "   ok: $repo" || say "   WARNUNG: $repo fehlgeschlagen"
    }
    hfdl "Qwen/Qwen3-TTS-Tokenizer-12Hz"        "$TTS_STAGE/qwen3tts-tokenizer"
    hfdl "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign" "$TTS_STAGE/qwen3tts-voicedesign"
    hfdl "ResembleAI/chatterbox"                "$TTS_STAGE/chatterbox"
    du -sh "$TTS_STAGE" 2>/dev/null | tee -a "$LOG"
fi

say "=== TTS-Installation beendet ==="
