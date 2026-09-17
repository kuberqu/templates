# RunPod Template — Start & Recovery

## Startcommand (RunPod Template / Pod-Konfiguration)

⚠️ **Wichtig:** Der Startcommand lädt `entrypoint.sh` bei JEDEM Pod-Boot von
`raw.githubusercontent.com`. Genau hier lag am 17.09.2026 ein Fehler:

- `curl -f` erkennt abgebrochene Transfers NICHT. Auf dem RunPod-Netzwerk-Volume
  (`mfs#eur-is-1.runpod.net`) kann dabei eine **abgeschnittene** Datei liegen
  bleiben, die bash dann ausführt: `entrypoint.sh: line 121: syntax error near
  unexpected token '}'` → der entrypoint stirbt VOR dem ComfyUI-Start, der Pod
  ist per SSH erreichbar, aber ComfyUI läuft nicht.
- Der Fehler ist in **keiner** committeten Version des Skripts enthalten
  (alle bestehen `bash -n`) — es war eine unvollständig geschriebene Datei.

**Deshalb: Download auf Temp-Datei, Syntaxprüfung, erst dann ersetzen.**

```bash
bash -c "([ -f /start.sh ] && /start.sh &); exec >> /workspace/boot.log 2>&1; echo '=== Pod Boot ==='; sleep 2; \
EP=/workspace/entrypoint.sh; \
curl -fsSL --retry 5 --retry-connrefused --connect-timeout 15 https://raw.githubusercontent.com/kuberqu/templates/main/runpod/entrypoint.sh -o /tmp/entrypoint.sh.new && bash -n /tmp/entrypoint.sh.new && mv /tmp/entrypoint.sh.new $EP && chmod +x $EP \
  || echo 'WARNUNG: entrypoint.sh Download/Syntaxcheck fehlgeschlagen - nutze vorhandene Version'; \
RUN_IN_BACKGROUND=true bash $EP; sleep infinity"
```

Fallback: existiert `$EP` schon (persistentes `/workspace`), läuft bei
Download-Problemen die vorhandene Version weiter — kein toter Boot mehr.

## Manuelle Diagnose auf dem Pod

```bash
curl -sf http://127.0.0.1:8188/system_stats                 # läuft ComfyUI?
cat /workspace/lipsync_status.json                          # Boot-Status (entrypoint)
cat /workspace/setup_status.json                            # Setup-Phasen (setup.sh)
tail -50 /workspace/comfyui_boot.log                        # entrypoint-Log
tail -50 /workspace/comfyui_server.log                      # ComfyUI-Log
tail -50 /workspace/comfyui_setup.log                       # Installer-Log
```

## Reparatur / erneutes Setup

```bash
bash /workspace/setup.sh && bash /workspace/entrypoint.sh   # vollständig
bash /workspace/entrypoint.sh                               # nur Fast-Boot + Server
```

Der entrypoint erkennt einen kaputten Python-Stack per echter Import-Prüfung
(`torch` CUDA, `mediapipe==0.10.21` inkl. `mediapipe.framework.formats`,
`numpy` 1.26.x, `onnxruntime`-Provider) und ruft dann `setup.sh` selbst auf.

## Smoke-Test (LivePortrait, API)

```bash
/workspace/venv/bin/python /workspace/test_lp_smoke.py      # 78 Frames, ~45s
ls -la /workspace/ComfyUI/output/lp_smoke_*.mp4
```

Testet die komplette Node-Kette zur Laufzeit — genau der Pfad, der bei
`mediapipe 1.0.x` mit `ModuleNotFoundError: mediapipe.framework` stirbt.
