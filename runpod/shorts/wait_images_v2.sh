#!/usr/bin/env bash
# Wartet auf die v2-Szenenbilder, holt sie und schickt eine Kontrollauswahl.
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"
DEST=/home/claw/workspace/runpod-lipsync/shorts/hummer_lobster/images

echo "v2-Bild-Wächter gestartet $(date -u '+%H:%M:%S UTC')"
for i in $(seq 1 70); do
    flag=$($POD 'grep -c IMAGES_V2_FERTIG /workspace/shorts_v2_chain.log 2>/dev/null' 2>/dev/null | tr -d '\r')
    if [ "$flag" = "1" ]; then echo "Bilder fertig nach $((i*20))s"; break; fi
    sleep 20
done

echo
echo "=== Log (Bildteil) ==="
$POD 'sed -n "1,20p" /workspace/shorts_v2_chain.log'
echo
echo "=== Bilder holen ==="
mkdir -p "$DEST"
scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 'root@194.68.245.49:/workspace/shorts/hummer_lobster/images/*' "$DEST/" 2>&1
ls "$DEST" | tr '\n' ' '
echo
echo "=== Kontrollauswahl an Telegram (Host + Schluesselszenen) ==="
for n in 01 03 04 07 10; do
    f="$DEST/szene_${n}.png"
    [ -f "$f" ] && hermes send --to telegram:27900483 "MEDIA:$f" 2>&1 | tail -1
done
echo "=== fertig $(date -u '+%H:%M:%S UTC') ==="
