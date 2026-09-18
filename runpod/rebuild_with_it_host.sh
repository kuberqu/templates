#!/usr/bin/env bash
# Host-Clip der Hummer-Folge auf InfiniteTalk umstellen und neu schneiden.
#
# Ablauf:
#   1. warten, bis der ESRGAN-Upscale alle 77 Frames geschrieben hat
#   2. Frames + Original-Ton -> clips/clip_01.mp4 (1080x1872, 25 fps)
#   3. alten Wav2Lip-Clip als clip_01_wav2lip.mp4 sichern
#   4. compose.py (OpenMontage-venv) -> short_final.mp4
#   5. pruefen (Dauer, Aufloesung, Lautheit) und lokal abholen
#
# Aufruf lokal: bash rebuild_with_it_host.sh
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -o ServerAliveInterval=30 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"
BASE=/workspace/shorts/hummer_lobster
OUT=/workspace/ComfyUI/output
D=/home/claw/workspace/runpod-lipsync/shorts/hummer_lobster
LOG=/home/claw/workspace/runpod-lipsync/shorts/rebuild_it.log
: > "$LOG"

echo "1) warte auf Upscale" | tee -a "$LOG"
# ACHTUNG Eigenmatch: `pgrep -f run_upscale_it` findet den eigenen bash -c-Aufruf
# (die Kommandozeile enthaelt das Muster) und lief hier 20 Min ins Leere.
# Bracket-Trick: das Muster matcht sich selbst nicht mehr.
for i in $(seq 1 60); do
  $POD 'pgrep -f "run_upscale_i[t]" >/dev/null' 2>/dev/null || break
  sleep 20
done
N=$($POD "ls $OUT/upit_*.png 2>/dev/null | wc -l" | tr -d '\r')
echo "   Frames: $N" | tee -a "$LOG"
if [ "$N" -lt 77 ]; then
  echo "ABBRUCH: nur $N von 77 Frames" | tee -a "$LOG"; exit 1
fi

echo "2) Clip zusammensetzen" | tee -a "$LOG"
$POD "cd $OUT && rm -f clip_01_it.mp4 && ffmpeg -y -v error -framerate 25 -start_number 1 -i upit_%05d_.png \
  -i talk_it_00001_.mp4 -map 0:v -map 1:a -c:v libx264 -crf 18 -preset medium \
  -pix_fmt yuv420p -c:a copy clip_01_it.mp4 && \
  ffprobe -v error -select_streams v -show_entries stream=width,height,r_frame_rate \
  -of csv=p=0 clip_01_it.mp4" 2>&1 | tee -a "$LOG"

# HARTE PRUEFUNG: ohne sie wuerde ein fehlgeschlagenes ffmpeg den alten Wav2Lip-Clip
# stehen lassen und der Schnitt liefe mit dem ALTEN Host durch (genau der Fehler,
# der nicht passieren darf). Frame-Zahl mit -count_frames ist belastbar.
FR=$($POD "ffprobe -v error -select_streams v -count_frames -show_entries stream=nb_read_frames -of csv=p=0 $OUT/clip_01_it.mp4 2>/dev/null" | tr -d '\r')
echo "   Frames im neuen Host-Clip: '$FR'" | tee -a "$LOG"
if [ "$FR" != "77" ]; then
  echo "ABBRUCH: neuer Clip hat '$FR' statt 77 Frames - Host wird NICHT getauscht" | tee -a "$LOG"; exit 1
fi

echo "3) Host-Clip tauschen (Wav2Lip gesichert)" | tee -a "$LOG"
# ACHTUNG: Das Backup MUSS aus dem clips/-Ordner heraus. compose.py sammelt die
# Clips per Glob `clip_*.mp4` — ein Backup namens clip_01_wav2lip.mp4 matcht das
# Muster, wird einsortiert (clip_01.mp4 < clip_01_wav2lip.mp4 < clip_02.mp4) und
# landet als zusätzliche Szene im Video (real passiert: 46,04s statt 44,80s, drei
# Sekunden altes Wav2Lip-Bild hinter Szene 1).
$POD "cd $BASE/clips && [ -f clip_01.mp4 ] && cp clip_01.mp4 ../clip_01_wav2lip_backup.mp4; \
  cp $OUT/clip_01_it.mp4 clip_01.mp4 && ls -la clip_01.mp4 ../clip_01_wav2lip_backup.mp4" 2>&1 | tee -a "$LOG"
# Beweis, dass wirklich der neue Clip im Projektordner liegt (md5-Vergleich)
SRC=$($POD "md5sum $OUT/clip_01_it.mp4 | cut -d' ' -f1" | tr -d '\r')
DST=$($POD "md5sum $BASE/clips/clip_01.mp4 | cut -d' ' -f1" | tr -d '\r')
echo "   md5 neu=$SRC im Projekt=$DST" | tee -a "$LOG"
if [ "$SRC" != "$DST" ]; then
  echo "ABBRUCH: Host-Clip im Projekt ist NICHT der neue Render" | tee -a "$LOG"; exit 1
fi
# Und: der clips/-Ordner muss GENAU 10 Dateien enthalten (Schutz vor Streu-Dateien)
NC=$($POD "ls $BASE/clips/clip_*.mp4 | wc -l" | tr -d '\r')
echo "   Clips im Ordner: $NC" | tee -a "$LOG"
if [ "$NC" != "10" ]; then
  echo "ABBRUCH: $NC Clips im Ordner (erwartet 10) - Glob-Falle!" | tee -a "$LOG"; exit 1
fi

BEFORE=$($POD "stat -c %Y $BASE/short_final.mp4 2>/dev/null || echo 0" | tr -d '\r')
echo "4) Schnitt" | tee -a "$LOG"
$POD "cd /workspace && /workspace/OpenMontage/.venv/bin/python -u compose.py $BASE 2>&1 | tail -8" | tee -a "$LOG"
AFTER=$($POD "stat -c %Y $BASE/short_final.mp4 2>/dev/null || echo 0" | tr -d '\r')
if [ "$AFTER" = "$BEFORE" ] || [ "$AFTER" = "0" ]; then
  echo "ABBRUCH: short_final.mp4 nicht neu geschrieben" | tee -a "$LOG"; exit 1
fi

echo "5) abholen + pruefen" | tee -a "$LOG"
$POD "cat $BASE/short_final.mp4" > "$D/short_final_infinitetalk.mp4"
L="$D/short_final_infinitetalk.mp4"
ls -la "$L" | tee -a "$LOG"
md5sum "$L" | tee -a "$LOG"
$POD "md5sum $BASE/short_final.mp4" | tee -a "$LOG"
ffprobe -v error -select_streams v -show_entries stream=width,height,r_frame_rate \
  -show_entries format=duration -of default=noprint_wrappers=1 "$L" | tee -a "$LOG"
ffmpeg -i "$L" -af volumedetect -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume" | tee -a "$LOG"

echo "6) Zustellung" | tee -a "$LOG"
hermes send --to telegram:27900483 --subject "[Freigabe] Hummer-Short (InfiniteTalk-Host)" \
  "MEDIA:$L" 2>&1 | tail -1 | tee -a "$LOG"
echo "KOMPLETT_FERTIG"
