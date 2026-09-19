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

### Charakter-LoRA von fal.ai einbinden

fal trainiert im **diffusers-Format**, ComfyUI braucht sein eigenes Schema — ohne
Konvertierung lädt die LoRA nicht (oder wird stillschweigend ignoriert):

| | fal/diffusers | ComfyUI |
|---|---|---|
| Präfix | `transformer.transformer_blocks.…` | `transformer_blocks.…` |
| Gewichte | `lora_A.weight` / `lora_B.weight` | `lora_down.weight` / `lora_up.weight` |
| Alpha | nur in Metadaten (`lora_alpha`) | eigener `alpha`-Tensor je Modul |

`runpod/convert_lora.py` erledigt das. **Alpha muss `lora_alpha` aus den Metadaten
sein, nicht geraten** — bei 2000 Steps/LR 5e-4 war es 16 (= rank). Mit alpha=32
statt 16 wirkt die LoRA doppelt so stark und überzeichnet die Figur.

**Stärke nicht auf 1.0 stellen.** Gemessen: bei `strength_model 1.0` zieht die LoRA
den Hintergrund aus dem Trainingsdatensatz mit — statt des dunkelblauen Studios
erschien ein Büroraum mit Glasflächen (eines der 18 Trainingsbilder). Bei **0.8**
bleibt der Prompt bestimmend und die Figur sitzt trotzdem. Empfehlung 0.6–0.8.

Ablauf: fal-Queue überwachen (`fal_status.py`), Ergebnis laden, konvertieren,
nach `models/loras/` verlinken, dann `LoraLoaderModelOnly` nach `ModelSamplingAuraFlow`
und vor den KSampler hängen. Vergleich ohne/mit/abgeschwächt immer mit gleichem Seed.

**Wann LoRA, wann Kanon:** Host-Aufnahmen über den Kanon (Edit + Referenzbild) —
präziser, weil die Identität direkt vom Bild kommt. Die trainierte LoRA für freie
Szenen, in denen die Figur ohne Referenz auftreten soll.

### Short-Produktion (Pipeline)

`shorts/` enthält die Kette für eine Folge, jeder Schritt einzeln wiederholbar:

| Skript | Aufgabe |
|---|---|
| `script.json` | Szenenplan: je Szene Text, Typ (`host`/`broll`), Bild-Prompt, Clip-Prompt, Plandauer |
| `make_narration.py` | edge-tts je Szene + **gemessene** Dauern nach `timing.json` |
| `make_images.py` | Host-Szenen über den Kanon (Edit+Angles), B-Roll via T2I 768×1344; `--only 4,10` für Einzelszenen |
| `make_clips.py` | LTX-I2V je Bild, Länge aus `timing.json` + Luft, auf 8n+1 gerundet — **kopiert jedes Bild vorher nach `ComfyUI/input/`** |
| `compose.py` | Clips concat → 1080×1920, Narration-Zeitleiste, Whisper-Untertitel, Ambient-Bett mit Sidechain-Ducking, −14 LUFS |

Regeln, die sich bewährt haben:

* **Host nur als Rahmen** (Hook + Schluss, je ~3 s), die Information trägt der Film —
  in der Mitte keine Host-Szene.
* **Sprache im Clip-Prompt angeben.** Ohne Angabe generiert LTX Sprache in der
  Prompt-Sprache (englischer Prompt → englisch sprechende Figur, live gehört).
  Für B-Roll: `no speech, ambience only`.
* **Szenen-Nummern nicht nachträglich umsortieren.** Werden Szenen eingefügt oder
  gestrichen, verschieben sich die Bilddateien und die Clips bekommen die falschen
  Bilder — Bilder nach dem Umbau komplett neu erzeugen (kostet ~9 Min, spart den
  Fehlgriff).
* LTX-Ton auf −26 dB absenken und unter die Narration ducken: er ist Atmo, kann aber
  Sprachreste des Prompts enthalten.
