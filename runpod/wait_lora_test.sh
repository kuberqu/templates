#!/usr/bin/env bash
# Wartet auf die LoRA-Testbilder (ohne / 1.0 / 0.8), holt sie und schickt sie per Telegram.
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"
DEST=/home/claw/workspace/runpod-lipsync/charakter/lora_test
mkdir -p "$DEST"

echo "LoRA-Test-Wächter gestartet $(date -u '+%H:%M:%S UTC')"
for i in $(seq 1 60); do
    n=$($POD 'ls /workspace/ComfyUI/output/lora_test/ 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r')
    if [ "${n:-0}" -ge 3 ]; then echo "3 Testbilder da nach $((i*20))s"; break; fi
    sleep 20
done

echo "=== Dateien ==="
$POD 'ls -la /workspace/ComfyUI/output/lora_test/ | tail -5'
scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 'root@194.68.245.49:/workspace/ComfyUI/output/lora_test/*' "$DEST/" 2>&1
echo
echo "=== Telegram (Kontrolle ohne / 1.0 / 0.8) ==="
for f in "$DEST"/*.png; do
    [ -f "$f" ] || continue
    label=$(basename "$f" | sed 's/lora_test_//; s/_00001_.png//')
    hermes send --to telegram:27900483 "MEDIA:$f" 2>&1 | tail -1
    echo "  gesendet: $(basename "$f")"
done
echo "=== fertig $(date -u '+%H:%M:%S UTC') ==="
