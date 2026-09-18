#!/usr/bin/env bash
# 5-s-Testclip (9:16) mit Zeit- und VRAM-Messung. Läuft im Pod, Log unter /workspace.
set -u
LOG=/workspace/ltx_heavy_test.log
VRAM=/workspace/ltx_heavy_vram.csv
P=/workspace/venv/bin/python
rm -f "$VRAM"

echo "=== START $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===" > "$LOG"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader >> "$LOG"

# VRAM/Utilisation mitschreiben
( while true; do
    nvidia-smi --query-gpu=timestamp,memory.used,utilization.gpu,power.draw \
      --format=csv,noheader >> "$VRAM"
    sleep 15
  done ) &
MON=$!

T0=$(date +%s)
$P /workspace/ltx_generate.py \
  "Cinematic wide shot of a lone astronaut walking across a vast desert of red sand at golden hour, long shadows stretching behind, fine dust drifting in the wind, slow dolly forward, wind and distant footsteps" \
  --w 768 --h 1344 --frames 121 --steps 8 --seed 7 >> "$LOG" 2>&1
RC=$?
T1=$(date +%s)

kill $MON 2>/dev/null
sleep 1
echo "" >> "$LOG"
echo "=== GEN_EXIT=$RC  DAUER=$((T1-T0))s ($(echo "scale=1; ($T1-$T0)/60" | bc 2>/dev/null || echo "?") min) ===" >> "$LOG"
echo "--- VRAM-Verlauf (Peak zuerst) ---" >> "$LOG"
sort -t, -k2 -rn "$VRAM" 2>/dev/null | head -4 >> "$LOG"
echo "--- VRAM-Verlauf (letzte 4) ---" >> "$LOG"
tail -4 "$VRAM" >> "$LOG"

# Ergebnisdatei benennen
OUT=$(ls -t /workspace/ComfyUI/output/ltx_test/*.mp4 2>/dev/null | head -1)
if [ -n "$OUT" ]; then
    ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,width,height,r_frame_rate \
      -of default=noprint_wrappers=1 "$OUT" >> "$LOG" 2>&1
    echo "OUTFILE=$OUT" >> "$LOG"
fi
echo "=== ENDE $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
