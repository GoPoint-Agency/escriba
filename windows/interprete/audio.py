"""Audio de Intérprete: los dos sentidos de la traducción.

- VoiceOut: tu micrófono real -> OpenAI -> micrófono virtual (VB-CABLE), con tu voz original bajita por debajo.
- Listen:   lo que suena en el computador -> OpenAI -> tus audífonos.

Los dispositivos se abren con `soundcard` (WASAPI en Windows). La captura de lo que suena usa, si está, el
ayudante `captura.exe`, que entrega el audio del sistema SIN el de esta app (si no, la traducción se volvería a
traducir a sí misma).
"""
import os
import subprocess
import sys
import threading
import time
import warnings

import numpy as np

from . import core
from .config import Config, log

warnings.filterwarnings("ignore", message="data discontinuity")
BLOCK = core.RATE // 50          # 20 ms
# Tamaño de bloque del dispositivo. En macOS (solo pruebas) el máximo es 512, así que se deja el que elija el sistema.
DEV_BLOCK = None if sys.platform == "darwin" else BLOCK * 2


def _sc():
    import soundcard
    return soundcard


def _com():
    """Cada hilo que toca audio en Windows tiene que iniciar COM."""
    if sys.platform == "win32":
        import ctypes
        ctypes.windll.ole32.CoInitializeEx(None, 0)


def microphones():
    return [m for m in _sc().all_microphones(include_loopback=False)]


def speakers():
    return list(_sc().all_speakers())


def is_virtual(name):
    n = name.lower()
    return any(k in n for k in ("cable", "blackhole", "vb-audio", "voicemeeter", "virtual"))


def virtual_mic():
    """La entrada del cable virtual: lo que se escribe aquí sale por el micrófono «CABLE Output»."""
    want = (os.environ.get("INTERPRETE_MIC_VIRTUAL") or Config.get("microfono_virtual") or "").lower()
    found = speakers()
    for s in found:
        if want and want in s.name.lower():
            return s
    for s in found:
        if "cable input" in s.name.lower() or "blackhole" in s.name.lower():
            return s
    return None


def real_mic():
    """Tu micrófono de verdad: el preferido en ajustes, o el del sistema, nunca uno virtual."""
    want = (Config.get("microfono") or "").lower()
    mics = microphones()
    if want:
        for m in mics:
            if want in m.name.lower() and not is_virtual(m.name):
                return m
    try:
        d = _sc().default_microphone()
        if d is not None and not is_virtual(d.name):
            return d
    except Exception:
        pass
    for m in mics:
        if not is_virtual(m.name):
            return m
    return None


def real_speaker():
    """Por donde escuchas: la salida del sistema, nunca el cable virtual."""
    forced = os.environ.get("INTERPRETE_SALIDA")          # solo para pruebas
    if forced:
        for s in speakers():
            if forced.lower() in s.name.lower():
                return s
    try:
        d = _sc().default_speaker()
        if d is not None and not is_virtual(d.name):
            return d
    except Exception:
        pass
    for s in speakers():
        if not is_virtual(s.name):
            return s
    return None


class _Session:
    """Lo común de los dos sentidos: conexión, hilos, cierre y resumen."""

    name = "Traducción"

    def __init__(self, on_stop=None):
        self.on_stop = on_stop or (lambda reason: None)
        self.running = False
        self.started = time.time()
        self.socket = None
        self.ring = core.Ring()
        self.chars = 0
        self._threads = []
        self._stopped = threading.Event()
        self.problem = None

    def _open_socket(self, language, voice=None):
        key = Config.api_key()
        if not key:
            raise core.TranslateError("Falta la clave de OpenAI.")
        # La voz que entrega el modelo a veces llega baja: se nivela antes de reproducirla.
        self.out_agc = core.Agc(target=0.5, max_gain=6.0, release=1.0)
        self.socket = core.TranslateSocket(key, language, voice=voice, on_audio=self._translated,
                                           on_text=self._text, on_dropped=self._dropped, log=log)
        self.socket.connect()

    def _translated(self, samples):
        self.ring.write(self.out_agc.apply(samples))

    def _text(self, t):
        self.chars += len(t)

    def _dropped(self, reason):
        self.fail(reason)

    def fail(self, reason):
        if self.running and self.problem is None:
            self.problem = reason
            log(f"{self.name}: {reason}")
            threading.Thread(target=self._auto_stop, args=(reason,), daemon=True).start()

    def _auto_stop(self, reason):
        self.stop()
        self.on_stop(reason)

    def _spawn(self, target, name):
        t = threading.Thread(target=self._guard, args=(target,), name=name, daemon=True)
        self._threads.append(t)
        t.start()

    def _guard(self, target):
        try:
            _com()
            target()
        except Exception as e:
            self.fail(f"falló el audio ({type(e).__name__}: {str(e)[:160]})")

    def stop(self):
        if not self.running:
            return
        self.running = False
        self._stopped.set()
        for t in self._threads:
            if t is not threading.current_thread():
                t.join(timeout=2)
        if self.socket:
            self.socket.close()
        self._cleanup()
        extra = f", ganancia de salida x{self.out_agc.gain:.1f}" if getattr(self, "out_agc", None) else ""
        if getattr(self, "mic_agc", None):
            extra += f", ganancia del micrófono x{self.mic_agc.gain:.1f}"
        log(f"{self.name} detenida a los {int(time.time() - self.started)} s, {self.chars} letras traducidas{extra}")

    def _cleanup(self):
        pass


