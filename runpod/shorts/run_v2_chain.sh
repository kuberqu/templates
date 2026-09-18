#!/usr/bin/env bash
# Komplette Kette v2: alle 10 Szenenbilder neu -> dann alle 10 LTX-Clips.
# Laeuft im Pod, Log: /workspace/shorts_v2_chain.log
set -u
P=/workspace/venv/bin/python
BASE=/workspace/shorts/hummer_lobster
LOG=/workspace/shorts_v2_chain.log

: > "$LOG"
echo "=== Bilder v2 (10 Szenen) $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
rm -f "$BASE/images"/szene_*.png          # alte v1-Bilder raus, damit keine Mischung entsteht
$P -u /workspace/make_images.py "$BASE/script_v2.json" --out-dir "$BASE" >> "$LOG" 2>&1
echo "IMAGES_V2_FERTIG ($(ls "$BASE/images" | wc -l) Bilder)" >> "$LOG"

echo "=== Clips v2 $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
$P -u /workspace/make_clips.py "$BASE/script_v2.json" \
    --timing "$BASE/timing.json" --out-dir "$BASE" >> "$LOG" 2>&1
echo "CLIPS_EXIT=$?" >> "$LOG"
ls -la "$BASE/clips" >> "$LOG" 2>&1
echo "CLIPS_FERTIG $(date -u '+%H:%M:%S UTC')" >> "$LOG"
