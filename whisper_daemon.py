#!/usr/bin/env python3
"""
Whisper MLX Daemon — Dictado Domotex v5.6 (Titanio Turbo & Anti-Ruido DSP con Blindaje VAD)
Arquitectura de Audio Acústico & Metal GPU para Apple Silicon.

Diseñado para el Ingeniero Sebastián Muñoz (macOS Tahoe / Sequoia / Apple Silicon).
Mantiene en memoria residente Whisper Large v3 Turbo en GPU Metal + Silero VAD para
transcribir cualquier audio con filtrado acústico de música y ruido de fondo,
utilizando un protocolo de comunicación estructurado JSON sobre socket UNIX.
"""

import os
import sys
import re
import socket
import signal
import time
import json
import warnings
from pathlib import Path

# Suprimir advertencias menores de PyTorch para mantener los logs limpios
warnings.filterwarnings("ignore")

# Asegurar que las rutas de herramientas del sistema estén siempre presentes
os.environ["PATH"] = (
    "/Users/sebastianmunoz/.local/bin:"
    "/opt/homebrew/bin:"
    "/opt/homebrew/sbin:"
    "/usr/local/bin:"
    + os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
)

import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal
import torch

SOCKET_PATH = "/tmp/dictado_whisper.sock"
LOG_PATH = Path.home() / "Library/Logs/DictadoDomotex_Daemon.log"
MODEL_ID = "mlx-community/whisper-large-v3-turbo"

# Prompt contextual optimizado para ingeniería eléctrica, Domotex y CELSA
INITIAL_PROMPT = (
    "Transcripción técnica en español de Colombia para ingeniería eléctrica, DOMOTEX y CELSA. "
    "Sebastián Muñoz, RETIE 40284, RETILAP, NTC 2050, EPM, transformador, subestación, luminaria, "
    "fotometría, calibre, disyuntor, amperios, voltios, kilovatios, kVA, kW, factor de potencia, "
    "canalización, cuadro de cargas, memoria de cálculo, puesta a tierra, citofonía, cotización, presupuesto."
)

def log(msg: str):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {msg}\n"
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass
    print(line, end="", flush=True)

def cleanup():
    if os.path.exists(SOCKET_PATH):
        try:
            os.remove(SOCKET_PATH)
        except OSError:
            pass

def signal_handler(signum, frame):
    log(f"Recibida señal {signum}, cerrando daemon limpiamente...")
    cleanup()
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

def load_audio_16k(wav_path: str):
    """
    Carga robusta de archivos WAV de cualquier formato (16-bit PCM, IEEE Float32, 24/32-bit).
    Convierte a mono y remuestrea a 16000 Hz float32 (-1.0 a 1.0).
    """
    sr = 16000
    data = None
    try:
        sr, data = wavfile.read(wav_path)
    except Exception:
        import wave
        with wave.open(wav_path, "rb") as wf:
            sr = wf.getframerate()
            n_ch = wf.getnchannels()
            sw = wf.getsampwidth()
            raw = wf.readframes(wf.getnframes())
            if sw == 2:
                data = np.frombuffer(raw, dtype=np.int16)
            elif sw == 4:
                data = np.frombuffer(raw, dtype=np.int32)
            else:
                data = np.frombuffer(raw, dtype=np.uint8).astype(np.int16) - 128
            if n_ch > 1:
                data = data.reshape(-1, n_ch)

    if data is None or len(data) == 0:
        return 16000, np.zeros(0, dtype=np.float32)

    # Convertir a mono si es multicanal
    if data.ndim > 1:
        data = np.mean(data, axis=1)

    # Normalizar escala numérica a float32 (-1.0 a 1.0)
    if np.issubdtype(data.dtype, np.floating):
        audio = data.astype(np.float32)
    elif data.dtype == np.int16:
        audio = (data / 32768.0).astype(np.float32)
    elif data.dtype == np.int32:
        audio = (data / 2147483648.0).astype(np.float32)
    else:
        audio = data.astype(np.float32)

    # Remuestrear a 16000 Hz si la fuente difiere
    if sr != 16000:
        num_target = int(len(audio) * 16000 / sr)
        audio = scipy.signal.resample(audio, num_target).astype(np.float32)
        sr = 16000

    return sr, audio

