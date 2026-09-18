# RunPod Template — Start & Recovery

## Generative Modelle (LTX-2.5 / Qwen-Image) — Setup-Schalter

`setup.sh` lädt seit 18.09.2026 zusätzlich die Modelle für Video-/Bildgenerierung
(~92 GB) als **zweite parallele Phase**. Steuerung:

| Variable | Wirkung | Default |
|---|---|---|
| `INSTALL_GEN` | `1` = Gen-Modelle laden, `0` = überspringen | `1` |
| `INSTALL_GEN_LORA` | `1` = LTX-2.5 distilled-LoRA (8,9 GB) zusätzlich | `0` |
| `HF_TOKEN` | Hugging-Face-Token (**read** genügt, fineGrained ok). Ohne Token wird die Phase **übersprungen statt zu scheitern** | – |
| `HF_TOKEN_FILE` | Datei mit dem Token (Fallback) | `/workspace/.hf_token` |

**Pflicht für den Download:** HF-Lizenz für `Lightricks/LTX-2.5` (gated) mit dem
Account akzeptieren, dessen Token gesetzt ist. Am saubersten `HF_TOKEN` als
**Template-Env** setzen — Achtung: `/workspace` ist ein Netzwerk-Volume, das
POSIX-Rechte ignoriert (`chmod 600` wirkt dort nicht, alles ist 666).

**Enthaltene Modelle** (Dateinamen/Größen am 18.09.2026 per HfApi verifiziert):

| Modell | Datei | Größe |
|---|---|---|
| LTX-2.5 Video/Audio (int8) | `diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot` | 21,5 GB |
| Gemma4-12B Textencoder (int8) | `text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot` | 15,4 GB |
| Video-/Audio-VAE | `vae/ltx-2.5-{video,audio}-vae-bf16` | 1,5 + 0,4 GB |
| Latent-Upscaler (spatial/temporal) | `latent_upscale_models/…` | 1,0 + 0,3 GB |
| Auto-Duration-Head | `model_patches/ltx-2.5-duration-head-bf16` | 4 MB |
| Qwen-Image 2512 (Apache-2.0) | `qwen_image_2512_fp8_e4m3fn` + Textencoder + VAE | 20,4 + 9,4 + 0,3 GB |
| Qwen-Image-Edit 2511 (Apache-2.0) | `qwen_image_edit_2511_int8_convrot` + LoRAs | 20,5 + 1,3 GB |

**Bewusst NICHT enthalten:** FLUX.1-schnell (Stand 08/2024, überholt durch
Qwen-Image 2512) und FLUX.2 [dev] (Non-Commercial-Lizenz → Risiko bei
monetarisierten Kanälen). NVFP4-Varianten fehlen ebenfalls: das ist ein
Blackwell-Pfad, auf Ampere (A40/A6000) ist int8 die tragfähige Wahl.

## LTX-2.5 lokal generieren (verifiziert 18.09.2026)

```bash
python /workspace/ltx_generate.py "Cinematic prompt in English" --w 768 --h 1344 --frames 121 --steps 8
```
`--frames 121` = 4,84 s bei 25 fps (LTX-2.5 erwartet Frames nach 8n+1, 9:16 via
768x1344; beide Werte durch 32 teilbar). Ergebnis landet in ComfyUI/output/ltx_test/.
Video **und** Audio (AAC 48 kHz) entstehen in einem Pass — kein zweiter Durchlauf.

### Zielordner der LTX-Loader (Quelle: comfy_extras/nodes_lt_audio.py)

| Datei | Ordner | Zusatz |
|---|---|---|
| ltx-2.5-22b-...convrot.safetensors | diffusion_models **+ checkpoints** | UNETLoader **und** LTXAVTextEncoderLoader |
| gemma4-12b-with-proj-...safetensors | text_encoders **+ checkpoints** | enthält audio_projector + multi_modal_projector |
| ltx-2.5-video-vae-bf16.safetensors | vae **+ checkpoints** | |
| ltx-2.5-audio-vae-bf16.safetensors | vae **+ checkpoints** | LTXVAudioVAELoader liest NUR checkpoints |

`link_gen_models()` in setup.sh legt diese Symlinks automatisch an (kostenlos).
Ohne sie bricht jeder LTX-Workflow ab mit `Value not in list: ckpt_name`.

### Bekannte Stolperfallen

| Symptom | Ursache | Fix |
|---|---|---|
| `Value not in list: ckpt_name` (Node 7) | `LTXVAudioVAELoader` liest `models/checkpoints/` | Symlink (s. o.) |
| `Required input is missing: vae_name` (Node 16) | `VAELoader` erwartet `vae_name`, nicht `ckpt_name` | im Workflow korrigieren |
| Textencoder-Output "mush" | Alt-Pfad `DualCLIPLoader(type=ltxv)` + separate projection | `LTXAVTextEncoderLoader` nutzen |
| `ok: false` trotz vollständiger Modelle | `stat -c %s` auf Symlink liefert die Symlink-Länge (~100 B) | `stat -L` verwenden |
| Gen-Größenprüfung cmd in Phase 7 | s. `runpod/gen_report.sh` als Einzelprüfung | `bash /workspace/gen_report.sh` |

