# Produktionsstandard Short-Serie (Stand 18.09.2026)

Verbindlich für alle Folgen der Short-Serie (TikTok + YouTube Shorts, 9:16, deutsch).
Jede Zeile hier ist auf dem Pod **real gemessen**, nicht aus der Doku übernommen.
Maschinenlesbare Fassung: `production_standard.json` (dieselben Werte für Skripte).

## 1. Host-Szenen (sprechender Host)

| Punkt | Wert |
|---|---|
| Verfahren | **InfiniteTalk** (Wan 2.1 I2V 480p + Audio-Patch) — ersetzt Wav2Lip |
| Skript | `run_wan_talk.py it --audio <wav> --bild <portrait> --sekunden <s>` |
| Auflösung / fps | **480×832, 25 fps** (nativ; 16 fps wäre S2V) |
| Frames | **4n+1** (`4*round(sek*25/4)+1`) |
| Sampler | `ModelSamplingSD3 shift 8` → KSampler **6 Steps, cfg 1.0, euler, scheduler "normal"** |
| Negativ | `ConditioningZeroOut` des **positiven** Conditionings |
| LoRA | `lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16` @ 1.0 |
| Node-Werte | `mode=single_speaker`, `motion_frame_count=9`, `audio_scale=1.0` |
| Audio-Encoder | `wav2vec2-chinese-base_fp16` (**nicht** die englische Variante) |
| Referenzbild | neutrales Portrait, Mund geschlossen, Gesicht 65–70 % der Bildhöhe |
| Renderzeit | **~83 s je Sekunde Video** kalt (3,08 s → 250 s) |

Warum nicht Wav2Lip: es erzeugt nur eine **96×96-Mundregion**, die in 832×1216
interpoliert wird (Faktor 8,7) — das Gesicht wirkt wachsartig. Kein Einstellungsfehler.

## 2. Upscale auf Kanalgröße

| Punkt | Wert |
|---|---|
| Skript | `run_upscale_it.py --video <clip> --frames 77 --prefix upit --chunk 16` |
| Modell | **4x-UltraSharp** (ESRGAN) in `ComfyUI/models/upscale_models/`, ~67 MB |
| Ziel | **1080×1872** (dann Skalierung im Schnitt auf 1080×1920 → 2 % Abweichung) |
| Chunking | 16 Frames — ESRGAN rechnet 4× hoch (1920×3328 je Frame), große Batches sprengen VRAM |
| Zeit | 84 s erster Chunk (inkl. Modell-Load), dann ~36 s je 16 Frames → **~3,7 min für 3 s Video** |
| Last | 94 % GPU bei nur 4,5 GB VRAM (kachelt) |

Ohne Upscale wirkt ein 480p-Clip in 1080×1920 weich. Der **alte Wav2Lip-Clip war zudem
832×1216 (0,684)** und wurde beim Schnitt um **21 % gestaucht** — ein zweiter Grund für das
schlechte Gesicht. 480×832 (0,577) weicht nur 2 % ab.

## 3. Charakter-LoRA (weiblicher Kanal)

| Punkt | Wert |
|---|---|
| Trainer | fal.ai `fal-ai/qwen-image-2512-trainer`, **1000 steps, lr 0.0005** |
| Datensatz | **24 Bilder + Captions** (image.EXT + image.txt im ZIP) |
| Dataset-Regeln | Outfit-Vielfalt, **nur die Person**, schlichte Studio-Hintergründe, Captions **ohne** Trigger-Tokens |
| Konvertierung | `convert_lora.py` (diffusers `lora_A/B` → ComfyUI `lora_down/up` + `alpha`) |
| **Stärke** | **0,7 als Standard** (freigegeben 0,6–0,8; 0,6 = maximal natürlich, 0,8 = deutlich idealisiert) |
| Laufzeit / Kosten | ~22 Min im Queue, ~3 USD |

Die Figur ist eingefroren: Gesicht `nordic_ash`, Brust B, Gesäß B. Ein Charakter-LoRA lernt die
**Person**, nicht die Kleidung — Outfits kommen aus dem Prompt.

## 4. Schnitt (`compose.py`)

| Punkt | Wert |
|---|---|
| Aufruf | `/workspace/OpenMontage/.venv/bin/python compose.py <projekt>` |
| Ausgabe | **1080×1920, 24 fps**, `libx264 crf 19`, AAC 192 kbit/s, 48 kHz (mono) |
| Loudness | `loudnorm I=-14:TP=-1.5:LRA=11` |
| Ton | **LTX-/B-Roll-Ton komplett stumm** (halluzinierte Sprache!), Narration + Ambient-Bett (0,22), Ducking per `sidechaincompress` |
| Untertitel | Whisper + `untertitel_korrekturen` aus dem Skript, eingebrannt (`subtitles`-Filter) |
| Clips | `clips/clip_NN.mp4` — **Glob `clip_*.mp4`!** Keine Backups/Streudateien im Ordner (sonst landen sie als Szene im Video) |