class VoiceOut(_Session):
    """Los demás te escuchan traducido: micrófono real -> traducción -> micrófono virtual."""

    name = "Traducción de mi voz"

    def start(self):
        out = virtual_mic()
        if out is None:
            raise core.TranslateError("Falta el micrófono virtual (VB-CABLE). Instálalo desde el menú.")
        mic = real_mic()
        archivo = os.environ.get("INTERPRETE_VOZ_ARCHIVO")
        if mic is None and not archivo:
            raise core.TranslateError("No encontré tu micrófono. Revisa Configuración > Sistema > Sonido > Entrada.")
        self.mic, self.out = mic, out
        self.mic_name = mic.name if mic else "archivo"
        self.out_name = out.name
        choice = Config.get("voz_traduccion")
        self._open_socket(Config.get("mi_voz_a"), core.VOICES.get(choice))
        v = float(Config.get("mi_voz_original") or 0)
        self.own = core.Ring(cushion=0.04, limit=0.4)
        self.own_gain = core.Smooth(v, v * 0.5)
        self.chunker = core.Chunker(self.socket.append)
        self.mic_agc = core.Agc()
        self.running = True
        self.started = time.time()
        self._spawn(self._play, "interprete.microfono-virtual")
        self._spawn(self._capture_file if archivo else self._capture, "interprete.microfono")
        log(f"{self.name} activa ({Config.get('mi_voz_a')}): {self.mic_name} -> {out.name}; voz {choice}; "
            f"mi voz original de fondo al {int(v * 100)} %")

    def set_own_voice(self, v):
        self.own_gain.idle, self.own_gain.ducked = v, v * 0.5

    def _ingest(self, samples):
        self.own.write(samples)
        # Muchos micrófonos de Windows entregan la voz baja, y el modelo contesta igual de bajo.
        self.chunker.feed(self.mic_agc.apply(samples))

    def _capture(self):
        with self.mic.recorder(samplerate=core.RATE, channels=1, blocksize=DEV_BLOCK) as rec:
            while self.running:
                data = rec.record(numframes=BLOCK * 2)
                self._ingest(np.asarray(data, dtype=np.float32).reshape(-1))

    def _capture_file(self):
        """Prueba: un archivo WAV en vez del micrófono, a ritmo de tiempo real."""
        from .prueba import leer_wav
        audio = leer_wav(os.environ["INTERPRETE_VOZ_ARCHIVO"])
        t0 = time.monotonic() + 0.5
        i = 0
        while self.running:
            wait = t0 + i / core.RATE - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            block = audio[i:i + BLOCK * 2]
            if len(block) < BLOCK * 2:
                block = np.concatenate([block, np.zeros(BLOCK * 2 - len(block), dtype=np.float32)])
            self._ingest(block)
            i += BLOCK * 2

    def _play(self):
        with self.out.player(samplerate=core.RATE, channels=1, blocksize=DEV_BLOCK) as p:
            while self.running:
                block = self.ring.read(BLOCK)
                # Encima de la traducción va tu voz original, bajita.
                block = block + self.own_gain.apply(self.own.read(BLOCK), self.ring.speaking)
                p.play(np.clip(block, -1, 1))


