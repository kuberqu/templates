#!/usr/bin/env bash
# Wartet auf den Datensatz-Build, holt ZIP + Vorschaubilder und schickt eine Auswahl.
set -u
POD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i /home/claw/.ssh/id_ed25519 -p 22014 root@194.68.245.49"
DEST=/home/claw/workspace/runpod-lipsync/charakter

echo "Datensatz-Wächter gestartet $(date -u '+%H:%M:%S UTC')"
for i in $(seq 1 70); do
    flag=$($POD 'grep -c ZIP_FERTIG /workspace/dataset_build.log 2>/dev/null' 2>/dev/null | tr -d '\r')
    if [ "$flag" = "1" ]; then
        echo "Datensatz fertig nach $((i*20))s"
        break
    fi
    sleep 20
done

echo
echo "=== Build-Log ==="
$POD 'cat /workspace/dataset_build.log | tail -24'
echo
echo "=== Datensatz-Inhalt ==="
$POD 'ls -la /workspace/dataset/ | tail -8; echo; echo "Dateien gesamt: $(ls /workspace/dataset | wc -l)"; echo; ls -la /workspace/charakter_dataset.zip 2>/dev/null | awk "{print \"ZIP: \" \$5 \" Bytes\"}"; echo; echo "--- Beispiel-Caption ---"; head -1 /workspace/dataset/01_frontal_studio.txt 2>/dev/null'

mkdir -p "$DEST/dataset"
scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 'root@194.68.245.49:/workspace/dataset/*' "$DEST/dataset/" 2>&1
scp -q -o StrictHostKeyChecking=no -i /home/claw/.ssh/id_ed25519 -P 22014 'root@194.68.245.49:/workspace/charakter_dataset.zip' "$DEST/" 2>&1
echo
echo "=== lokal ==="
ls "$DEST/dataset" | wc -l
ls -la "$DEST/charakter_dataset.zip" 2>/dev/null | awk '{print "ZIP lokal: " $5 " Bytes"}'

# Auswahl an Telegram (6 Ansichten)
for f in 01_frontal_studio 07_outfit_grey 10_buero 11_aussen 13_nahaufnahme 16_konferenz; do
    if [ -f "$DEST/dataset/$f.png" ]; then
        hermes send --to telegram:27900483 "MEDIA:$DEST/dataset/$f.png" 2>&1 | tail -1
    fi
done
echo "=== Wächter fertig $(date -u '+%H:%M:%S UTC') ==="