def apply_dsp_bandpass(audio: np.ndarray, sr: int = 16000) -> np.ndarray:
    """
    Filtro paso banda Butterworth acústico (80 Hz a 7500 Hz, orden 4).
    Elimina sub-bajos de música (bombos, 808s, resonancias graves) y siseos agudos.
    """
    if len(audio) < 160:
        return audio
    nyq = 0.5 * sr
    low = 80.0 / nyq
    high = min(7500.0 / nyq, 0.99)
    sos = scipy.signal.butter(4, [low, high], btype="bandpass", output="sos")
    filtered = scipy.signal.sosfiltfilt(sos, audio).astype(np.float32)
    return filtered

def clean_transcription(text: str) -> str:
    """
    Filtro de salida anti-alucinaciones:
    - Remueve etiquetas sonoras ([Música], (Música), ♪, etc.).
    - Elimina frases residuales de subtítulos de YouTube/Whisper.
    - Colapsa repeticiones patológicas consecutivas.
    - Colapsa secuencias de puntos o signos repetidos.
    - Exige al menos 2 caracteres alfanuméricos para evitar emitir puntos o símbolos sueltos.
    """
    if not text:
        return ""

    # 1. Eliminar etiquetas de audio no vocal
    for pat in [
        r'\[[Mm]úsic[a-z]*\]', r'\([Mm]úsic[a-z]*\)',
        r'\[[Aa]plausos*\]', r'\([Aa]plausos*\)',
        r'\[[Rr]uido*\]', r'\([Rr]uido*\)',
        r'\[[Ss]ilencio*\]', r'\([Ss]ilencio*\)',
        r'\[[Ss]onido*\]', r'\([Ss]onido*\)',
        r'[♪♫]+',
    ]:
        text = re.sub(pat, '', text)

    # 2. Filtrar frases típicas de alucinación de subtítulos de YouTube/Whisper
    hallucination_phrases = [
        r'subt[íi]tulos\s+por\s+la\s+comunidad.*',
        r'subt[íi]tulos\s+realizados\s+por.*',
        r'subtitulado\s+por.*',
        r'gracias\s+por\s+ver\s+(el\s+)?(video|vídeo).*',
        r'¡?suscr[íi]bete\s+al\s+canal!?.*',
        r'suscr[íi]bete\s+y\s+dale\s+like.*',
        r'nos\s+vemos\s+en\s+el\s+pr[óo]ximo\s+(video|vídeo).*',
        r'amara\.org',
    ]
    for pat in hallucination_phrases:
        text = re.sub(pat, '', text, flags=re.IGNORECASE)

    # 3. Colapsar frases repetidas consecutivas (ej: "frase X. frase X.")
    text = re.sub(r'(.{10,50}?)(?:,\s*|\.\s*|\s+)\1', r'\1', text, flags=re.IGNORECASE)

    # 4. Colapsar palabras repetidas 3 o más veces consecutivas ("la la la la" -> "la")
    text = re.sub(r'\b(\w+)(\s+\1){2,}\b', r'\1', text, flags=re.IGNORECASE)

    # 5. Colapsar secuencias de puntos o comas repetidas ("....", "..", ",,")
    text = re.sub(r'\.{2,}', '.', text)
    text = re.sub(r',{2,}', ',', text)

    # 6. Limpieza final de signos sueltos y espacios
    text = re.sub(r'^[.,;:¡!¿?\s\-_]+', '', text)
    text = re.sub(r'\s+', ' ', text).strip()

    # 7. Rechazar cadenas que no contengan al menos 2 caracteres alfanuméricos
    alphanumeric_count = len(re.findall(r'[a-zA-Z0-9áéíóúÁÉÍÓÚñÑ]', text))
    if alphanumeric_count < 2:
        return ""

    return text

