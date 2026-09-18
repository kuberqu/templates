#!/usr/bin/env bash
# Wartet auf den fertigen Short, holt ihn, prueft Bild/Ton und schickt ihn per Telegram.
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"
BASE=/workspace/shorts/hummer_lobster

echo "Short-Wächter gestartet $(date -u '+%H:%M:%S UTC')"
for i in $(seq 1 58); do
    flag=$($POD "grep -c -E 'SHORT_FERTIG|SHORT_UNVOLLSTAENDIG' /workspace/shorts_clips2.log 2>/dev/null" 2>/dev/null | tr -d '\r')
    if [ -n "$flag" ] && [ "$flag" != "0" ]; then echo "fertig nach $((i*30))s"; break; fi
    sleep 30
done

echo
echo "=== Log (Ende) ==="
$POD "tail -22 /workspace/shorts_clips2.log"
echo
echo "=== Clips ==="
$POD "ls $BASE/clips/ 2>/dev/null | wc -l"
OUT=$($POD "ls -t $BASE/short_final.mp4 2>/dev/null | head -1" | tr -d '\r')
if [ -n "$OUT" ]; then
    mkdir -p /home/claw/workspace/runpod-lipsync/shorts/hummer_lobster
    scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 "root@194.68.245.49:$OUT" /home/claw/workspace/runpod-lipsync/shorts/hummer_lobster/
    L=/home/claw/workspace/runpod-lipsync/shorts/hummer_lobster/short_final.mp4
    ls -la "$L"
    ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,width,height,r_frame_rate,sample_rate -of default=noprint_wrappers=1 "$L" 2>&1 | head -16
    ffmpeg -i "$L" -af volumedetect -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume"
    echo "=== Telegram ==="
    hermes send --to telegram:27900483 "MEDIA:$L" 2>&1 | tail -1
fi
echo "=== fertig $(date -u '+%H:%M:%S UTC') ==="
