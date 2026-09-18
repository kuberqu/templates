#!/usr/bin/env bash
# Testmatrix: warum ist die Tonspur im 5-s-Lauf stumm?
# Variiert jeweils EINE Variable gegen den bekannten stummen Fall
# (768x1344, 121 Frames, 8 Steps = stumm / 512x896, 25 Frames, 4 Steps = Ton).
set -u
P=/workspace/venv/bin/python
OUT=/workspace/ltx_audio_matrix.log
PR="Cinematic wide shot of a lone astronaut walking across a vast desert of red sand at golden hour, long shadows stretching behind, fine dust drifting in the wind, slow dolly forward, wind and distant footsteps"

: > "$OUT"

run() {
    local label="$1" w="$2" h="$3" fr="$4" st="$5"
    echo "=== $label : ${w}x${h}, ${fr} Frames, ${st} Steps ===" | tee -a "$OUT"
    local t0; t0=$(date +%s)
    $P /workspace/ltx_generate.py "$PR" --w "$w" --h "$h" --frames "$fr" --steps "$st" --seed 7 \
        >> "$OUT" 2>&1
    local rc=$?
    local t1; t1=$(date +%s)
    local f; f=$(ls -t /workspace/ComfyUI/output/ltx_test/*.mp4 | head -1)
    echo "   exit=$rc dauer=$((t1-t0))s datei=$(basename "$f")" | tee -a "$OUT"
    # Audiopegel messen
    local lvl
    lvl=$(ffmpeg -i "$f" -af volumedetect -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume" | tr '\n' ' ')
    echo "   AUDIO: $lvl" | tee -a "$OUT"
    if echo "$lvl" | grep -qE "mean_volume: -[0-9]{1,2}\." ; then
        echo "   -> MIT TON" | tee -a "$OUT"
    else
        echo "   -> STUMM" | tee -a "$OUT"
    fi
    echo | tee -a "$OUT"
}

# A) Nur Steps geändert (4 statt 8) bei langer Sequenz
run "A_steps4_lang" 768 1344 121 4
# B) Nur Laenge geaendert (25 Frames) bei 8 Steps
run "B_kurz_steps8" 768 1344 25 8
# C) Nur Aufloesung geaendert (512x896) bei lang/8 Steps
run "C_klein_lang_steps8" 512 896 121 8
# D) 49 Frames (mittlere Laenge), 8 Steps
run "D_mittel" 768 1344 49 8

echo "=== MATRIX FERTIG $(date -u '+%H:%M:%S UTC') ===" | tee -a "$OUT"