* **`LoadImage` liest ausschließlich aus `ComfyUI/input/`** — nicht aus dem Projekt­ordner.
  Wer die Szenenbilder dort liegen lässt, bekommt für **jeden** Clip
  `custom_validation_failed: image - Invalid image file: szene_01.png` und 0 Clips,
  obwohl alle Bilder korrekt erzeugt wurden. `make_clips.py` kopiert sie deshalb
  vor dem Aufruf nach `input/` (gemessen: 10 von 10 Clips fehlgeschlagen).
* **Untertitel gegenprüfen:** Whisper verhört Fachbegriffe. Gemessen bei diesem Thema:
  „Malzähne" statt Mahlzähne, „Malwerk" statt Mahlwerk, „Heutung" statt Häutung.
  Deshalb `untertitel_korrekturen` im Skript-JSON pflegen — `compose.py` wendet sie
  auf jede Zeile an. Ein-Wort-Reste werden automatisch an die vorige Zeile gehängt
  (sonst 0,3-s-Einblendungen, die niemand lesen kann).
* `faster-whisper` gehört ins Setup (Phase 8f/8i) — sonst fällt der Schnitt auf die
  Szenentexte zurück, die pro Einblendung zu lang sind.
* **ffmpeg-Fallen im Mischpfad** (beide live getroffen):
  1. Ein Filterausgang darf nur EINMAL als Eingang dienen. Wer die Narration sowohl
     in den Mix als auch als Sidechain-Steuerung schickt, braucht `asplit=2`, sonst
     bricht ffmpeg ab mit `Stream specifier 'nar' ... matches no streams`.
  2. `-af` (Simple-Filter) und `-filter_complex` dürfen nicht denselben Stream
     bearbeiten: `loudnorm` muss in den Komplex-Filter hinein
     (`...amix...[mixp];[mixp]loudnorm=...[mix]`), nicht als `-af` daneben.
