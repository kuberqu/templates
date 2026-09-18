#!/usr/bin/env bash
# Kette: auf die 2 fehlenden Szenenbilder warten -> alle 10 LTX-Clips erzeugen.
# Laeuft im Pod, Log: /workspace/shorts_clips.log
set -u
P=/workspace/venv/bin/python
BASE=/workspace/shorts/hummer_lobster
LOG=/workspace/shorts_clips.log

: > "$LOG"
echo "=== Warte auf Bilder $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
for i in $(seq 1 40); do
    if grep -q IMAGES2_FERTIG /workspace/shorts_images2.log 2>/dev/null; then
        echo "Bilder fertig nach $((i*15))s" >> "$LOG"
        break
    fi
    sleep 15
done
N=$(ls "$BASE/images" | wc -l)
echo "Bilder vorhanden: $N/10" >> "$LOG"
for id in 01 02 03 04 05 06 07 08 09 10; do
    [ -f "$BASE/images/szene_$id.png" ] || echo "  FEHLT: szene_$id.png" >> "$LOG"
done

echo "=== Starte Clips $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
$P -u /workspace/make_clips.py "$BASE/script_v2.json" \
    --timing "$BASE/timing.json" --out-dir "$BASE" >> "$LOG" 2>&1
echo "CLIPS_EXIT=$?" >> "$LOG"
echo "=== Clips fertig $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
ls -la "$BASE/clips" | tail -12 >> "$LOG"
echo "CLIPS_FERTIG" >> "$LOG"