def main():
    cleanup()
    log("==================================================")
    log("Iniciando Whisper MLX Daemon v5.5 (Titanio Turbo & Anti-Ruido DSP)")
    log("Cargando detector acústico de voz Silero VAD...")

    torch.set_num_threads(4)
    try:
        vad_model, vad_utils = torch.hub.load(
            repo_or_dir="snakers4/silero-vad",
            model="silero_vad",
            trust_repo=True
        )
        get_speech_timestamps = vad_utils[0]
        log("Silero VAD residente en memoria listo.")
    except Exception as e:
        log(f"Aviso: Silero VAD no disponible ({e}). Operando con DSP puro.")
        vad_model = None
        get_speech_timestamps = None

    log(f"Cargando modelo MLX '{MODEL_ID}' en GPU Metal...")
    try:
        import mlx_whisper
    except ImportError as e:
        log(f"ERROR FATAL: No se pudo importar mlx_whisper: {e}")
        sys.exit(1)

    t0 = time.time()
    dummy_wav = "/tmp/audio_test_warmup.wav"
    if not os.path.exists(dummy_wav):
        import wave
        with wave.open(dummy_wav, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(16000)
            wf.writeframes(b"\x00" * 32000)

    try:
        _ = mlx_whisper.transcribe(
            dummy_wav,
            path_or_hf_repo=MODEL_ID,
            language="es",
            temperature=0.0,
            initial_prompt=INITIAL_PROMPT,
            condition_on_previous_text=False
        )
        t1 = time.time()
        log(f"Whisper Turbo pre-calentado exitosamente en GPU Metal en {t1 - t0:.2f}s.")
    except Exception as e:
        log(f"Aviso en pre-calentamiento MLX: {e}")

    # Crear socket Unix
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(SOCKET_PATH)
        server.listen(5)
        os.chmod(SOCKET_PATH, 0o777)
        log(f"Daemon activo y escuchando en socket: {SOCKET_PATH}")
    except Exception as e:
        log(f"ERROR: No se pudo enlazar socket Unix en {SOCKET_PATH}: {e}")
        sys.exit(1)

    while True:
        try:
            conn, _ = server.accept()
            with conn:
                raw_data = conn.recv(4096).decode("utf-8", errors="replace").strip()
                if not raw_data:
                    continue

                if raw_data == "PING":
                    conn.sendall(b"PONG\n")
                    continue
                elif raw_data == "STOP":
                    log("Comando STOP recibido. Apagando daemon.")
                    conn.sendall(b"OK\n")
                    break

                wav_path = None
                if raw_data.startswith("{"):
                    try:
                        req = json.loads(raw_data)
                        action = req.get("action", "transcribe")
                        if action == "ping":
                            conn.sendall(b'{"status": "ok", "message": "pong"}\n')
                            continue
                        elif action == "stop":
                            log("Comando STOP recibido vía JSON. Apagando daemon.")
                            conn.sendall(b'{"status": "ok", "message": "stopping"}\n')
                            break
                        wav_path = req.get("audio_path") or req.get("path")
                    except Exception as e:
                        log(f"Error parseando JSON entrante: {e}")
                        resp = {"status": "error", "message": f"JSON inválido: {e}", "text": ""}
                        conn.sendall(json.dumps(resp, ensure_ascii=False).encode("utf-8") + b"\n")
                        continue
                else:
                    wav_path = raw_data

                if not wav_path or not os.path.exists(wav_path):
                    log(f"Error: Archivo de audio no encontrado: {wav_path}")
                    resp = {"status": "error", "message": f"Archivo no encontrado: {wav_path}", "text": ""}
                    conn.sendall(json.dumps(resp, ensure_ascii=False).encode("utf-8") + b"\n")
                    continue

                file_size = os.path.getsize(wav_path)
                if file_size < 3000:
                    log(f"Audio demasiado corto ({file_size} bytes). Descartando.")
                    resp = {"status": "no_speech", "reason": "file_size_too_small", "duration": 0.0, "text": ""}
                    conn.sendall(json.dumps(resp, ensure_ascii=False).encode("utf-8") + b"\n")
                    continue

                t_start = time.time()

                # 1. Carga de audio en memoria
                sr, audio = load_audio_16k(wav_path)
                duration = len(audio) / sr
                if duration < 0.3:
                    log(f"Duración de audio nula o ínfima ({duration:.2f}s). Descartando.")
                    resp = {"status": "no_speech", "reason": "duration_too_short", "duration": round(duration, 2), "text": ""}
                    conn.sendall(json.dumps(resp, ensure_ascii=False).encode("utf-8") + b"\n")
                    continue

                # 2. Pre-procesamiento DSP: Filtro paso banda acústico (80 Hz - 7500 Hz)
                t_dsp = time.time()
                audio_filt = apply_dsp_bandpass(audio, sr)
                dsp_ms = (time.time() - t_dsp) * 1000

                # 3. Puerta Vocal Silero VAD (Anti-Música y Anti-Silencio)
                if vad_model is not None and get_speech_timestamps is not None:
                    t_vad = time.time()
                    wav_tensor = torch.from_numpy(audio_filt)
                    ts = get_speech_timestamps(
                        wav_tensor,
                        vad_model,
                        sampling_rate=sr,
                        threshold=0.15,
                        speech_pad_ms=250
                    )
                    vad_ms = (time.time() - t_vad) * 1000

                    if not ts:
                        log(f"VAD Gate: Cero voz detectada en {duration:.1f}s (DSP: {dsp_ms:.1f}ms, VAD: {vad_ms:.1f}ms). "
                            "Bloqueando para evitar alucinaciones con música/silencio.")
                        resp = {
                            "status": "no_speech",
                            "reason": "vad_gate",
                            "duration": round(duration, 2),
                            "text": ""
                        }
                        conn.sendall(json.dumps(resp, ensure_ascii=False).encode("utf-8") + b"\n")
                        continue

                    speech_dur = sum([(s['end'] - s['start']) for s in ts]) / sr
                    log(f"Audio {duration:.1f}s -> Voz detectada: {len(ts)} segmentos ({speech_dur:.1f}s) "
                        f"[DSP: {dsp_ms:.1f}ms | VAD: {vad_ms:.1f}ms]")

                # 4. Normalización dinámica de pico a -0.5 dBFS
                max_amp = np.max(np.abs(audio_filt))
                if max_amp > 1e-4:
                    norm_audio = audio_filt / max_amp * 0.95
                else:
                    norm_audio = audio_filt

                # 5. Inferencia con Whisper Large v3 Turbo en MLX Metal GPU
                t_infer = time.time()
                try:
                    res = mlx_whisper.transcribe(
                        norm_audio,
                        path_or_hf_repo=MODEL_ID,
                        language="es",
                        temperature=0.0,
                        compression_ratio_threshold=2.2,
                        logprob_threshold=-1.0,
                        no_speech_threshold=0.6,
                        hallucination_silence_threshold=1.5,
                        initial_prompt=INITIAL_PROMPT,
                        condition_on_previous_text=False
                    )
                    raw_text = res.get("text", "").strip()
                    infer_time = time.time() - t_infer

                    # 6. Desinfección y limpieza de salida
                    final_text = clean_transcription(raw_text)
                    total_time = time.time() - t_start

                    alphanumeric_count = len(re.findall(r'[a-zA-Z0-9áéíóúÁÉÍÓÚñÑ]', final_text))
                    if not final_text or alphanumeric_count < 2:
                        log(f"Descartado post-inferencia por falta de palabras reales: \"{raw_text}\" -> \"{final_text}\"")
                        resp = {
                            "status": "no_speech",
                            "reason": "transcription_empty_or_symbols_only",
                            "duration": round(duration, 2),
                            "inference_time": round(infer_time, 3),
                            "text": ""
                        }
                    else:
                        log(f"Completado en {total_time:.3f}s (Inferencia: {infer_time:.3f}s): "
                            f"\"{final_text[:80]}...\" ({len(final_text)} car)")
                        resp = {
                            "status": "ok",
                            "text": final_text,
                            "duration": round(duration, 2),
                            "inference_time": round(infer_time, 3)
                        }

                    conn.sendall(json.dumps(resp, ensure_ascii=False).encode("utf-8") + b"\n")
                except Exception as e:
                    log(f"Error en transcripción MLX Turbo: {e}")
                    resp = {"status": "error", "message": str(e), "text": ""}
                    conn.sendall(json.dumps(resp, ensure_ascii=False).encode("utf-8") + b"\n")

        except Exception as e:
            log(f"Aviso en bucle de socket: {e}")

    cleanup()
    log("Daemon finalizado.")

if __name__ == "__main__":
    main()
