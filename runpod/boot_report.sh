#!/usr/bin/env bash
# ============================================================
# Boot-Report — prüft einen Pod-Start in einem Durchgang.
# Aufruf auf dem Pod:  bash /workspace/boot_report.sh [--smoke]
#   --smoke  zusätzlich den LivePortrait-Smoke-Test (~40s) fahren
# Exit 0 = alles grün, 1 = mindestens eine Prüfung rot.
# ============================================================
set -uo pipefail
VENV=/workspace/venv
SMOKE=0
[ "${1:-}" = "--smoke" ] && SMOKE=1

FAIL=0
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=1; }
warn() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
hdr()  { printf '\n=== %s ===\n' "$*"; }

hdr "Container"
UP=$(awk '{printf "%d", $1}' /proc/uptime)
printf '  uptime         : %d Min %ds\n' $((UP / 60)) $((UP % 60))
printf '  Zeit (UTC)     : %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  GPU            : /' || warn "nvidia-smi nicht verfügbar"

hdr "entrypoint (Boot-Modus & Dauer)"
if [ -f /workspace/lipsync_status.json ]; then
    cat /workspace/lipsync_status.json
    echo
    MODE=$("$VENV/bin/python" -c "import json;print(json.load(open('/workspace/lipsync_status.json')).get('boot_mode'))" 2>/dev/null)
    case "$MODE" in
        fast) ok "Fast-Boot (Workspace war intakt)" ;;
        full) ok "Volleinrichtung (setup.sh lief)" ;;
        *)    warn "boot_mode unbekannt: '$MODE'" ;;
    esac
else
    bad "lipsync_status.json fehlt — entrypoint lief nicht durch"
fi
grep -a "Initialisiere Pod-Umgebung\|Fast-Boot\|Setup/Reparatur\|bereit nach\|Alle Kern\|ComfyUI läuft" \
    /workspace/comfyui_boot.log 2>/dev/null | tail -6 | sed 's/^/  /'

hdr "setup.sh (Phasen & Laufzeit)"
if [ -f /workspace/setup_status.json ]; then
    cat /workspace/setup_status.json; echo
    FEHL=$("$VENV/bin/python" -c "import json;d=json.load(open('/workspace/setup_status.json'));print(len(d.get('failed_phases',[])))" 2>/dev/null)
    if [ "${FEHL:-1}" = "0" ]; then ok "Keine fehlgeschlagenen Phasen"; else bad "$FEHL fehlgeschlagene Phase(n)"; fi
else
    warn "setup_status.json fehlt (kein setup.sh-Lauf in diesem Boot — bei Fast-Boot normal)"
fi
grep -a "langsamste Phase\|GESAMT:" /workspace/comfyui_setup.log 2>/dev/null | tail -6 | sed 's/^/  /'

hdr "ComfyUI"
PROCS=$(pgrep -c -f "ComfyUI/mai[n].py" 2>/dev/null || echo 0)
if [ "$PROCS" = "1" ]; then ok "genau 1 ComfyUI-Prozess"; else bad "$PROCS ComfyUI-Prozesse (erwartet: 1)"; fi
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8188/system_stats 2>/dev/null || echo 000)
if [ "$HTTP" = "200" ]; then ok "API antwortet (HTTP 200)"; else bad "API antwortet nicht (HTTP $HTTP)"; fi

if [ "$HTTP" = "200" ]; then
    RES=$("$VENV/bin/python" - <<'PYEOF' 2>/dev/null
import json, urllib.request
d = json.load(urllib.request.urlopen("http://127.0.0.1:8188/object_info", timeout=90))
req = ["Wav2Lip", "SadTalker", "LivePortraitProcess", "LivePortraitCropper",
       "LivePortraitRetargeting", "LivePortraitComposite", "VHS_VideoCombine"]
missing = [n for n in req if n not in d]
print("MISSING=" + ",".join(missing))
print("COUNT=%d" % len(d))
PYEOF
)
    MISS=$(echo "$RES" | sed -n 's/^MISSING=//p')
    CNT=$(echo "$RES" | sed -n 's/^COUNT=//p')
    if [ -z "$MISS" ]; then ok "alle Kern-Nodes registriert ($CNT Nodes total)"; else bad "fehlende Nodes: $MISS"; fi
fi

hdr "Python-Stack"
"$VENV/bin/python" - <<'PYEOF' 2>&1 | sed 's/^/  /'
import torch, numpy, mediapipe, soundfile, insightface, onnxruntime
from mediapipe.framework.formats import landmark_pb2  # noqa
print(f"torch {torch.__version__} cuda={torch.cuda.is_available()} | mediapipe {mediapipe.__version__}"
      f" | numpy {numpy.__version__} | onnxruntime {onnxruntime.__version__}")
print("mediapipe.framework.formats OK | soundfile OK | insightface OK")
PYEOF
[ ${PIPESTATUS[0]} -eq 0 ] && ok "Imports vollständig" || bad "Import-Prüfung fehlgeschlagen"

hdr "OpenMontage"
if [ -x /workspace/OpenMontage/.venv/bin/python ]; then
    printf '  venv           : %s\n' "$(/workspace/OpenMontage/.venv/bin/python -V 2>&1)"
    printf '  node           : %s\n' "$(node -v 2>/dev/null || echo 'fehlt')"
    [ -f /workspace/OpenMontage/tools/video/remotion_caption_burn.py ] && \
        printf '  staticFile-Patch: %s\n' "$(grep -c 'talking-head/{video_filename}' /workspace/OpenMontage/tools/video/remotion_caption_burn.py)"
    cd /workspace/OpenMontage && ./.venv/bin/python -c "
from tools.tool_registry import registry
registry.discover()
print('  video_compose  :', type(registry.get('video_compose')).__name__)
import aiohttp, pydub, edge_tts
print('  OM Runtime-Deps: aiohttp/pydub/edge_tts OK')" 2>&1 | sed 's/^/  /' | tail -3
else
    warn "OM-venv fehlt"
fi

if [ "$SMOKE" = "1" ]; then
    hdr "Smoke-Test (LivePortrait, ~40s)"
    if [ -f /workspace/test_lp_smoke.py ]; then
        if "$VENV/bin/python" /workspace/test_lp_smoke.py 2>&1 | tail -4 | sed 's/^/  /'; then
            ok "Smoke-Test durchgelaufen"
        else
            bad "Smoke-Test fehlgeschlagen"
        fi
    else
        warn "test_lp_smoke.py fehlt"
    fi
fi

hdr "Ergebnis"
if [ "$FAIL" = "0" ]; then ok "BOOT-REPORT: ALLES GRÜN"; else bad "BOOT-REPORT: FEHLER VORHANDEN"; fi
exit "$FAIL"
