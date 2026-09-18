#!/usr/bin/env bash
# Kette im Pod: auf die fertigen Clips warten -> Schnitt ausfuehren.
# Log: /workspace/shorts_compose.log
set -u
P=/workspace/OpenMontage/.venv/bin/python
BASE=/workspace/shorts/hummer_lobster
LOG=/workspace/shorts_compose.log

: > "$LOG"
echo "=== Warte auf Clips $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
for i in $(seq 1 240); do            # bis 2 h
    if grep -q CLIPS_FERTIG /workspace/shorts_v2_chain.log 2>/dev/null; then
        echo "Clips fertig nach $((i*30))s" >> "$LOG"
        break
    fi
    sleep 30
done
N=$(ls "$BASE/clips" 2>/dev/null | wc -l)
echo "Clips vorhanden: $N" >> "$LOG"
if [ "$N" -lt 10 ]; then
    echo "⚠ nicht alle Clips da - Schnitt uebersprungen" >> "$LOG"
    echo "SHORT_UNVOLLSTAENDIG" >> "$LOG"
    exit 1
fi

echo "=== Schnitt $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
$P -u /workspace/compose.py "$BASE" >> "$LOG" 2>&1
echo "COMPOSE_EXIT=$?" >> "$LOG"
ls -la "$BASE/short_final.mp4" >> "$LOG" 2>&1
ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,width,height \
    -of default=noprint_wrappers=1 "$BASE/short_final.mp4" >> "$LOG" 2>&1
echo "SHORT_FERTIG $(date -u '+%H:%M:%S UTC')" >> "$LOG"
