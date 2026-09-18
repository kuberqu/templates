#!/usr/bin/env bash
# Offizieller LTX-2.5-Graph: Einzellauf + Pegel-/Formatpruefung.
# Setzt am Ende 'KETTE FERTIG' ins Log, damit der Wächter (wait_official.sh) triggert.
set -u
P=/workspace/venv/bin/python
LOG=/workspace/ltx_official_test.log

# Alte Wartekette + Matrix-Reste beenden (nicht sich selbst!)
pkill -f "run_official_test.sh" 2>/dev/null
pkill -f "audio_matrix.sh" 2>/dev/null
pkill -f "ltx_generate.py" 2>/dev/null
sleep 2
curl -s -m 8 -X POST http://127.0.0.1:8188/interrupt >/dev/null 2>&1
sleep 2

: > "$LOG"
echo "=== Start $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
$P /workspace/ltx_official.py \
  "Cinematic medium shot of a female news anchor in a modern studio, dark blue backdrop with soft rim light, she looks directly into the camera and speaks calmly, subtle head movement, shallow depth of field, quiet room tone and a soft fabric rustle" \
  --seconds 5 --width 720 --height 1280 --seed 42 >> "$LOG" 2>&1
echo "GEN_EXIT=$?" >> "$LOG"

OUT=$(ls -t /workspace/ComfyUI/output/ltx_test/*.mp4 2>/dev/null | head -1)
echo "OUTFILE=$OUT" >> "$LOG"
if [ -n "$OUT" ]; then
    echo "--- AUDIO ---" >> "$LOG"
    ffmpeg -i "$OUT" -af volumedetect -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume" >> "$LOG"
    echo "--- FORMAT ---" >> "$LOG"
    ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,width,height,r_frame_rate \
        -of default=noprint_wrappers=1 "$OUT" >> "$LOG" 2>&1
fi
echo "=== KETTE FERTIG $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
