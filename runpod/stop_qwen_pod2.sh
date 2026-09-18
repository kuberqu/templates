#!/usr/bin/env bash
# Qwen-Download auf Pod 2 stoppen (100-GB-Volume reicht nicht fuer Wan + Qwen).
# Der Wan/InfiniteTalk-Satz ist vollstaendig; der Qwen-Block (~52 GB) wuerde das
# Volume fuellen und damit auch die venv-/OpenMontage-Installation killen.
set -u
echo "=== vor dem Stopp $(date -u +%H:%M:%S) ==="
du -sh /workspace

A=$(pgrep -f "aria2[c]" | head -1)
if [ -n "${A:-}" ]; then
  P=$(ps -o ppid= -p "$A" | tr -d ' ')
  echo "aria2c=$A  Elternprozess=$P  cmd=$(tr '\0' ' ' < /proc/$A/cmdline | cut -c1-90)"
  kill -9 "$A" 2>/dev/null && echo "aria2c gestoppt"
  [ -n "$P" ] && [ "$P" != "1" ] && kill "$P" 2>/dev/null && echo "Download-Schleife ($P) gestoppt"
else
  echo "kein aria2c aktiv"
fi

sleep 2
# Reste der Qwen-Downloads entfernen (Teildateien + Platzhalter)
find /workspace/gen_models -name "*.aria2__temp" -delete 2>/dev/null
rm -f /workspace/gen_models/split_files/diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors \
      /workspace/gen_models/split_files/diffusion_models/qwen_image_edit_2511_int8_convrot.safetensors
echo "Reste entfernt"

echo "=== nach dem Stopp ==="
du -sh /workspace
pgrep -af "aria2[c]" >/dev/null && echo "ACHTUNG: aria2c laeuft noch" || echo "kein aria2c mehr"
echo "--- Wan-Satz (>100 MB) ---"
find /workspace/gen_models -type f -name "*.safetensors" -size +100M -printf "%s %p\n" \
  | awk '{printf "%6.2fGB %s\n", $1/1e9, $2}' | sort -rn
echo "--- Setup laeuft? ---"
pgrep -f "setup[.]sh" >/dev/null && echo "ja (Hauptphase)" || echo "nein"
echo "--- Phase ---"
tail -2 /workspace/comfyui_setup.log | cut -c1-140