class Listen(_Session):
    """Tú escuchas traducido: lo que suena en el computador -> traducción -> tus audífonos."""

    name = "Traducción de lo que escucho"

    def start(self):
        spk = real_speaker()
        if spk is None:
            raise core.TranslateError("No encontré tus audífonos o parlantes.")
        self.spk = spk
        self._open_socket(Config.get("traducir_a"))
        self.agc = core.Agc()
        self.chunker = core.Chunker(self.socket.append)
        self.helper = None
        self.duck = None
        self.running = True
        self.started = time.time()
        modo = self._start_capture()
        self._spawn(self._play, "interprete.audifonos")
        # El original se baja en los dos modos de captura: en el simple lo capturado llega más bajo, y lo
        # compensa el nivelador de entrada.
        if sys.platform == "win32":
            from . import volumen
            self.duck = volumen.Ducker(float(Config.get("volumen_original") or 0))
            self.duck.start()
        log(f"{self.name} activa ({Config.get('traducir_a')}): captura {modo} -> {spk.name}")

    # Captura -----------------------------------------------------------------------------------------------

    def _start_capture(self):
        """Devuelve el modo usado. `exclusive` dice si la captura deja fuera el audio de esta app."""
        archivo = os.environ.get("INTERPRETE_ESCUCHA_ARCHIVO")
        self.exclusive = False
        if archivo:
            self._spawn(lambda: self._capture_file(archivo), "interprete.captura")
            return "archivo"
        exe = helper_path()
        if exe:
            try:
                self.helper = subprocess.Popen([exe, str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                first = self.helper.stdout.read(BLOCK * 4)       # 20 ms de float32: confirma que arrancó
                if len(first) == BLOCK * 4:
                    self.exclusive = True
                    self._spawn(self._capture_helper, "interprete.captura")
                    return "del sistema sin esta app"
                err = self.helper.stderr.read().decode("utf-8", "replace")[:200]
                log(f"El ayudante de captura no arrancó: {err.strip()}")
            except Exception as e:
                log(f"El ayudante de captura no arrancó: {e}")
            self.helper = None
        # Respaldo: todo lo que suena, incluida la traducción. Para que no se traduzca a sí misma, mientras la
        # traducción habla no se manda nada al modelo (se pierde lo que digan encima).
        self._spawn(self._capture_loopback, "interprete.captura")
        return "de todo el sistema (modo simple)"

    def _send(self, samples):
        self.chunker.feed(self.agc.apply(samples))

    def _capture_helper(self):
        out = self.helper.stdout
        size = BLOCK * 4
        while self.running:
            data = out.read(size)
            if len(data) < size:
                if self.running:
                    self.fail("se cortó la captura del audio del sistema")
                return
            self._send(np.frombuffer(data, dtype="<f4"))

    def _capture_loopback(self):
        sc = _sc()
        mic = sc.get_microphone(self.spk.id, include_loopback=True)
        with mic.recorder(samplerate=core.RATE, channels=1, blocksize=DEV_BLOCK) as rec:
            while self.running:
                data = np.asarray(rec.record(numframes=BLOCK * 2), dtype=np.float32).reshape(-1)
                if self.ring.speaking or self.ring.seconds > 0.05:
                    data = np.zeros_like(data)
                self._send(data)

    def _capture_file(self, path):
        from .prueba import leer_wav
        audio = leer_wav(path)
        t0 = time.monotonic() + 0.5
        i = 0
        while self.running:
            wait = t0 + i / core.RATE - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            block = audio[i:i + BLOCK * 2]
            if len(block) < BLOCK * 2:
                block = np.concatenate([block, np.zeros(BLOCK * 2 - len(block), dtype=np.float32)])
            self._send(block)
            i += BLOCK * 2

    # Reproducción ------------------------------------------------------------------------------------------

    def _play(self):
        with self.spk.player(samplerate=core.RATE, channels=1, blocksize=DEV_BLOCK) as p:
            while self.running:
                block = self.ring.read(BLOCK)
                if self.duck:
                    self.duck.speaking = self.ring.speaking
                p.play(block)

    def set_original_volume(self, v):
        if self.duck:
            self.duck.set_level(v)

    def _cleanup(self):
        if self.duck:
            self.duck.stop()
            self.duck = None
        if self.helper:
            try:
                self.helper.kill()
            except Exception:
                pass
            self.helper = None


def helper_path():
    """`captura.exe` va junto al programa. Solo existe en Windows."""
    if sys.platform != "win32":
        return None
    base = getattr(sys, "_MEIPASS", None) or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for p in (os.path.join(base, "captura.exe"), os.path.join(base, "helper", "captura.exe")):
        if os.path.exists(p):
            return p
    return None
