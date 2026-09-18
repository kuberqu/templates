#!/usr/bin/env bash
# Kette: Matrix-Lauf A abwarten -> Matrix stoppen -> offiziellen LTX-2.5-Graph testen.
set -u
P=/workspace/venv/bin/python
LOG=/workspace/ltx_official_test.log

echo "Kette gestartet $(date -u '+%H:%M:%S UTC')"

# 1) auf das Ergebnis von Matrix-Lauf A warten (höchstens 12 Minuten)
for i in $(seq 1 72); do
    if grep -q "AUDIO:" /workspace/ltx_audio_matrix.log 2>/dev/null; then
        echo "Matrix-Lauf A fertig nach $((i*10))s"
        break
    fi
    sleep 10
done
grep -A2 "A_steps4_lang" /workspace/ltx_audio_matrix.log | head -6

# 2) restliche Matrix-Laeufe stoppen (B, C, D brauchen wir nicht mehr)
pkill -f "audio_matrix.sh" 2>/dev/null
pkill -f "ltx_generate.py" 2>/dev/null
sleep 2
curl -s -m 8 -X POST http://127.0.0.1:8188/interrupt >/dev/null 2>&1
sleep 3

# 3) offizieller 2-Stufen-Workflow
echo "starte offiziellen Graphen $(date -u '+%H:%M:%S UTC')"
: > "$LOG"
$P /workspace/ltx_official.py \
  "Cinematic medium shot of a female news anchor in a modern studio, dark blue backdrop with soft rim light, she looks directly into the camera and speaks calmly, subtle head movement, shallow depth of field, quiet room tone and a soft fabric rustle" \
  --seconds 5 --width 720 --height 1280 --seed 42 >> "$LOG" 2>&1
echo "GEN_EXIT=$?" >> "$LOG"

# 4) Ergebnis pruefen
OUT=$(ls -t /workspace/ComfyUI/output/ltx_test/*.mp4 2>/dev/null | head -1)
echo "OUTFILE=$OUT" >> "$LOG"
if [ -n "$OUT" ]; then
    ffmpeg -i "$OUT" -af volumedetect -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume" >> "$LOG"
    ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,width,height,r_frame_rate -of default=noprint_wrappers=1 "$OUT" >> "$LOG" 2>&1
fi
echo "=== KETTE FERTIG $(date -u '+%H:%M:%S UTC') ===" >> "$LOG"
