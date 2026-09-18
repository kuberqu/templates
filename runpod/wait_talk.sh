#!/usr/bin/env bash
# Wartet auf den Sprech-Test, holt das Video und schickt es + Pegelvergleich.
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"

echo "Sprech-Wächter gestartet $(date -u '+%H:%M:%S UTC')"
for i in $(seq 1 85); do
    flag=$($POD 'grep -c KETTE_FERTIG /workspace/talk_test.log 2>/dev/null' 2>/dev/null | tr -d '\r')
    if [ "$flag" = "1" ]; then
        echo "fertig nach $((i*20))s"
        break
    fi
    sleep 20
done

echo
echo "=== Testlog ==="
$POD 'cat /workspace/talk_test.log'
echo
echo "=== Ergebnis ==="
OUT=$($POD 'ls -t /workspace/ComfyUI/output/ltx_test/talk*.mp4 2>/dev/null | head -1' | tr -d '\r')
echo "$OUT"
if [ -n "$OUT" ]; then
    mkdir -p /home/claw/workspace/runpod-lipsync/ltx_out
    scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 "root@194.68.245.49:$OUT" /home/claw/workspace/runpod-lipsync/ltx_out/
    LOCAL=/home/claw/workspace/runpod-lipsync/ltx_out/$(basename "$OUT")
    ls -la "$LOCAL"
    echo "=== Format + Pegel ==="
    ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,codec_type,width,height,r_frame_rate -of default=noprint_wrappers=1 "$LOCAL" 2>&1 | head -14
    ffmpeg -i "$LOCAL" -af volumedetect -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume"
    echo "=== Referenz-Audio zum Vergleich ==="
    ffmpeg -i /home/claw/workspace/runpod-lipsync/narration_florian.mp3 -af volumedetect -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume" 2>/dev/null || true
    echo "=== Telegram ==="
    hermes send --to telegram:27900483 "MEDIA:$LOCAL" 2>&1 | tail -1
fi
echo "=== fertig $(date -u '+%H:%M:%S UTC') ==="
