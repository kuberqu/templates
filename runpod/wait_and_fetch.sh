#!/usr/bin/env bash
# Wartet auf das Ende des 5-s-LTX-Tests, holt den Clip und schickt ihn per Telegram.
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"

echo "Wächter gestartet $(date -u '+%H:%M:%S UTC')"
for i in $(seq 1 80); do
    done_flag=$($POD 'grep -c "=== ENDE" /workspace/ltx_heavy_test.log 2>/dev/null' 2>/dev/null | tr -d '\r')
    if [ "$done_flag" = "1" ]; then
        echo "Test fertig nach $((i*20))s Wartezeit"
        break
    fi
    sleep 20
done

echo
echo "=== TESTLOG ==="
$POD 'tail -22 /workspace/ltx_heavy_test.log'
echo
echo "=== VRAM-PEAK ==="
$POD 'sort -t, -k2 -rn /workspace/ltx_heavy_vram.csv 2>/dev/null | head -3'

OUT=$($POD 'ls -t /workspace/ComfyUI/output/ltx_test/*.mp4 2>/dev/null | head -1' | tr -d '\r')
echo
echo "=== Ergebnisdatei: $OUT ==="
if [ -n "$OUT" ]; then
    mkdir -p /home/claw/workspace/runpod-lipsync/ltx_out
    scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 "root@194.68.245.49:$OUT" /home/claw/workspace/runpod-lipsync/ltx_out/ 2>&1
    LOCAL=/home/claw/workspace/runpod-lipsync/ltx_out/$(basename "$OUT")
    ls -la "$LOCAL"
    ffprobe -v error -show_entries format=duration,size,bit_rate -show_entries stream=codec_name,codec_type,width,height,r_frame_rate,sample_rate,channels -of default=noprint_wrappers=1 "$LOCAL" 2>&1 | head -24
    echo "=== Telegram ==="
    hermes send --to telegram:27900483 "MEDIA:$LOCAL" 2>&1 | tail -2
fi
echo
echo "=== Wächter fertig $(date -u '+%H:%M:%S UTC') ==="
