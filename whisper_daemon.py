#!/usr/bin/env python3
"""
Whisper MLX Daemon — Dictado Domotex v5.6 (Titanio Turbo & Anti-Ruido DSP con Blindaje VAD)
Arquitectura de Audio Acústico & Metal GPU para Apple Silicon.

Diseñado para macOS (Apple Silicon / GPU Metal).
Mantiene en memoria residente Whisper Large v3 Turbo en GPU Metal + Silero VAD para
transcribir cualquier audio con filtrado acústico de música y ruido de fondo,
utilizando un protocolo de comunicación estructurado JSON sobre socket UNIX privado.
"""

import os
import sys
import re
import socket
import signal
import tempfile
import time
import json
import warnings
from pathlib import Path

# Suprimir advertencias menores de PyTorch para mantener los logs limpios
warnings.filterwarnings("ignore")

# Asegurar que las rutas de herramientas del sistema estén siempre presentes
os.environ["PATH"] = (
    f"{Path.home()}/.local/bin:"
    "/opt/homebrew/bin:"
    "/opt/homebrew/sbin:"
    "/usr/local/bin:"
    + os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
)

import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal
import torch

APP_SUPPORT_DIR = Path.home() / "Library/Application Support/OpenMacDictate"
APP_SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
os.chmod(APP_SUPPORT_DIR, 0o700)

SOCKET_PATH = str(APP_SUPPORT_DIR / "dictado_whisper.sock")
LOG_PATH = Path.home() / "Library/Logs/DictadoDomotex_Daemon.log"
MODEL_ID = "mlx-community/whisper-large-v3-turbo"

DEFAULT_INITIAL_PROMPT = (
    "Transcripción técnica en español e inglés para ingeniería, desarrollo de software, "
    "GitHub, Python, Swift, VS Code, Docker, Colab y arquitectura en Mac."
)


def _cargar_vocabulario_local() -> tuple[str, list[tuple[re.Pattern, str]]]:
    """Carga prompt y reemplazos personalizados desde un archivo local privado (fuera del repo)."""
    candidatos = [
        APP_SUPPORT_DIR / "vocabulario_local.json",
        Path(__file__).resolve().parent / "vocabulario_local.json",
    ]
    for ruta in candidatos:
        if ruta.is_file():
            try:
                data = json.loads(ruta.read_text(encoding="utf-8"))
                prompt = str(data.get("initial_prompt") or DEFAULT_INITIAL_PROMPT).strip()
                reglas: list[tuple[re.Pattern, str]] = []
                for item in data.get("reemplazos", []):
                    patron = item.get("patron")
                    reemplazo = item.get("reemplazo", "")
                    if not patron:
                        continue
                    flags = re.IGNORECASE if "i" in str(item.get("flags", "i")).lower() else 0
                    reglas.append((re.compile(patron, flags), reemplazo))
                return prompt, reglas
            except Exception:
                pass
    return DEFAULT_INITIAL_PROMPT, []


INITIAL_PROMPT, _REEMPLAZOS_LOCALES = _cargar_vocabulario_local()

# Filtro paso banda Butterworth de 4to orden pre-calculado para 16 kHz (80 Hz - 7500 Hz)
_SOS_BP_16K = scipy.signal.butter(4, [80.0 / 8000.0, 7500.0 / 8000.0], btype="bandpass", output="sos")


def _format_carbon_tier(match: re.Match) -> str:
    tier_raw = match.group(1).lower()
    mapping = {
        "high": "High",
        "medium": "Medium",
        "low": "Low",
        "alto": "Alto",
        "medio": "Medio",
        "bajo": "Bajo",
        "pro": "Pro",
        "full": "full",
    }
    return f"Carbon {mapping.get(tier_raw, tier_raw.capitalize())}"


def _format_argon_tier(match: re.Match) -> str:
    tier_raw = match.group(1).lower()
    if tier_raw in ("medio", "medium"):
        return "Argon Medium"
    mapping = {
        "high": "High",
        "low": "Low",
        "alto": "Alto",
        "bajo": "Bajo",
        "pro": "Pro",
    }
    return f"Argon {mapping.get(tier_raw, tier_raw.capitalize())}"