## 5. Upload

### YouTube

| Punkt | Wert |
|---|---|
| Kanal | **The Prickle** `UCjKqU1J5wio-sd7AigvQm2g` |
| Modul | `youtube-tops/pipeline/youtube_upload.py` → `upload_video(path, title, description, hashtags, privacy)` |
| Token | `~/.hermes/auth/youtube_oauth.json` (Google-App muss auf **Production** stehen, sonst 7-Tage-Ablauf) |
| Kategorie | 22 (People & Blogs, im Modul fest) |
| Hashtags | `#Shorts` + 4 Themen-Tags |
| **Nach dem Upload prüfen** | `videos.list` → `uploadStatus=processed`, `duration`, `definition=hd`, `privacyStatus` |

### TikTok (Kette MinIO → Buffer)

| Punkt | Wert |
|---|---|
| Kanal | `@_the_prickle`, Buffer-Channel-ID `69fdf6675c4c051afa243b4b` (aus der **API-Antwort** lesen, nicht aus Notizen) |
| Organisation | `69fdf62899d12587b2ba02fe` |
| Skript | `tiktok_publish.py` (`--check` liest nur, `--publish` postet) |
| Referenz | `podcast-clipper/pipeline/tiktok_upload.py` → `upload_video()` — **übernehmen, nicht nachbauen** |
| Media-Weg | Video in den **öffentlichen** MinIO-Bucket `buffer` (`https://s3.o.qtx.de`) → URL in `assets[].video.url` |
| Credentials | `~/.hermes/auth/s3_credentials.json`, `~/.hermes/auth/buffer_token.json` |
| Modus | **`shareNow`** (sofort veröffentlichen, nicht einplanen) |
| **Nach dem Posten prüfen** | (a) Media-URL per HTTP: `200`, `content-type: video/mp4`, `content-length` = Dateigröße; (b) Post per ID abfragen bis `status=sent` |

**Falle:** Die Queue-Abfrage (`posts.totalCount`) liefert mit diesem Token **FORBIDDEN** — die
Referenz-Implementierung fängt das ab und meldet fälschlich „0/10". Der Stand des Free-Plan-Limits
(10 *geplante* Posts) ist damit **nicht prüfbar**. Mit `shareNow` ist das unkritisch, weil sofortige
Posts das Plan-Kontingent nicht belegen. Einzelabfrage `post(input:{id})` funktioniert dagegen.

## 6. Qualitätsregeln aus echten Ausfällen

1. **Nur ein `compose.py` gleichzeitig** — zwei Läufe schreiben `video_raw.mp4` und zerlegen es.
2. **Prüfen statt hoffen:** Frame-Zahl (`-count_frames`), MD5 gegen die Quelle, exakte Clip-Zahl,
   `uploadStatus=processed`. Ein „sent" ohne diese Checks ist kein Nachweis.
3. **Test- und Smoke-Skripte stellen ihre Assets selbst bereit** (ComfyUI `input/` ist auf einem
   frischen Pod leer; `VHS_LoadVideo` liest **nur** aus `input/`).
4. **`pgrep -f <muster>` matcht den eigenen Aufruf** → Bracket-Trick `pgrep -f "name_[p]y"`.
5. **Nach jedem Download die Byte-Größe prüfen** — `curl -C -` erzeugte eine 23,1-GB-Datei bei
   16,4 GB Sollwert (fiel erst beim Modell-Load auf).
6. **Volume-Quota 200 GB:** `df` zeigt den 756-TB-Pool, die Wahrheit liefert `du -sh /workspace`.

## 7. Erste Produktion nach diesem Standard

„Hummer knurren – aber nicht mit dem Maul", veröffentlicht 18.09.2026:

| Kanal | Nachweis |
|---|---|
| YouTube (The Prickle) | `iXVZ8BruYR8` — public, PT45S, `definition=hd`, `uploadStatus=processed`, 14:31 UTC |
| TikTok (`@_the_prickle`) | Buffer-Post `6aad4c0bbce81a431d4b42b6`, `status=sent`, 14:34 UTC; Media-URL `200 / video/mp4 / 36.261.044 B` |

Rohschnitt mit Wav2Lip-Host: verworfen (siehe `short_final_infinitetalk_KAPUTT_46s_11clips.mp4`).
