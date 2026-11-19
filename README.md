# OpenMacDictate 🎙️ (Dictado Domotex)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-black?logo=apple)](https://www.apple.com/macos)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Privacy](https://img.shields.io/badge/Privacy-100%25%20On--Device-brightgreen)](https://github.com/jsmm888-DOMOTEX/open-mac-dictate)

**Fast, infinite, on-device native voice dictation for macOS.**  
*Dictado por voz infinito, nativo y 100% local para Mac.*

---

## 🌎 English Overview

### Why Do Existing Dictation Tools & Online Services Fail?

1. **Cloud / Online Dictation Lags and Fails:**  
   Most modern AI dictation tools stream audio packets to remote servers over WebSockets. If your connection fluctuates, phrases are dropped, latency rises to 3–5 seconds, and confidential conversations or source code are transmitted to third-party clouds.
2. **Subscription Fatigue:**  
   Many commercial macOS apps (Superwhisper, MacWhisper Pro) lock basic keyboard dictation behind monthly subscriptions ($10–$20/month).
3. **The Undocumented Apple Speech 60-Second Buffer Collapse:**  
   macOS includes `SFSpeechRecognizer` for on-device recognition, but it has a notorious hidden bug: **at ~63 seconds of continuous speaking, Apple's engine silently flushes its internal buffer without throwing an error.** In naive implementations, the accumulated text is abruptly wiped and replaced by only the next spoken word.

### How OpenMacDictate Solves This

- **Direct Hardware PCM Capture (`AVAudioRecorder`):** Captures 16 kHz mono PCM directly via CoreAudio HAL without `AVAudioEngine` graph deadlocks or the 60-second Apple Speech cutoff.
- **Resident Apple Silicon Daemon (`whisper_daemon.py`):** Keeps **Silero VAD** and **Whisper Large-v3-Turbo (`mlx-whisper`)** pre-warmed in Metal GPU memory over a private per-user Unix socket (`~/Library/Application Support/OpenMacDictate/dictado_whisper.sock`, `0600`).
- **Triple On-Device Fallback:** Daemon Socket → `mlx_whisper` CLI → Apple `SFSpeechURLRecognitionRequest` with `requiresOnDeviceRecognition = true` (zero cloud audio).
- **Privacy First:** Clipboard-only by default; optional disk backup (`~/Library/Logs/UltimoDictado.txt` & `.wav`) is disabled unless enabled from the menu bar.
- **Custom Local Vocabulary:** User-specific prompts and phonetic corrections live in `~/Library/Application Support/OpenMacDictate/vocabulario_local.json` (excluded from Git via `.gitignore`).
- **Note on First Launch:** On the very first run, `install.sh` creates an isolated `.venv` from `requirements.txt`, and the daemon downloads **Silero VAD** (`torch.hub`) and **Whisper Large-v3-Turbo** (`mlx-community/whisper-large-v3-turbo`) from HuggingFace/PyTorch Hub once; afterwards it runs **100% offline**.

---

## 🇪🇸 Descripción en Español

### ¿Por qué fallan las demás opciones de dictado?

1. **El dictado online en la nube se corta y tiene lag:**  
   Las herramientas que envían el audio a internet se demoran entre 3 y 5 segundos por frase, se desconectan si la señal fluctúa y envían información privada de tus proyectos a servidores externos.
2. **Cobros mensuales excesivos:**  
   Las aplicaciones comerciales para Mac cobran suscripciones mensuales recurrentes por funciones básicas de teclado.
3. **El colapso secreto de Apple a los 60 segundos:**  
   El reconocedor local de Apple (`SFSpeechRecognizer`) tiene una ventana deslizante oculta de 60–63 segundos. Al llegar a ese tiempo, el motor vacía silenciosamente su memoria sin avisar. Cualquier programa convencional borra de golpe todo tu párrafo acumulado y empieza desde cero con la siguiente palabra suelta.

### La Solución de OpenMacDictate (v5.6)

- **Grabación Directa `AVAudioRecorder` (sin corte a los 60 s):** Captura PCM mono a 16 kHz directamente sin bloqueos de `AVAudioEngine` ni pérdida de frases en dictados largos.
- **Daemon Residente en GPU Metal (`whisper_daemon.py`):** Mantiene pre-calentados **Silero VAD** y **Whisper Large-v3-Turbo (`mlx-whisper`)** escuchando en un socket Unix privado por usuario (`~/Library/Application Support/OpenMacDictate/dictado_whisper.sock`, `0600`).
- **Triple Respaldo 100% Local:** Socket Daemon → `mlx_whisper` CLI → Apple Speech con `requiresOnDeviceRecognition = true`.
- **Privacidad por Defecto:** El guardado continuo en disco (`~/Library/Logs/UltimoDictado.txt` y `.wav`) es opcional desde el menú; los archivos temporales usan el directorio privado del usuario.
- **Vocabulario Personalizado Fuera del Repo:** Copia `vocabulario_local.example.json` a `~/Library/Application Support/OpenMacDictate/vocabulario_local.json` (ignorado en `.gitignore`) para tus propios nombres y términos.
- **Primer Arranque:** `install.sh` crea automáticamente el `.venv` con `requirements.txt`, y en el primer arranque el daemon descarga una única vez Silero VAD y el modelo Whisper MLX desde internet antes de operar 100% offline.