def corregir_dictado_tecnico(texto: str) -> str:
    """Motor de Corrección Fonética y Léxica v2.0."""
    if not texto:
        return ""
    t = texto

    for patron_local, reemplazo_local in _REEMPLAZOS_LOCALES:
        t = patron_local.sub(reemplazo_local, t)

    # 1. Repositorios, IDEs y herramientas de software / IA
    t = re.sub(
        r'\b(G-?HAP|G-?HUB|GIHUB|GHAP|G-?JAP|GITHUD|GIT\s+HUB|GUIJAP|GUITJAP)\b',
        'GitHub',
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(r'\b(en|de|a|con|para)\s+g-?hap\b', r'\1 GitHub', t, flags=re.IGNORECASE)
    t = re.sub(
        r'\b(?:Antigrack|Antigrak|Antigrafiti|Anti[\s\-]?gravity|Antigraviti|Antigrabity)\b',
        'Antigravity',
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(r'\bGoogle\s+Collab?\b', 'Google Colab', t, flags=re.IGNORECASE)
    t = re.sub(r'\bCollab\b', 'Colab', t, flags=re.IGNORECASE)
    t = re.sub(r'\ben\s+el\s+colab\b', 'en el Colab', t, flags=re.IGNORECASE)
    t = re.sub(r'\b(?:Obsidia|Osidian|Oxidian)\b', 'Obsidian', t, flags=re.IGNORECASE)
    t = re.sub(r'\ben\s+Obsidiana\b', 'en Obsidian', t, flags=re.IGNORECASE)
    t = re.sub(
        r'\b(un|el|los|servidor|conector|protocolo)\s+msp\b',
        r'\1 MCP',
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(r'\bmcp\b', 'MCP', t, flags=re.IGNORECASE)
    t = re.sub(r'\b(?:mark\s*daba|mark\s*down|mard[áa]n)\b', 'Markdown', t, flags=re.IGNORECASE)
    t = re.sub(r'\bblender\s+3d\b', 'Blender 3D', t, flags=re.IGNORECASE)
    t = re.sub(r'\bblender\b', 'Blender', t, flags=re.IGNORECASE)
    t = re.sub(r'\bdomo\s*plano\b', 'DomoPlano', t, flags=re.IGNORECASE)

    # 2. Modelos de IA: separación estricta entre Carbon y Argon + Flash + Claude
    t = re.sub(r'\bgemini\s*4\s*carb[óo]n\b', 'Gemini 4 Carbon', t, flags=re.IGNORECASE)
    t = re.sub(r'\bgemini\s*4\s*(?:arg[óo]n|[áa]rbol)\b', 'Gemini 4 Argon', t, flags=re.IGNORECASE)

    t = re.sub(
        r'\bcarb[óo]n\s+(high|medium|low|alto|medio|bajo|pro|full)\b',
        _format_carbon_tier,
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(
        r'\b(modelo|agente|usar|usa|ponme|pon|con|c[óo]digo|auditor|dile\s+a|ensayos?\s+con)\s+carb[óo]n\b',
        r'\1 Carbon',
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(r'\bcarbon\b', 'Carbon', t, flags=re.IGNORECASE)

    t = re.sub(
        r'\b(?:arg[óo]n|[áa]rbol)\s+(high|medium|medio|low|bajo|alto|pro)\b',
        _format_argon_tier,
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(
        r'\b(modelo|agente|usar|usa|ponme|pon|tarea\s+de)\s+(?:arg[óo]n|[áa]rbol)\b',
        r'\1 Argon',
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(r'(?<!gas\s)\barg[óo]n\b', 'Argon', t, flags=re.IGNORECASE)

    t = re.sub(
        r'\bgemini\s*3[\.,]8\s*(?:flash|plans?|plahs?|flas|flach|clash|flush)\s+high\b',
        'Gemini 3.8 Flash High',
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(
        r'\bgemini\s*3[\.,]8\s*(?:flash|plans?|plahs?|flas|flach|clash|flush)\s+lite\b',
        'Gemini 3.8 Flash Lite',
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(
        r'\bgemini\s*3[\.,]8\s*(?:flash|plans?|plahs?|flas|flach|clash|flush)\b',
        'Gemini 3.8 Flash',
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(
        r'\b3[\.,]8\s*(?:flash|plans?|plahs?|flas|flach|clash|flush)\b',
        '3.8 Flash',
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(r'\bflash\s+plans?\b', 'Flash', t, flags=re.IGNORECASE)
    t = re.sub(r'\bflash\s+high\b', 'Flash High', t, flags=re.IGNORECASE)
    t = re.sub(r'\bflash\s+lite\b', 'Flash Lite', t, flags=re.IGNORECASE)

    t = re.sub(
        r'\b(?:Claude|Cloud|Clod)\s+(Opus|Sonnet|Haiku|Code)\b',
        lambda m: f"Claude {m.group(1).capitalize()}",
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(
        r'(?<!Google\s)\b(con|de|en|a|para|agente|modelo|copiarlo\s+de|como\s+se\s+hace\s+en)\s+cloud\b'
        r'(?!\s+(?:Storage|Run|SQL|Functions|Composer|Build|Platform|Drive|Flare))',
        r'\1 Claude',
        t,
        flags=re.IGNORECASE,
    )

    # 3. Vocabulario personalizado adicional se carga desde vocabulario_local.json (fuera del repositorio)

    # 4. Normativa, Energía Solar, Unidades y Modismos Técnicos Colombianos
    t = re.sub(r'\b(?:retie|retye)\b', 'RETIE', t, flags=re.IGNORECASE)
    t = re.sub(r'\b(?:retilap|retilab)\b', 'RETILAP', t, flags=re.IGNORECASE)
    t = re.sub(r'\bntc\s*20\s*50\b', 'NTC 2050', t, flags=re.IGNORECASE)
    t = re.sub(r'\bcreg\s*(\d{2,3})\b', r'CREG \1', t, flags=re.IGNORECASE)
    t = re.sub(r'\bra\s*8[\s\-]*001\b', 'RA8-001', t, flags=re.IGNORECASE)
    t = re.sub(r'\bepm\b', 'EPM', t, flags=re.IGNORECASE)
    t = re.sub(r'\bdian\b', 'DIAN', t, flags=re.IGNORECASE)
    t = re.sub(r'\bupme\b', 'UPME', t, flags=re.IGNORECASE)
    t = re.sub(r'\bagpe\b', 'AGPE', t, flags=re.IGNORECASE)
    t = re.sub(r'\bautogen\b', 'AutoGen', t, flags=re.IGNORECASE)
    t = re.sub(r'\bmetagpt\b', 'MetaGPT', t, flags=re.IGNORECASE)
    t = re.sub(r'\begm\b', 'EGM', t, flags=re.IGNORECASE)
    t = re.sub(r'\bpytorch\b', 'PyTorch', t, flags=re.IGNORECASE)

    t = re.sub(
        r'\binversor(es)?\s+(?:de\s+ye|deye|daye|delle)\b',
        lambda m: f"inversor{'es' if m.group(1) else ''} Deye",
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(r'\b(?:growatt|growat|groguat)\b', 'Growatt', t, flags=re.IGNORECASE)
    t = re.sub(r'\b(?:hoymiles|hoy\s+miles|hoimiles)\b', 'Hoymiles', t, flags=re.IGNORECASE)

    t = re.sub(r'\b(\d+(?:[.,]\d+)?)\s*kva\b', r'\1 kVA', t, flags=re.IGNORECASE)
    t = re.sub(r'\b(\d+(?:[.,]\d+)?)\s*kwh\b', r'\1 kWh', t, flags=re.IGNORECASE)
    t = re.sub(r'\b(\d+(?:[.,]\d+)?)\s*kwp\b', r'\1 kWp', t, flags=re.IGNORECASE)
    t = re.sub(r'\b(\d+(?:[.,]\d+)?)\s*kw\b', r'\1 kW', t, flags=re.IGNORECASE)

    t = re.sub(r'\bbarqueaderos\b', 'parqueaderos', t, flags=re.IGNORECASE)
    t = re.sub(r'\bbarqueadero\b', 'parqueadero', t, flags=re.IGNORECASE)
    t = re.sub(
        r'\b(una|dos|tres|cuatro|cinco)\s+cometida(s?)\b',
        r'\1 acometida\2',
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(r'\b(?:breker|brequer)\b', 'breaker', t, flags=re.IGNORECASE)
    t = re.sub(r'\b(?:brekers|brequers|breques)\b', 'breakers', t, flags=re.IGNORECASE)
    t = re.sub(r'\bahce\b', 'hace', t, flags=re.IGNORECASE)
    t = re.sub(r'\b(?:eificnete|eficente)\b', 'eficiente', t, flags=re.IGNORECASE)

    t = re.sub(r'\s+', ' ', t).strip()
    return t

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
    Filtro paso banda Butterworth acústico (80 Hz a 7500 Hz, orden 4) con remoción previa de DC.
    Elimina sub-bajos de música (bombos, 808s, resonancias graves) y siseos agudos.
    """
    if len(audio) < 160:
        return audio
    audio_zero_dc = (audio - float(np.mean(audio))).astype(np.float32)
    if sr == 16000:
        return scipy.signal.sosfiltfilt(_SOS_BP_16K, audio_zero_dc).astype(np.float32)
    nyq = 0.5 * sr
    low = 80.0 / nyq
    high = min(7500.0 / nyq, 0.99)
    sos = scipy.signal.butter(4, [low, high], btype="bandpass", output="sos")
    return scipy.signal.sosfiltfilt(sos, audio_zero_dc).astype(np.float32)

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

    # 3. Colapsar palabras individuales repetidas con comas, puntos o signos (ej: "No, no, no, no...")
    text = re.sub(r'\b([a-zA-Z0-9áéíóúÁÉÍÓÚñÑ]+)(?:[,\s\.\-¡!¿?]+(?:\1)){2,}\b', r'\1', text, flags=re.IGNORECASE)

    # 4. Colapsar frases cortas repetidas con comas, puntos o signos (ej: "no te voy, no te voy")
    text = re.sub(r'(.{3,40}?)(?:[,\s\.\-¡!¿?]+)\1(?:[,\s\.\-¡!¿?]+)\1', r'\1', text, flags=re.IGNORECASE)

    # 5. Colapsar frases largas repetidas consecutivas (ej: "frase X. frase X.")
    text = re.sub(r'(.{10,60}?)(?:,\s*|\.\s*|\s+)\1', r'\1', text, flags=re.IGNORECASE)

    # 6. Colapsar secuencias de puntos o comas repetidas ("....", "..", ",,")
    text = re.sub(r'\.{2,}', '.', text)
    text = re.sub(r',{2,}', ',', text)

    # 7. Limpieza final de signos sueltos y espacios
    text = re.sub(r'^[.,;:¡!¿?\s\-_]+', '', text)
    text = re.sub(r'\s+', ' ', text).strip()

    # 7. Rechazar cadenas que no contengan al menos 2 caracteres alfanuméricos
    alphanumeric_count = len(re.findall(r'[a-zA-Z0-9áéíóúÁÉÍÓÚñÑ]', text))
    if alphanumeric_count < 2:
        return ""

    return corregir_dictado_tecnico(text)

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
        import mlx.core as mx
        import mlx_whisper
    except ImportError as e:
        log(f"ERROR FATAL: No se pudo importar mlx_whisper: {e}")
        sys.exit(1)

    t0 = time.time()
    dummy_wav = str(Path(tempfile.gettempdir()) / f"open_mac_dictate_warmup_{os.getuid()}.wav")
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
        mx.clear_cache()
        t1 = time.time()
        log(f"Whisper Turbo Carbon v2.0 pre-calentado en GPU Metal ({mx.metal.is_available()}) en {t1 - t0:.2f}s.")
    except Exception as e:
        log(f"Aviso en pre-calentamiento MLX: {e}")

    # Crear socket Unix con permisos restringidos al propietario (0o600 en vez de 0o777)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(SOCKET_PATH)
        server.listen(8)
        os.chmod(SOCKET_PATH, 0o600)
        log(f"Daemon activo y escuchando en socket seguro (0600): {SOCKET_PATH}")
    except Exception as e:
        log(f"ERROR: No se pudo enlazar socket Unix en {SOCKET_PATH}: {e}")
        sys.exit(1)

    infer_counter = 0
    while True:
        try:
            conn, _ = server.accept()
            conn.settimeout(5.0)
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
                            conn.sendall(b'{"status": "ok", "message": "pong", "version": "carbon-2.0"}\n')
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

                # 2. Pre-procesamiento DSP: Filtro paso banda acústico (80 Hz - 7500 Hz) + remoción DC
                t_dsp = time.time()
                audio_filt = apply_dsp_bandpass(audio, sr)
                dsp_ms = (time.time() - t_dsp) * 1000

                # 3. Puerta Vocal Silero VAD + Recorte de silencios muertos inicial/final
                if vad_model is not None and get_speech_timestamps is not None:
                    t_vad = time.time()
                    wav_tensor = torch.from_numpy(audio_filt)
                    ts = get_speech_timestamps(
                        wav_tensor,
                        vad_model,
                        sampling_rate=sr,
                        threshold=0.35,
                        speech_pad_ms=350
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
                    first_sample = max(0, int(ts[0]['start']) - int(0.15 * sr))
                    last_sample = min(len(audio_filt), int(ts[-1]['end']) + int(0.20 * sr))
                    if (last_sample - first_sample) >= int(0.3 * sr):
                        audio_filt = audio_filt[first_sample:last_sample]

                    log(f"Audio {duration:.1f}s -> Voz detectada: {len(ts)} segmentos ({speech_dur:.1f}s) "
                        f"[DSP: {dsp_ms:.1f}ms | VAD: {vad_ms:.1f}ms]")

                # 4. Normalización robusta por percentil 99.8 (inmune a clics) + limitador suave anti-clipping
                p998 = float(np.percentile(np.abs(audio_filt), 99.8))
                if p998 > 1e-4:
                    gain = min(max(0.89 / p998, 0.5), 8.0)
                    norm_audio = audio_filt * gain
                else:
                    norm_audio = audio_filt
                abs_a = np.abs(norm_audio)
                over = abs_a > 0.92
                if np.any(over):
                    norm_audio = np.where(
                        over,
                        np.sign(norm_audio) * (0.92 + 0.07 * np.tanh((abs_a - 0.92) / 0.07)),
                        norm_audio,
                    )
                norm_audio = np.clip(norm_audio, -0.99, 0.99).astype(np.float32)

                # 5. Inferencia con Whisper Large v3 Turbo en MLX Metal GPU
                t_infer = time.time()
                max_sample_tokens = min(224, max(32, int((len(norm_audio) / sr) * 14) + 20))
                try:
                    res = mlx_whisper.transcribe(
                        norm_audio,
                        path_or_hf_repo=MODEL_ID,
                        language="es",
                        temperature=0.0,
                        sample_len=max_sample_tokens,
                        compression_ratio_threshold=2.2,
                        logprob_threshold=-1.0,
                        no_speech_threshold=0.6,
                        initial_prompt=INITIAL_PROMPT,
                        condition_on_previous_text=False
                    )
                    infer_counter += 1
                    if len(norm_audio) > 16000 * 20 or (infer_counter % 20 == 0):
                        try:
                            mx.clear_cache()
                        except Exception:
                            pass
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
                        log(f"Completado en {total_time:.3f}s (Inferencia: {infer_time:.3f}s): {len(final_text)} caracteres")
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
