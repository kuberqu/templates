#!/usr/bin/env bash
# Wartet auf den überarbeiteten Short, holt ihn und schickt ihn per Telegram.
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"
BASE=/workspace/shorts/hummer_lobster

echo "Fix-Wächter gestartet $(date -u '+%H:%M:%S UTC')"
for i in $(seq 1 58); do
    flag=$($POD "grep -c FIX_FERTIG /workspace/shorts_fix2.log 2>/dev/null" 2>/dev/null | tr -d '\r')
    if [ "$flag" = "1" ]; then echo "fertig nach $((i*30))s"; break; fi
    sleep 30
done

echo
echo "=== Log ==="
$POD "tail -14 /workspace/shorts_fix2.log"
echo
OUT=$($POD "ls -t $BASE/short_final.mp4 2>/dev/null | head -1" | tr -d '\r')
if [ -n "$OUT" ]; then
    mkdir -p /home/claw/workspace/runpod-lipsync/shorts/hummer_lobster
    scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 "root@194.68.245.49:$OUT" /home/claw/workspace/runpod-lipsync/shorts/hummer_lobster/short_final_v2.mp4 2>&1
    L=/home/claw/workspace/runpod-lipsync/shorts/hummer_lobster/short_final_v2.mp4
    ls -la "$L"
    ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,width,height -of default=noprint_wrappers=1 "$L" 2>&1 | head -8
    ffmpeg -i "$L" -af volumedetect -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume"
    # Frames der beiden neuen Szenen (3 = ~8-13s, 7 = ~25-29s)
    rm -f /home/claw/workspace/runpod-lipsync/shorts/hummer_lobster/fx_*.jpg
    ffmpeg -v error -i "$L" -vf "select='eq(n\,260)+eq(n\,660)',scale=405:720" -vsync 0 \
        /home/claw/workspace/runpod-lipsync/shorts/hummer_lobster/fx_%d.jpg 2>/dev/null
    ls /home/claw/workspace/runpod-lipsync/shorts/hummer_lobster/fx_*.jpg 2>/dev/null
    echo "=== Telegram ==="
    hermes send --to telegram:27900483 "MEDIA:$L" 2>&1 | tail -1
fi
echo "=== fertig $(date -u '+%H:%M:%S UTC') ==="
