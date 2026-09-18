#!/usr/bin/env bash
# Clips neu erzeugen (Bilder sind fertig) -> danach automatisch Schnitt.
# Log: /workspace/shorts_clips2.log
set -u
P=/workspace/venv/bin/python
COMP=/workspace/OpenMontage/.venv/bin/python
BASE=/workspace/shorts/hummer_lobster
LOG=/workspace/shorts_clips2.log

: > "$LOG"
echo "=== Clips (nach input-Fix) $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
$P -u /workspace/make_clips.py "$BASE/script_v2.json" \
    --timing "$BASE/timing.json" --out-dir "$BASE" >> "$LOG" 2>&1
echo "CLIPS_EXIT=$?" >> "$LOG"
ls -la "$BASE/clips" >> "$LOG" 2>&1
N=$(ls "$BASE/clips" 2>/dev/null | wc -l)
echo "CLIPS_VORHANDEN=$N" >> "$LOG"

if [ "$N" -eq 10 ]; then
    echo "=== Schnitt $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
    $COMP -u /workspace/compose.py "$BASE" >> "$LOG" 2>&1
    echo "COMPOSE_EXIT=$?" >> "$LOG"
    ls -la "$BASE/short_final.mp4" >> "$LOG" 2>&1
    ffprobe -v error -show_entries format=duration,size \
        -show_entries stream=codec_name,width,height,r_frame_rate \
        -of default=noprint_wrappers=1 "$BASE/short_final.mp4" >> "$LOG" 2>&1
    echo "SHORT_FERTIG $(date -u '+%H:%M:%S UTC')" >> "$LOG"
else
    echo "SHORT_UNVOLLSTAENDIG (nur $N Clips)" >> "$LOG"
fi