* **Abstrakte Motive nicht fotorealistisch verlangen.** Gemessen: „gastric mill"
  liefert eine gekochte Krabbe auf dem Schneidebrett statt einer Präparation,
  „sound waves propagating" eine Languste ohne Schallausbreitung. Konkrete Motive
  (Hummer, Kabeljau, Panzer-Makro) funktionieren dagegen gut. Für Anatomie/Physik
  entweder sehr konkrete Objektbeschreibungen („three white grinding teeth on a pale
  surface, museum specimen") oder eine Infografik statt Fotorealismus.

### Charakter (wiederkehrende Figur)

Zwei Werkzeuge, beide laufen über den offiziellen Qwen-Image-Pfad:

| Skript | Zweck | Parameter |
|---|---|---|
| `runpod/qwen_portraits.py` | Typ-Auswahl: 6 Portraits eines Typs (T2I) | 1024×1024, ModelSamplingAuraFlow shift=3.1, 20 Steps/cfg 4 (der Lightning-Pfad des Templates braucht ein separates LoRA) |
| `runpod/qwen_kanon.py` | Kanon aus **einem** Basisbild: 6 Kamera-Ansichten (Edit 2511) | 4 Steps/cfg 1.0 mit Lightning + Multiple-Angles-LoRA, ~24 s pro Bild auf der A40 |

Multiple-Angles-LoRA (`dx8152/Qwen-Edit-2509-Multiple-angles`): **keine Trigger-Wörter**,
sondern Kamera-Kommandos — zuverlässig in chinesischer Form:
`将镜头向左旋转45度` (45° links) · `将镜头向右旋转45度` (45° rechts) · `将镜头向左移动` ·
`将镜头转为特写镜头` (Close-up) · `将镜头转为广角镜头` (Weitwinkel) · `将镜头转为俯视` (Top-down).
Laut Autor **muss** die LoRA zusammen mit Qwen-Image-Lightning laufen.

### Trainings-Datensatz für ein Charakter-LoRA

`runpod/build_dataset.py` erzeugt 18 Variationen (Winkel, Outfits, Umgebungen, Distanzen)
**plus Captions** im Format `<name>.png` + `<name>.txt`, danach ZIP.

* Captions beschreibend schreiben — **keine** Token wie `TOK`/`sks`: Qwen lernt durch
  Überschreiben beschreibender Konzepte, abstrakte Platzhalter funktionieren nicht.
* Datensatzgröße: 15–30 Bilder für Charaktere (laut fal.ai), Aspect-Ratio-Bucketing
  übernimmt der Trainer.
* Externe Trainer (Stand 18.09.2026): `fal-ai/qwen-image-2512-trainer` (T2I, 2000 Steps
  ≈ 8 USD — Figur danach direkt per Text in neuen Szenen), `fal-ai/qwen-image-edit-2511-trainer`
  (Edit, $4/1000 Steps), `fal-ai/ltx2-video-trainer` (Video-LoRA, $0,0048/Step);
  alternativ Replicate `qwen-image-lora-trainer` (H100, 15–30 Min).
* **LoRA-Downloads immer prüfen:** Dateien < 1 MB sind Trümmer (abgeschnitten bzw. falscher
  Repo-Pfad). Beispiel: die Angles-LoRA liegt als `镜头转换.safetensors` im Repo —
  mit falschem Dateinamen liefert HF 82 Bytes Müll, und ComfyUI scheitert still.

### Video aus der Figur: I2V und Sprechen

| Skript | Zweck | Besonderheiten |
|---|---|---|
| `runpod/ltx_i2v.py` | Kanon-Bild → Video (offizieller I2V-Graph) | `LTXVPreprocess(img_compression 18)` → `LTXVImgToVideoInplace(strength 0.7)`, sonst wie T2V |
| `runpod/ltx_talk.py` | Figur **spricht** (Lippen an Referenzaudio) | `LTXVReferenceAudio` sitzt zwischen Modell und Guider und liefert MODEL + positive + negative; `identity_guidance_scale 3.0` |

* Videolänge an die Audiolänge koppeln: `Frames = Sekunden × 24 + 1`, auf 8n+1 gerundet
  (9,7 s → 233 Frames). Sonst laufen Lippen und Sprache auseinander.
* Für I2V das Startbild auf das Zielformat bringen (`scale=…:force_original_aspect_ratio=increase,crop=…`),
  sonst verzerrt der Latent.

**Sprech-Test, gemessen (18.09.2026, 9,7 s Clip, A40, 560 s Laufzeit):**

* `LTXVReferenceAudio` koppelt die Lippen an das Referenzaudio — der Mund artikuliert
  sichtbar über den ganzen Clip. **Aber:** LTX gibt das Referenzaudio **nicht** als Tonspur
  aus. Verifiziert per Hüllkurven-Korrelation (0,09) und Spektrum:
  Referenz-Sprache hat 55 % Energie unter 1 kHz, die Videospur nur 26 % und 37 % über 3 kHz
  (= Atmo/Rauschen). → **Narration kommt immer als separate Spur in den Schnitt**, Video
  liefert nur Atmo.
* Mimik-Prompt ist entscheidend: „speaks, lips and jaw moving naturally" ohne
  Ausdrucksvorgabe erzeugte ein erschrockenes Gesicht (Brauen hoch, Augen weit, ovaler Mund).
  Für einen ruhigen Host explizit vorgeben: *steady serious expression, relaxed eyebrows,
  level gaze, moderate mouth movement, occasional slow blink, composed*.
* Clipping beachten: die Videospur lag bei max 0,0 dB (Referenz −4,6 dB) → beim Mischen
  im Schnitt Pegel absenken.

### Der offizielle Graph ist die Referenz (nicht selbst bauen)

`comfyui_workflow_templates_json/templates/video_ltx2_5_t2v.json` liegt im Pod und
enthält als **Subgraph** (42 Nodes) den echten Workflow. Wer ihn nachbaut, MUSS
diese sieben Punkte treffen — sonst ist die Tonspur stumm (live gemessen, vom
Nutzer bestätigt: Bild und Ton synchron):

| Parameter | offiziell (richtig) | falsch (Folge) |
|---|---|---|
| LTXVDualCFGGuider | **1.0 / 1.0** | 3.0 / 7.0 → Audio kollabiert (−91 dB statt −31,8 dB) |
| Sigmas | ManualSigmas, 2 Stufen | LTXVScheduler, einstufig |
| Sampler | **euler_ancestral** | euler |
| Textencoder | CLIPLoader type=ltxv (text_encoders/) | LTXAVTextEncoderLoader (liest checkpoints/) |
| Audio-VAE | VAELoader (vae/) | LTXVAudioVAELoader (liest checkpoints/) |
| Decode | VAEDecodeTiled | VAEDecode |
| fps | 24, Frames = s×24+1 | 25 |

Ablauf: Basis-Sampling bei **halber** Zielauflösung → `LTXVSeparateAVLatent` →
Video durch `LTXVLatentUpsampler` ×2 → wieder mit dem Audio-Latent
`LTXVConcatAVLatent` → Refine-Sampling (Sigmas 0.85 → 0.0) → Decode.

Fertige Umsetzung als API-Prompt: `runpod/ltx_official.py`
(`python ltx_official.py "Prompt" --seconds 5 --width 720 --height 1280`).
Die Sigma-Folgen stehen dort als `SIGMAS_STAGE1` / `SIGMAS_STAGE2`.

### Messwerte A40 48 GB (gemessen 18.09.2026)

* VRAM-Bedarf 5-s-Clip 768x1344 8 Steps: **43,5 GB von 46 GB** → knapp; fuer
  laengere Clips `LTXVContextWindows` oder kleinere Basis-Aufloesung + Latent-Upscaler x2
* Modell-Laden (20 GB LTX + 15 GB Gemma vom Netzwerk-Volume) dominiert den ersten Lauf
* Offizieller 2-Stufen-Graph, 5 s @720×1280: **200 s** (3,3 Min) — schneller als der
  einstufige 768×1344-Lauf (311 s), weil die Basis nur 360×640 rechnet
* Ausgabe 704×1280 statt 720×1280 (Latent-Rundung auf 32er-Vielfache) — unkritisch
* Tonspur mean −31,8 dB / Peak −14,0 dB; Bild und Ton synchron (Nutzerabnahme)
  → ~40 Min Pod-Zeit pro 60-s-Short aus 12 Clips

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


## Lip-Sync (Wav2Lip) - drei Fallen, alle real aufgetreten

**1. `mode` MUSS zur Quelle passen.** `sequential` verarbeitet jeden Frame genau
einmal (Videosequenz), `repetitive` wiederholt das Bild, bis die Audiospur gefuellt
ist (Standbild). Ein Standbild mit `sequential` ergibt EINEN Frame -> Video ohne
jede Mundbewegung (Lauf "erfolgreich", Lippen steif). Der schlanke Smoke-Test deckt
das NICHT auf: er prueft nur, dass ein Video entsteht. Immer die Mundbewegung messen
(Frame-zu-Frame-Differenz im Mundbereich; Sprechen liegt deutlich ueber 10).

**2. Vorlage: neutrales Portrait, Mund geschlossen.** Ein Bild mit bereits offenem
Mund (z.B. aus einem LTX-Sprech-Prompt) laesst Wav2Lip kaum Spielraum. Grosses,
frontales Gesicht (65-70 % der Bildhoehe) ist optimal - dann rendert Wav2Lip auch
schnell: 92 s statt 382 s fuer dieselben 3 s Audio (s3fd-Face-Detection findet das
Gesicht sofort). Wav2Lip ist CPU-lastig, GPU-Auslastung nahe 0 ist normal.

**3. NIEMALS "/" im `filename_prefix`.** Drei Folgen, alle real erlebt:
(a) Die Datei landet NICHT in einem Unterordner, sondern flach in `ComfyUI/output/`.
(b) Der Zaehler springt nicht weiter: bei mehreren Bildern im selben Lauf
    ueberschreibt jede Generierung `..._00001_.png` - fuenf von sechs Bildern waren
    so verloren. Ohne Slash zaehlt ComfyUI korrekt hoch (00001, 00002, ...).
(c) Abhol-Skripte suchen dann am falschen Ort und liefern stillschweigend nichts.
Also: Prefix ohne Slash (`weiblich2_`) und die Dateien anschliessend umbenennen.

## LTX-Referenzaudio ist KEINE Sprachquelle

`LTXVReferenceAudio` uebernimmt aus der Referenz-WAV nur den Stimmcharakter, den
TEXT erfindet das Modell neu. Gemessen: Skript sagte "Dieser Hummer knurrt. Aber
nicht mit dem Maul", der Clip sagte "Aber jetzt brauche ich allen Gord". Fuer
Szenen mit vorgegebenem Text daher: **InfiniteTalk** (siehe unten) ueber
`runpod/run_wan_talk.py it`, B-Roll ohne Mund: LTX, Sync ist dort irrelevant.

## Host-Talking-Head: InfiniteTalk statt Wav2Lip (18.09.2026)

Wav2Lip erzeugt nur eine **96x96-Mundregion** und interpoliert sie ins Zielbild - bei
832x1216 ist das Faktor 8,7 Vergroesserung, das Gesicht wirkt wachsartig. Das ist die
Architektur, kein Einstellungsfehler. Ersatz: **InfiniteTalk** (Wan 2.1 I2V 480p +
Audio-Patch), in ComfyUI >=0.36 nativ als `WanInfiniteTalkToVideo` vorhanden.

Modell-Dateien + Repos stehen in `setup.sh` (Gen-Phase). Audio-Encoder ist der
**chinesische** wav2vec2-Base (`Kijai/wav2vec2_safetensors`) - das ist die Wahl des
offiziellen Templates, NICHT der englische `wav2vec2_large_english` aus dem
Comfy-Org-Repo. Deutsche Phoneme liefen damit sauber synchron (vom Nutzer abgenommen).

Werte = offizielles Template `video_wan2_1_infinitetalk.json`:
`ModelSamplingSD3 shift 8` -> LoRA `lightx2v_I2V_14B_480p_...rank64` @1.0 ->
`WanInfiniteTalkToVideo(mode=single_speaker, motion_frame_count=9, audio_scale=1.0)` ->
negativ = **`ConditioningZeroOut` des positiven Conditionings** -> KSampler
**6 Steps, cfg 1.0, euler, scheduler "normal"** -> `CreateVideo(fps=25)`.
Laenge = **4n+1** Frames bei **25 fps**. Gemessen: 3,08 s @480x832 in **250 s** kalt.

Fallstricke (real getroffen):
- `CLIPVisionLoader` erwartet den Eingang **`clip_name`** (`clip_vision_name` ->
  `required_input_missing`).
- ComfyUI 0.36 nutzt das **V3-Node-Schema**: `inspect.getsource(cls.INPUT_TYPES)` zeigt nur
  den Wrapper. Eingaben immer per **`GET /object_info/<Node>`** erfragen.
- `bc` ist auf dem Pod **nicht installiert** -> Arithmetik in Shell-Skripten mit `awk`.

## Volume-Quota: `df` luegt, `du` zaehlt

`df -h /workspace` zeigt den Shared-Storage-Pool (756 TB), **nicht** die Quote. Die liegt bei
**200 GB** und war bei 97 %, waehrend `df` 75 % Pool-Auslastung meldete. Wahrheit: `du -sh
/workspace`. Entlastung: LTX-2.5-Stack + obsolete LipSync-Modelle (Wav2Lip/SadTalker/
LivePortrait, zusammen 39 GB). Das Staging liegt in `/workspace/gen_models` und wird per
Symlink in `ComfyUI/models/` gehaengt - beim Loeschen tote Symlinks mit
`find /workspace/ComfyUI/models -xtype l -delete` entfernen, sonst listet ComfyUI Dateien,
die beim Laden fehlschlagen.

**Download-Resume kann Dateien korrumpieren:** `curl -C -` erzeugte eine **23,1 GB** grosse
Datei, wo 16,4 GB erwartet waren. Nach jedem Download die Byte-Groesse gegen den
Sollwert pruefen; eine zu grosse Datei faellt sonst erst beim Modell-Load auf.

## TTS / Charakterstimme auf dem Pod (19.09.2026)

Zwei Modelle, **zwei getrennte venvs** — beide Konflikte sind real aufgetreten:

| venv | Paket | Modell | Rolle |
|---|---|---|---|
| `/workspace/qwenvenv` | `qwen-tts` | `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign` + `Tokenizer-12Hz` | **Identität**: Stimme aus Textbeschreibung, ohne Referenzaudio |
| `/workspace/ttsvenv` | `chatterbox-tts` | `ResembleAI/chatterbox` | **Vortrag**: Klangfarbe per Referenz, Emotion per `exaggeration` |

**Konflikt 1 — transformers unvereinbar:** `chatterbox-tts 0.1.7` verlangt
`transformers==5.2.0`, `qwen-tts` verlangt `4.57.3`. In einem venv meldet uv
`requirements are unsatisfiable`. Deshalb getrennte venvs (je eigenes torch ≈ 2,5 GB).

**Konflikt 2 — chatterbox zerschießt das torch-Triple:** nach der Installation stuft
chatterbox `torch` auf **2.6.0+cu124** herunter, `torchvision` bleibt auf `0.24.0+cu128`.
Folge: `RuntimeError: operator torchvision::nms does not exist`, und der transformers-Lazy-Import
stirbt mit `Could not import module 'LlamaModel'. Are this object's requirements defined correctly?`.
**Reparatur (muss NACH chatterbox laufen):**

```bash
uv pip install --python /workspace/ttsvenv/bin/python --index-url https://download.pytorch.org/whl/cu128 \
    "torch==2.9.0+cu128" "torchvision==0.24.0+cu128" "torchaudio==2.9.0+cu128"
```

Prüfung danach: `torch 2.9.0+cu128 | torchvision 0.24.0+cu128` **und** `from transformers import
LlamaModel` muss gehen — sonst ist der Import-Fehler nur verdeckt.

**Setup:** `install_tts_background()` in `setup.sh` (Schalter `INSTALL_TTS=0` schaltet die Phase ab,
Status in `/workspace/tts_models_status.json`). Manuell/nachziehbar: `tts_install2.sh`
(`MODELS=1` lädt zusätzlich ~18 GB Modelle). Platzbedarf: venvs ~6 GB + Modelle ~18 GB.

**Nutzung (Beispiel-API):**

```python
# Identität (qwenvenv)
from qwen_tts import Qwen3TTSModel
m = Qwen3TTSModel.from_pretrained("/workspace/tts_models/qwen3tts-voicedesign",
                                  device_map="cuda:0", dtype=torch.bfloat16,
                                  attn_implementation="sdpa")   # flash_attention_2 nur wenn installiert
wavs, sr = m.generate_voice_design(text="…", language="German", instruct="A young German woman …")

# Zeilen (ttsvenv) — Referenz ist die Identitätsdatei
from chatterbox.mtl_tts import ChatterboxMultilingualTTS
c = ChatterboxMultilingualTTS.from_pretrained(device="cuda", t3_model="v3")
wav = c.generate(text, language_id="de", audio_prompt_path="id_ref.wav",
                 exaggeration=0.6, cfg_weight=0.5)
```

**Wichtig:** Die **Identität ist die WAV-Datei**, nicht der Seed. Einmal erzeugt und abgelegt, ist die
Stimme damit exakt reproduzierbar — die Beschreibung samt Seed wird nur zur Dokumentation notiert.
Chatterbox **V3** ist die aktuelle Multilingual-Version und ausdrücklich gegen die
Wiederholungsschleifen optimiert, die mit V2 aufgetreten waren (21 s Ausgabe für einen 4,5-s-Satz).
