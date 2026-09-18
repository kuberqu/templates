#!/usr/bin/env bash
# Zwei schwache Szenen neu: Bilder 3+7 -> Clips 3+7 -> neuer Schnitt.
# Log: /workspace/shorts_fix2.log
set -u
P=/workspace/venv/bin/python
COMP=/workspace/OpenMontage/.venv/bin/python
BASE=/workspace/shorts/hummer_lobster
LOG=/workspace/shorts_fix2.log

: > "$LOG"
echo "=== Bilder 3+7 neu $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
$P -u /workspace/make_images.py "$BASE/script_v2.json" --out-dir "$BASE" --only 3,7 >> "$LOG" 2>&1

echo "=== Clips 3+7 neu $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
$P -u /workspace/make_clips.py "$BASE/script_v2.json" --timing "$BASE/timing.json" \
    --out-dir "$BASE" --only 3,7 >> "$LOG" 2>&1
echo "CLIPS_VORHANDEN=$(ls "$BASE/clips" | wc -l)" >> "$LOG"

echo "=== Neuer Schnitt $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
mv -f "$BASE/short_final.mp4" "$BASE/short_v1.mp4" 2>/dev/null || true
$COMP -u /workspace/compose.py "$BASE" >> "$LOG" 2>&1
echo "COMPOSE_EXIT=$?" >> "$LOG"
ls -la "$BASE/short_final.mp4" >> "$LOG" 2>&1
echo "FIX_FERTIG $(date -u '+%H:%M:%S UTC')" >> "$LOG"
