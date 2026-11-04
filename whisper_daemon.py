#!/usr/bin/env python3
"""
Whisper MLX Daemon — Dictado Domotex v5.0
Procesador residente de voz a texto de ultra-alta velocidad sobre Apple Silicon GPU (Metal/MLX).
Mantiene el modelo en memoria para transcribir audios en < 0.3 segundos sin latencia de arranque.
"""

import os
import sys

# Asegurar que las rutas de herramientas del sistema (ffmpeg, python, homebrew) estén siempre presentes
os.environ["PATH"] = (
    "/Users/sebastianmunoz/.local/bin:"
    "/opt/homebrew/bin:"
    "/opt/homebrew/sbin:"
    "/usr/local/bin:"
    + os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
)

import socket
import signal
import time
import json
from pathlib import Path

SOCKET_PATH = "/tmp/dictado_whisper.sock"
LOG_PATH = Path.home() / "Library/Logs/DictadoDomotex_Daemon.log"
MODEL_ID = "mlx-community/whisper-small-mlx"

# Vocabulario de polarización contextual para ingeniería eléctrica, Domotex y CELSA
INITIAL_PROMPT = (
    "Domotex, Sebastián Muñoz, CELSA, RETIE, RETILAP, NTC 2050, EPM, "
    "transformador, subestación, luminaria, fotometría, calibre, disyuntor, "
    "amperios, voltios, kilovatios, kVA, kW, factor de potencia, canalización, "
    "cuadro de cargas, memoria de cálculo, puesta a tierra."
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

def main():
    cleanup()
    log("==================================================")
    log("Iniciando Whisper MLX Daemon (Dictado Domotex v5.0)")
    log(f"Cargando modelo '{MODEL_ID}' en GPU Metal...")

    try:
        import mlx_whisper
    except ImportError as e:
        log(f"ERROR FATAL: No se pudo importar mlx_whisper: {e}")
        sys.exit(1)

    t0 = time.time()
    # Generar o utilizar un micro-audio de prueba para calentar el pipeline de MLX en memoria
    dummy_wav = "/tmp/audio_test.wav"
    if not os.path.exists(dummy_wav):
        # Crear un archivo wav mínimo de silencio si no existe
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
            initial_prompt=INITIAL_PROMPT
        )
        t1 = time.time()
        log(f"Modelo cargado y pre-calentado exitosamente en {t1 - t0:.2f}s.")
    except Exception as e:
        log(f"Aviso en pre-calentamiento: {e}")

    # Crear socket Unix
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(SOCKET_PATH)
        server.listen(5)
        # Permisos accesibles para cualquier proceso del usuario
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

                wav_path = raw_data
                if not os.path.exists(wav_path):
                    log(f"Error: Archivo de audio no encontrado: {wav_path}")
                    conn.sendall(b"")
                    continue

                file_size = os.path.getsize(wav_path)
                if file_size < 1000:
                    log(f"Audio demasiado corto ({file_size} bytes). Descartando.")
                    conn.sendall(b"")
                    continue

                log(f"Transcribiendo audio: {wav_path} ({file_size} bytes)...")
                t_start = time.time()

                try:
                    res = mlx_whisper.transcribe(
                        wav_path,
                        path_or_hf_repo=MODEL_ID,
                        language="es",
                        temperature=0.0,
                        initial_prompt=INITIAL_PROMPT,
                        condition_on_previous_text=False
                    )
                    text = res.get("text", "").strip()
                    t_end = time.time()
                    elapsed = t_end - t_start
                    log(f"Transcriptor completado en {elapsed:.3f}s: \"{text[:80]}...\" ({len(text)} car)")
                    conn.sendall(text.encode("utf-8"))
                except Exception as e:
                    log(f"Error en transcripción MLX: {e}")
                    conn.sendall(b"")

        except Exception as e:
            log(f"Aviso en bucle de socket: {e}")

    cleanup()
    log("Daemon finalizado.")

if __name__ == "__main__":
    main()
