#!/usr/bin/env bash
# Wartet auf das Ende der Test-Kette, holt das Ergebnis und schickt es per Telegram.
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"

echo "Wächter2 gestartet $(date -u '+%H:%M:%S UTC')"
for i in $(seq 1 85); do
    flag=$($POD 'grep -c "KETTE FERTIG" /workspace/ltx_official_test.log 2>/dev/null' 2>/dev/null | tr -d '\r')
    if [ "$flag" = "1" ]; then
        echo "Kette fertig nach $((i*20))s Wartezeit"
        break
    fi
    sleep 20
done

echo
echo "=== Matrix-Ergebnis (Steps-Effekt) ==="
$POD 'grep -A4 "A_steps4_lang" /workspace/ltx_audio_matrix.log | head -8'
echo
echo "=== Offizieller Graph: Log ==="
$POD 'cat /workspace/ltx_official_test.log'
echo
echo "=== Ergebnisdatei ==="
OUT=$($POD 'ls -t /workspace/ComfyUI/output/ltx_test/*.mp4 2>/dev/null | head -1' | tr -d '\r')
echo "$OUT"
if [ -n "$OUT" ]; then
    mkdir -p /home/claw/workspace/runpod-lipsync/ltx_out
    scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 "root@194.68.245.49:$OUT" /home/claw/workspace/runpod-lipsync/ltx_out/ 2>&1
    LOCAL=/home/claw/workspace/runpod-lipsync/ltx_out/$(basename "$OUT")
    ls -la "$LOCAL"
    ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,codec_type,width,height,r_frame_rate,channels -of default=noprint_wrappers=1 "$LOCAL" 2>&1 | head -20
    echo "=== Telegram ==="
    hermes send --to telegram:27900483 "MEDIA:$LOCAL" 2>&1 | tail -2
fi
echo "=== Wächter2 fertig $(date -u '+%H:%M:%S UTC') ==="
