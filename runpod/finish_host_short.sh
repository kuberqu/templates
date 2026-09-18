#!/usr/bin/env bash
# Clip 10 nachziehen, dann Schnitt - mit Pruefung, damit kein alter Stand rausgeht.
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"
BASE=/workspace/shorts/hummer_lobster
LOG=/home/claw/workspace/runpod-lipsync/shorts/finish_host.log
: > "$LOG"

echo "1) Clip 10 erzeugen" | tee -a "$LOG"
# Korrekte Signatur: <script.json> + --timing (aus dem Skript-Header)
$POD "/workspace/venv/bin/python -u $BASE/make_clips.py $BASE/script_v2.json --timing $BASE/timing.json --only 10 2>&1 | tail -3" | tee -a "$LOG"

N=$($POD "ls $BASE/clips/clip_*.mp4 2>/dev/null | wc -l" | tr -d "\r")
echo "   Clips vorhanden: $N" | tee -a "$LOG"
if [ "$N" -lt 10 ]; then
  echo "ABBRUCH: nur $N Clips - Schnitt uebersprungen (kein veralteter Versand)" | tee -a "$LOG"
  exit 1
fi

BEFORE=$($POD "stat -c %Y $BASE/short_final.mp4 2>/dev/null || echo 0" | tr -d "\r")
echo "2) Schnitt" | tee -a "$LOG"
$POD "cd /workspace && /workspace/OpenMontage/.venv/bin/python -u compose.py $BASE 2>&1 | tail -6" | tee -a "$LOG"

AFTER=$($POD "stat -c %Y $BASE/short_final.mp4 2>/dev/null || echo 0" | tr -d "\r")
if [ "$AFTER" = "$BEFORE" ] || [ "$AFTER" = "0" ]; then
  echo "ABBRUCH: short_final.mp4 wurde nicht neu geschrieben" | tee -a "$LOG"
  exit 1
fi

D=/home/claw/workspace/runpod-lipsync/shorts/hummer_lobster
scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 "root@194.68.245.49:$BASE/short_final.mp4" "$D/short_final_host.mp4"
L="$D/short_final_host.mp4"
echo "3) Pruefung" | tee -a "$LOG"
ls -la "$L" | tee -a "$LOG"
ffprobe -v error -show_entries format=duration -show_entries stream=width,height -of default=noprint_wrappers=1 "$L" | tee -a "$LOG"
ffmpeg -i "$L" -af volumedetect -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume" | tee -a "$LOG"
# Host-Szene pruefen: Mundbewegung im ersten Clip messen
ffmpeg -v error -i "$D/clips_clip_01_check.mp4" -f null /dev/null 2>/dev/null
$POD "cp $BASE/clips/clip_01.mp4 $BASE/clip_01_check.mp4"
scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 "root@194.68.245.49:$BASE/clip_01_check.mp4" "$D/clip_01_check.mp4"
rm -f /tmp/hc_*.png
ffmpeg -v error -i "$D/clip_01_check.mp4" -vf "crop=260:150:290:670,scale=130:75" -vsync 0 /tmp/hc_%03d.png 2>/dev/null
python3 - <<'EOF' | tee -a "$LOG"
from PIL import Image, ImageChops
import glob, statistics
fs = sorted(glob.glob("/tmp/hc_*.png"))
if len(fs) > 3:
    d = [statistics.mean(ImageChops.difference(Image.open(fs[i-1]).convert("L"), Image.open(fs[i]).convert("L")).getdata()) for i in range(1, len(fs))]
    print(f"   Mundbewegung im Host-Clip: max {max(d):.2f} mittel {statistics.mean(d):.2f} -> " + ("Synchron-Render aktiv" if max(d) > 8 else "PRUEFEN: kaum Bewegung"))
else:
    print("   Messung nicht moeglich (zu wenige Frames)")
EOF
echo "4) Zustellung" | tee -a "$LOG"
hermes send --to telegram:27900483 "MEDIA:$L" 2>&1 | tail -1 | tee -a "$LOG"
echo "KOMPLETT_FERTIG"
