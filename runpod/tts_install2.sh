#!/usr/bin/env bash
# TTS-Stack auf dem Pod — ZWEI venvs. Zwei auf dem Pod real aufgetretene Konflikte:
#
#  1. chatterbox-tts 0.1.7 verlangt transformers==5.2.0, qwen-tts verlangt 4.57.3.
#     In einem venv ist das unlösbar ("requirements are unsatisfiable") -> getrennte venvs.
#  2. chatterbox-tts stuft torch auf 2.6.0+cu124 herunter, torchvision bleibt auf
#     0.24.0+cu128 -> "operator torchvision::nms does not exist" -> der transformers-
#     Lazy-Import stirbt mit "Could not import module 'LlamaModel'".
#     Reparatur: das gepinnte Triple (torch/torchvision/torchaudio cu128) NACH
#     chatterbox erneut installieren.
#
#   MODELS=1 bash tts_install2.sh    # + Modelle vorladen (~18 GB)
#   MODELS=0 bash tts_install2.sh    # nur Pakete
set -uo pipefail
LOG=/workspace/tts_install2.log
TTS_VENV=/workspace/ttsvenv        # Chatterbox
QWEN_VENV=/workspace/qwenvenv      # Qwen3-TTS VoiceDesign
TTS_STAGE=/workspace/tts_models
TORCH_INDEX="https://download.pytorch.org/whl/cu128"
TORCH_PIN=("torch==2.9.0+cu128" "torchvision==0.24.0+cu128" "torchaudio==2.9.0+cu128")
MODELS="${MODELS:-0}"
UV=/usr/bin/uv

say() { echo "[$(date -u '+%H:%M:%S')] $*" | tee -a "$LOG"; }

mkvenv() {
    if [ ! -x "$1/bin/python" ]; then
        say "venv anlegen: $1"
        "$UV" venv "$1" --python /workspace/venv/bin/python >>"$LOG" 2>&1 || say "WARNUNG: venv $1 fehlgeschlagen"
    else
        say "venv vorhanden: $1"
    fi
}

inst_torch() {
    say "   torch-Triple (cu128) für $1"
    "$UV" pip install --python "$1" --index-url "$TORCH_INDEX" "${TORCH_PIN[@]}" >>"$LOG" 2>&1 \
        && say "   torch ok" || say "   WARNUNG: torch fehlgeschlagen"
}

say "=== TTS-Installation (Zwei-venv-Aufbau, MODELS=$MODELS) ==="

# ---- 1) Chatterbox (Klangfarbe per Referenzstimme + exaggeration) -----------
mkvenv "$TTS_VENV"
inst_torch "$TTS_VENV/bin/python"
say "chatterbox-tts installieren"
"$UV" pip install --python "$TTS_VENV/bin/python" chatterbox-tts soundfile "huggingface_hub[cli]" \
    >>"$LOG" 2>&1 && say "   chatterbox ok" || say "   WARNUNG: chatterbox fehlgeschlagen"
# ---- Konflikt 2: Triple nach chatterbox REPARIEREN (torch-Downgrade!) -------
say "torch-Triple nach chatterbox wiederherstellen (verhindert torchvision::nms-Fehler)"
inst_torch "$TTS_VENV/bin/python"

# ---- 2) Qwen3-TTS VoiceDesign (Identität per Textbeschreibung) --------------
mkvenv "$QWEN_VENV"
inst_torch "$QWEN_VENV/bin/python"
say "qwen-tts installieren"
"$UV" pip install --python "$QWEN_VENV/bin/python" qwen-tts soundfile >>"$LOG" 2>&1 \
    && say "   qwen-tts ok" || say "   WARNUNG: qwen-tts fehlgeschlagen"
inst_torch "$QWEN_VENV/bin/python"

say "Import-Test:"
for py in "$TTS_VENV/bin/python" "$QWEN_VENV/bin/python"; do
    say "  $py"
    "$py" - <<'PY' 2>&1 | sed 's/^/    /' | tee -a "$LOG"
import importlib
for m in ("torch", "torchvision", "torchaudio", "soundfile", "chatterbox", "qwen_tts", "transformers"):
    try:
        mod = importlib.import_module(m)
        print(f"  ok  {m} {getattr(mod, '__version__', '')}")
    except Exception as e:
        print(f"  --  {m}: {str(e)[:80]}")
PY
done

# ---- 3) Modelle vorladen ----------------------------------------------------
if [ "$MODELS" = "1" ]; then
    mkdir -p "$TTS_STAGE"
    export HF_HOME="$TTS_STAGE/.hf"
    tok=""
    [ -s /workspace/.hf_token ] && tok="$(tr -d '[:space:]' < /workspace/.hf_token)"
    hfdl() {
        local repo="$1" dir="$2" tool="$3" args=()
        [ -n "$tok" ] && args=(--token "$tok")
        if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then say "   vorhanden: $repo"; return 0; fi
        say "   lade: $repo"
        "$tool" download "$repo" --local-dir "$dir" ${args[@]+"${args[@]}"} >>"$LOG" 2>&1 \
            && say "   ok: $repo" || say "   WARNUNG: $repo fehlgeschlagen"
    }
    hfdl "Qwen/Qwen3-TTS-Tokenizer-12Hz"        "$TTS_STAGE/qwen3tts-tokenizer" "$QWEN_VENV/bin/hf"
    hfdl "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign" "$TTS_STAGE/qwen3tts-voicedesign" "$QWEN_VENV/bin/hf"
    hfdl "ResembleAI/chatterbox"                "$TTS_STAGE/chatterbox" "$TTS_VENV/bin/hf"
    du -sh "$TTS_STAGE" 2>/dev/null | tee -a "$LOG"
fi

say "=== TTS-Installation beendet ==="