### Desinstalación limpia / Uninstall
```bash
chmod +x uninstall.sh
./uninstall.sh
```

---

## ⚡ Quick Start / Instalación Rápida

### 1. Clone & Build (Un solo comando)
```bash
git clone https://github.com/jsmm888-DOMOTEX/open-mac-dictate.git
cd open-mac-dictate
chmod +x install.sh
./install.sh
```

### 2. Permissions / Permisos
Upon first launch, macOS will request:
1. **Microphone Access:** To capture your voice.
2. **Speech Recognition:** To use Apple's on-device neural language model.
3. **Accessibility (Optional but recommended):** Go to `System Settings → Privacy & Security → Accessibility` and enable **OpenMacDictate** so it can auto-paste directly into your active cursor via synthetic `⌘V`. (If disabled, text is safely copied to your clipboard so you can just press `⌘V`).

---

## ⌨️ Shortcuts / Atajos de Teclado

| Action / Acción | Shortcut / Atajo | Description / Descripción |
|---|---|---|
| **Toggle Dictation** | `Control + Option + Space` (`⌃⌥Espacio`) | Starts/stops recording and auto-pastes into the active window. |
| **Alternative Hotkey** | `F8` | Single-key toggle for quick speaking. |
| **Menu Bar Mic Icon** | `Left Click on 🎙` | Start or stop dictation with a single click from the macOS status bar. |
| **Re-paste Last Text** | `Option + Command + N` (`⌥⌘N`) | Pastes the last successfully transcribed speech if needed. |

---

## 🏗️ Architecture / Arquitectura (v5.5 Titanium Turbo & Anti-Ruido DSP)

```
Microphone Hardware Input (CoreAudio HAL via AVAudioRecorder)
       │
       ├──► High-Fidelity 16kHz Mono PCM Audio Stream (Zero Graph Overhead)
       │         │
       │         ├──► Live VU Meter & Floating HUD (Real-time animated waveform [ ▂▃▅▆▇ ])
       │         │
       │         └──► Physical WAV Backup (Saved continuously to disk)
       │
User Press Hotkey Stop (⌃⌥Space / F8 / Menu Bar Click)
       │
       ▼
DSP Acoustic Filtering (SciPy Butterworth 80 Hz – 7500 Hz Bandpass)
       │  (Eliminates music 808 sub-bass, kick drums, AC hum, and table thuds)
       ▼
Voice Activity Detection Gate (Silero VAD in Memory)
       ├──► Zero Voice Detected (Pure Music / Ambient Noise / Silence) ──► Rejection in < 0.1s (0 Hallucinations)
       │
       ▼ Voice Confirmed
Dynamic Peak Normalization (-0.5 dBFS)
       │
       ▼
Whisper MLX Large-v3-Turbo Daemon (Pre-warmed on Apple Silicon GPU Metal)
       │
       ├──► Transcribes with optional local vocabulario_local.json biasing in < 0.8s
       │
       ├──► Anti-hallucination Decode Guardrails (greedy temp=0.0, compression_ratio=2.2, no_speech=0.6)
       │
       ├──► Post-processing Sanitizer (removes residual subtitle tags, YouTube artifacts, repeating loops)
       │
       ▼
Auto-Paste Engine (CGEvent ⌘V into Target Application) + Persistent Backup
```

### Key Advancements in v5.5 (Anti-Ruido & Turbo):
1. **Whisper Large-v3-Turbo (`mlx-community/whisper-large-v3-turbo`)**: Replaces the small model with OpenAI's latest Large v3 Turbo, bringing 32 encoder layers of acoustic representation. Rejection of background instruments and phonetic accuracy are dramatically superior, running in **~0.6–0.8s** on Apple Silicon Metal GPU.
2. **Silero VAD Acoustic Gate**: Rejects pure instrumental music, songs, or background silence in under 100ms. If you are not speaking, it emits empty text rather than hallucinating song lyrics or YouTube subtitles.
3. **Butterworth Acoustic Bandpass (80 Hz – 7500 Hz)**: Digital filter eliminating low-frequency sub-bass contamination from background speakers, music kicks, and room rumble.
4. **Pure PCM Hardware Capture (`AVAudioRecorder`)**: Bypasses unstable `AVAudioEngine` audio graph deadlocks. 100% resilient to Bluetooth sample rate switching (e.g. Sony WH-1000XM5, AirPods) between 16kHz SCO and 44.1kHz A2DP.
5. **Domain Prompt Biasing & Sanitizer**: Ensures 100% precision with technical terminology ("kVA", "kW", "RETIE", "NTC 2050", "transformador", "luminarias", "citofonía") and strips repetitive loops or non-speech tokens.

---

## 📄 License / Licencia

Distributed under the **MIT License**. See `LICENSE` for more information.  
Desarrollado por **Sebastián Muñoz — DOMOTEX** ([@jsmm888-DOMOTEX](https://github.com/jsmm888-DOMOTEX)).
