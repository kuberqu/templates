#!/usr/bin/env bash
# fal.ai-Trainingsjob überwachen und die fertige LoRA automatisch abholen.
# Key liegt in ~/.hermes/credentials/fal_api_key (chmod 600) - wird nie ausgegeben.
set -u
ID=01a0b3f9-dbe6-7af1-b183-c28177c21bb4
EP=fal-ai/qwen-image-2512-trainer
DEST=/home/claw/workspace/runpod-lipsync/charakter/lora
S=/home/claw/workspace/runpod-lipsync/fal_status.py
mkdir -p "$DEST"

echo "fal-Wächter gestartet $(date -u '+%H:%M:%S UTC') | Job $ID"
for i in $(seq 1 70); do
    OUT=$(python3 "$S" --endpoint "$EP" --request-id "$ID" 2>&1 | head -3)
    ST=$(printf '%s' "$OUT" | grep -oE "IN_QUEUE|IN_PROGRESS|COMPLETED|FAILED" | head -1)
    printf '[%s] Laufzeit-Check %2d: %s\n' "$(date -u '+%H:%M:%S')" "$i" "${ST:-unbekannt}"
    case "$ST" in
        COMPLETED)
            echo "=== FERTIG — hole Ergebnis ==="
            python3 "$S" --endpoint "$EP" --request-id "$ID" --result --download "$DEST/" 2>&1 | tail -25
            echo "=== LoRA-Dateien ==="
            ls -la "$DEST" | tail -5
            echo "FAL_FERTIG"
            exit 0
            ;;
        FAILED)
            echo "=== Job FEHLGESCHLAGEN ==="
            python3 "$S" --endpoint "$EP" --request-id "$ID" --result 2>&1 | tail -20
            echo "FAL_FEHLER"
            exit 1
            ;;
    esac
    sleep 45
done
echo "FAL_TIMEOUT (nach ~52 Min Wartezeit)"