### Messwerte A40 48 GB (gemessen 18.09.2026)

* VRAM-Bedarf 5-s-Clip 768x1344 8 Steps: **43,5 GB von 46 GB** → knapp; fuer
  laengere Clips `LTXVContextWindows` oder kleinere Basis-Aufloesung + Latent-Upscaler x2
* Modell-Laden (20 GB LTX + 15 GB Gemma vom Netzwerk-Volume) dominiert den ersten Lauf

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

⛔ **Zusätzlich:** `raw.githubusercontent.com` liefert `cache-control: max-age=300`
(`x-cache: HIT`, `via: 1.1 varnish`) — also **bis zu 5 Minuten den alten Stand**,
und ein Query-String als Cache-Buster wird ignoriert (gemessen vom Pod aus).
Ein Boot direkt nach einem Push lief dadurch schon mit veraltetem `setup.sh`.
Deshalb holen `entrypoint.sh` und `setup.sh` ihre Skripte jetzt über
**codeload.github.com** (Repo-Tarball, ~30 KB, immer aktuell, 1 Request);
Fallback ist die GitHub-API, danach bleiben die vorhandenen Dateien.

**Deshalb: Download auf Temp-Datei, Syntaxprüfung, erst dann ersetzen.**

```bash
bash -c "([ -f /start.sh ] && /start.sh &); exec >> /workspace/boot.log 2>&1; echo '=== Pod Boot ==='; sleep 2; \
EP=/workspace/entrypoint.sh; \
curl -fsSL --retry 5 --retry-connrefused --connect-timeout 15 'https://codeload.github.com/kuberqu/templates/tar.gz/refs/heads/main' -o /tmp/repo.tgz \
  && tar -xzOf /tmp/repo.tgz templates-main/runpod/entrypoint.sh > /tmp/entrypoint.sh.new \
  && bash -n /tmp/entrypoint.sh.new && mv /tmp/entrypoint.sh.new $EP && chmod +x $EP \
  || echo 'WARNUNG: entrypoint.sh Download/Syntaxcheck fehlgeschlagen - nutze vorhandene Version'; \
RUN_IN_BACKGROUND=true bash $EP; sleep infinity"
```

Fallback: existiert `$EP` schon (persistentes `/workspace`), läuft bei
Download-Problemen die vorhandene Version weiter — kein toter Boot mehr.

## Boot eines Pods prüfen (ein Befehl)

```bash
bash /workspace/boot_report.sh            # Struktur, Status, Dauer
bash /workspace/boot_report.sh --smoke    # zusätzlich LivePortrait-Render (~40s)
```
Exit 0 = alles grün. Prüft: Boot-Modus/Dauer (`boot_mode`, `boot_seconds`,
`server_ready_seconds`), fehlgeschlagene setup-Phasen, genau **einen**
ComfyUI-Prozess, HTTP 200, Node-Registrierung, Python-Importe inkl.
`mediapipe.framework.formats`, OpenMontage-Registry + staticFile-Patch.

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

## Smoke-Tests Wav2Lip + SadTalker (API)

```bash
/workspace/venv/bin/python /workspace/test_lipsync_smokes.py    # beide, je ~180s
```
Voraussetzungen im `input/`-Ordner: `lp_source.jpg` (Gesicht) und `tts_test.wav` (Sprache).
SadTalker schreibt `<timestamp>.mp4` direkt nach `output/` (kein history-Eintrag).

## H3 → LipSync (YouTube-Tops → Pod)

`h3_lipsync.py` läuft **lokal** und baut selbst den SSH-Tunnel zum Pod:

```bash
./h3_lipsync.py --h3 ~/workspace/youtube-tops/output/facts_*.mp4 \
    --face presenter.jpg --start 4 --duration 6 --out /tmp/h3_out.mp4
./h3_lipsync.py --h3 clip.mp4 --check-only        # nur Face-Check + Modus-Entscheidung
```

- Modus `direct`: H3-Clip enthält ein Gesicht → Wav2Lip über die H3-Frames.
- Modus `presenter`: H3-Audio treibt ein Presenter-Bild (Normalfall bei den Facts-Clips,
  die keine Gesichter enthalten).
- Ergebnis wird mit der Original-H3-Audiospur gemuxt.
- Env statt CLI: `LIPSYNC_POD`, `LIPSYNC_PORT`, `LIPSYNC_KEY`.

