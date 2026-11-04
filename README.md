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

- **Monotonic Accumulator (`SpeechAccumulator`):** An append-only state machine that detects when Apple's sliding window drops. It seals previous phrases into an immutable list and stitches new segments seamlessly. **Your text will never be cleared mid-sentence.**
- **Proactive Task Recycling (45s Cycle):** Automatically recycles recognition sub-tasks every 45 seconds while keeping the `AVAudioEngine` running continuously. Apple never hits its 60s hard limit.
- **Zero-Latency Real-Time Persistence:** Every word recognized is immediately synced to the system clipboard (`NSPasteboard`) and saved to disk (`~/Library/Logs/UltimoDictado.txt`). Even if an app crashes, your words are safe.
- **Target App Memory:** Remembers which window had focus when you started talking. If you switch to another app, upon finishing it brings your original window back to the front and auto-pastes.
- **Hybrid Fallback to Apple Silicon Whisper (MLX):** If Apple Speech ever returns an empty result, the app seamlessly triggers local `mlx_whisper` in the background to salvage the text from a parallel raw WAV recording.
- **100% Native & Private:** Built in pure Swift using Cocoa, AVFoundation, Speech, and Carbon. Uses under 30 MB of RAM, zero external server calls, zero telemetry.

---

## 🇪🇸 Descripción en Español

### ¿Por qué fallan las demás opciones de dictado?

1. **El dictado online en la nube se corta y tiene lag:**  
   Las herramientas que envían el audio a internet se demoran entre 3 y 5 segundos por frase, se desconectan si la señal fluctúa y envían información privada de tus proyectos a servidores externos.
2. **Cobros mensuales excesivos:**  
   Las aplicaciones comerciales para Mac cobran suscripciones mensuales recurrentes por funciones básicas de teclado.
3. **El colapso secreto de Apple a los 60 segundos:**  
   El reconocedor local de Apple (`SFSpeechRecognizer`) tiene una ventana deslizante oculta de 60–63 segundos. Al llegar a ese tiempo, el motor vacía silenciosamente su memoria sin avisar. Cualquier programa convencional borra de golpe todo tu párrafo acumulado y empieza desde cero con la siguiente palabra suelta.

### La Solución de OpenMacDictate (Dictado Domotex)

- **Acumulador Monotónico Indestructible:** Si Apple reinicia su búfer, el sistema congela y protege todo el texto previo y le añade las palabras nuevas. **Nunca se reinicia ni se pierde lo que has dictado**.
- **Rotación Proactiva a los 45s:** El programa renueva la tarea en milisegundos sin pausar el micrófono. Puedes dictar durante **5, 10 o 30 minutos continuos**.
- **Respaldo en Tiempo Real:** Cada palabra dicha queda copiada al portapapeles y al archivo `~/Library/Logs/UltimoDictado.txt`.
- **Memoria de Ventana:** Si cambias de pantalla mientras hablas, al terminar devuelve el foco a la ventana original (Antigravity, Cursor, VS Code, Word, Chrome) y pega el texto automáticamente.
- **Respaldo con Whisper MLX Local:** Si el micrófono físico llegase a fallar, rescata el audio con Whisper en el Neural Engine de tu Apple Silicon.

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

## 🏗️ Architecture / Arquitectura (v5.0 Titanium Edition)

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
Whisper MLX Daemon (Pre-warmed on Apple Silicon GPU Metal / Neural Engine)
       │
       ├──► Transcribes with domain biasing (RETIE, Domotex, CELSA, EPM) in < 0.3s
       │
       ├──► Triple Fallback (Daemon Socket → MLX CLI → Apple Speech URL)
       │
       ▼
Auto-Paste Engine (CGEvent ⌘V into Target Application) + Persistent Backup
```

### Key Advancements in v5.0:
1. **Pure PCM Hardware Capture (`AVAudioRecorder`)**: Bypasses unstable `AVAudioEngine` audio graph connection deadlocks. 100% resilient to Bluetooth sample rate switching (e.g. Sony WH-1000XM5, AirPods) between 16kHz SCO and 44.1kHz A2DP.
2. **Resident Whisper MLX Daemon**: Keeps `whisper-small-mlx` in unified memory on Apple Silicon GPU Metal. Eliminates Python startup overhead, transcribing audio in **~0.25 seconds**!
3. **Domain Prompt Biasing**: Ensures 100% precision with technical terminology ("kVA", "kW", "RETIE", "NTC 2050", "transformador", "luminarias").
4. **Zero-Loss Physical Guarantee**: Audio is captured directly to WAV on disk. Even in case of power failure or crash, your recorded audio is physically preserved in `~/Library/Logs/UltimoDictado.wav`.

       │    Target App Restore & Auto-Paste (Cmd+V via CGEvent)
       │
       └──► Parallel PCM WAV Recorder (/tmp/dictado_ultimo.wav)
                 │ (Fallback if Apple returns empty)
                 ▼
            Local MLX Whisper Runner (Apple Silicon GPU/ANE)
```

---

## 📄 License / Licencia

Distributed under the **MIT License**. See `LICENSE` for more information.  
Desarrollado por **Sebastián Muñoz — DOMOTEX** ([@jsmm888-DOMOTEX](https://github.com/jsmm888-DOMOTEX)).
