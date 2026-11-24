"""Núcleo de Intérprete para Windows: la conexión con OpenAI y las colas de audio.

No toca dispositivos de audio: recibe y entrega audio mono a 24 kHz en float32 (numpy). Por eso se puede probar
en cualquier sistema, con archivos.

Dos motores, igual que la app del Mac (ver docs/TRASPASO-INTERPRETE.md):
- automático: `gpt-realtime-translate`. Lo más rápido. La voz la elige el modelo (imita la que escucha).
- voz fija: `gpt-realtime-2.1` usado como intérprete, con voz de hombre o de mujer. Parte cerca de 1,5 s más tarde.
"""
import base64
import json
import os
import threading
import time
import unicodedata

import numpy as np
from websockets.sync.client import connect

RATE = 24000
CHUNK = RATE // 5                      # 200 ms
MODEL = "gpt-realtime-translate"
AGENT_MODEL = os.environ.get("INTERPRETE_MODELO_VOZ", "gpt-realtime-2.1")
VOICES = {"hombre": "cedar", "mujer": "marin"}
LANGUAGES = {"en": "English", "es": "Spanish", "pt": "Portuguese", "de": "German", "fr": "French", "it": "Italian",
             "zh": "Mandarin Chinese", "ko": "Korean", "ja": "Japanese"}


class TranslateError(Exception):
    pass


def _instructions(language):
    name = LANGUAGES.get(language, language)
    return (
        f"You are a simultaneous interpreter on a live call. Every time the speaker finishes a sentence, say it in {name}.\n"
        "Rules: output ONLY the translation of what was said, nothing else. Keep the same grammatical person the speaker "
        'used: "I" stays "I" and "you" stays "you" (a question addressed to "you" is still addressed to "you"). '
        "Keep names, numbers and tone.\n"
        "Never answer questions, never greet, never comment, never explain, never refuse: if the speaker asks a question, "
        f"translate the question. If the speaker already talks in {name}, repeat it as is. "
        "If you hear nothing intelligible, stay silent.\nSpeak at a brisk, natural pace."
    )


class TranslateSocket:
    """Se le manda audio sin parar (también el silencio) y devuelve voz y texto traducidos por los callbacks."""

    def __init__(self, api_key, language, voice=None, on_audio=None, on_text=None, on_dropped=None, log=print,
                 guard=None):
        self.api_key = api_key
        self.language = language
        self.voice = voice                      # None = motor automático
        self.on_audio = on_audio or (lambda a: None)
        self.on_text = on_text or (lambda t: None)
        self.on_dropped = on_dropped or (lambda m: None)
        self.log = log
        self.guard = guard                      # EchoGuard: no repetir lo que ya viene en el idioma de destino
        self.agent = voice is not None
        self._ws = None
        self._send_lock = threading.Lock()
        self._closing = False
        self._updated = threading.Event()
        self._closed = threading.Event()
        self._error = None
        self._items = []
        self._current = None
        self._state = threading.Lock()

    def connect(self, timeout=15):
        url = (f"wss://api.openai.com/v1/realtime?model={AGENT_MODEL}" if self.agent
               else f"wss://api.openai.com/v1/realtime/translations?model={MODEL}")
        try:
            self._ws = connect(url, additional_headers={"Authorization": f"Bearer {self.api_key}"},
                               open_timeout=timeout, max_size=None)
        except Exception as e:
            raise TranslateError(_friendly(e)) from None
        first = json.loads(self._ws.recv(timeout=timeout))
        if first.get("type") == "error":
            raise TranslateError("OpenAI rechazó la conexión: " + str(first.get("error", {}).get("message", ""))[:200])
        threading.Thread(target=self._listen, name="interprete.socket", daemon=True).start()
        if self.agent:
            session = {
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": _instructions(self.language),
                "audio": {
                    "input": {"format": {"type": "audio/pcm", "rate": RATE},
                              "turn_detection": {"type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300,
                                                 "silence_duration_ms": 250, "create_response": False,
                                                 "interrupt_response": False}},
                    "output": {"format": {"type": "audio/pcm", "rate": RATE}, "voice": self.voice, "speed": 1.15},
                },
            }
            self._send({"type": "session.update", "session": session})
            # Sin esta confirmación no se manda audio: si OpenAI rechaza los ajustes, el modelo quedaría sin la orden
            # de traducir y contestaría como asistente.
            if not self._updated.wait(10) or self._error:
                err = self._error or "OpenAI no confirmó la voz elegida."
                self.close()
                raise TranslateError(err)
        else:
            audio = {"output": {"language": self.language}}
            if self.guard:
                audio["input"] = {"transcription": {"model": "gpt-realtime-whisper"}}
            self._send({"type": "session.update", "session": {"audio": audio}})

    def append(self, samples):
        """Audio mono float32 a 24 kHz. Conviene mandar trozos de 200 ms."""
        pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
        kind = "input_audio_buffer.append" if self.agent else "session.input_audio_buffer.append"
        self._send({"type": kind, "audio": base64.b64encode(pcm).decode()})

    def _send(self, obj):
        ws = self._ws
        if ws is None:
            return
        try:
            with self._send_lock:
                ws.send(json.dumps(obj))
        except Exception:
            pass

    def _listen(self):
        problem = None
        try:
            for raw in self._ws:
                self._handle(json.loads(raw))
        except Exception as e:
            problem = _friendly(e)
        self._closed.set()
        self._updated.set()
        if not self._closing:
            self.on_dropped(problem or "OpenAI cerró la traducción.")

    def _handle(self, j):
        t = j.get("type", "")
        if t in ("session.output_audio.delta", "response.output_audio.delta"):
            d = base64.b64decode(j.get("delta", ""))
            if len(d) >= 2:
                a = np.frombuffer(d[:len(d) // 2 * 2], dtype="<i2").astype(np.float32) / 32768
                if self.guard:
                    a = self.guard.audio(a)
                if a is not None:
                    self.on_audio(a)
        elif t in ("session.output_transcript.delta", "response.output_audio_transcript.delta"):
            if self.guard:
                self.guard.translated(j.get("delta", ""))
            self.on_text(j.get("delta", ""))
        elif t == "session.input_transcript.delta":
            if self.guard:
                self.guard.source(j.get("delta", ""))
        elif t == "session.updated":
            self._updated.set()
        elif t == "input_audio_buffer.committed" and self.agent:
            # Con voz fija cada frase se traduce por separado y en orden: una respuesta por frase, que solo ve esa frase.
            with self._state:
                self._items.append(j.get("item_id"))
            self._next_phrase()
        elif t == "response.done" and self.agent:
            with self._state:
                done, self._current = self._current, None
            if done:
                self._send({"type": "conversation.item.delete", "item_id": done})
            self._next_phrase()
        elif t == "session.closed":
            self._closed.set()
        elif t == "error":
            msg = str(j.get("error", {}).get("message", j))[:300]
            if self.agent and self._updated.is_set() and self._current is not None:
                self.log("Traducción con voz fija, frase sin traducir: " + msg[:160])
                with self._state:
                    self._current = None
                self._next_phrase()
                return
            self._error = "OpenAI rechazó la traducción: " + msg[:200]
            self.log("Traducción, error de OpenAI: " + msg)
            self._updated.set()

    def _next_phrase(self):
        with self._state:
            if self._current is not None or not self._items:
                return
            item = self._items.pop(0)
            self._current = item
        self._send({"type": "response.create",
                    "response": {"conversation": "none", "output_modalities": ["audio"],
                                 "input": [{"type": "item_reference", "id": item}]}})

    def close(self):
        """Cierra con aviso para que OpenAI entregue lo último que estaba traduciendo."""
        self._closing = True
        if self._ws is None:
            return
        if not self.agent:
            self._send({"type": "session.close"})
            self._closed.wait(3)
        try:
            self._ws.close()
        except Exception:
            pass
        self._ws = None


def _friendly(e):
    s = str(e)
    if "401" in s:
        return "La clave de OpenAI no es válida."
    if "429" in s:
        return "OpenAI dice que la cuenta no tiene saldo o pasó su límite."
    if "timed out" in s or "getaddrinfo" in s or "Network" in s:
        return "No pude conectarme con OpenAI. Revisa internet."
    return "Se cortó la conexión con OpenAI: " + s[:160]


def _norm(text):
    """Texto a palabras comparables: minúsculas, sin tildes ni signos. Cada carácter chino, japonés o coreano va solo."""
    out, cur = [], []
    for ch in unicodedata.normalize("NFD", text.lower()):
        if unicodedata.combining(ch):
            continue
        if ch.isalnum():
            if ord(ch) >= 0x2E80:
                if cur:
                    out.append("".join(cur)); cur = []
                out.append(ch)
            else:
                cur.append(ch)
        elif cur:
            out.append("".join(cur)); cur = []
    if cur:
        out.append("".join(cur))
    return out


class EchoGuard:
    """Evita que el intérprete repita lo que ya viene en el idioma de quien escucha.

    El modelo de traducción, cuando alguien habla en el idioma de destino, lo repite con otras palabras. Aquí se
    compara el texto de lo que el modelo va a decir con el texto de lo que se escuchó (los dos llegan antes que la
    voz): si son casi las mismas palabras, es una repetición y esa voz no se reproduce. No depende del idioma.
    """
    HOLD, PASS, ECHO = "espera", "pasa", "repite"

    def __init__(self, clock=time.monotonic, compas=None, same_language=True):
        self._clock = clock
        self.compas = compas            # sala de equipo: lo que emiten los compañeros no se traduce de vuelta
        self._same = same_language      # falso = solo se filtra lo de los compañeros
        self.skipped_team = 0.0         # segundos de traducción de un compañero que no se tradujeron de vuelta
        self._team_until = -1e9
        self._src = []                  # (momento, palabra) de lo escuchado
        self._src_tail = ""             # palabra de lo escuchado que aún puede seguir creciendo
        self._out = []                  # palabras de lo que dice el modelo en esta intervención
        self._out_tail = ""
        self._last_out = -1e9
        self._last_src = -1e9
        self._src_run = -1e9            # cuándo empezó la racha actual de habla escuchada
        self.state = self.PASS
        self._pending = []
        self._hold_since = None
        self.skipped = 0.0              # segundos de voz repetida que no se reprodujeron

    # Texto ------------------------------------------------------------------------------------------------

    def _words(self, tail, delta):
        """Une los trozos de texto en palabras. Devuelve (palabras completas, resto que puede seguir creciendo)."""
        text = tail + delta
        if not text or not text[-1].isalnum():
            return _norm(text), ""
        cut = len(text)
        while cut > 0 and (text[cut - 1].isalnum() or unicodedata.combining(text[cut - 1])):
            cut -= 1
        return _norm(text[:cut]), text[cut:]

    def source(self, delta):
        now = self._clock()
        if now - self._last_src > 1.5:
            self._src_run = now
        self._last_src = now
        done, self._src_tail = self._words(self._src_tail, delta)
        self._src += [(now, w) for w in done]
        self._src = [(t, w) for t, w in self._src if now - t < 15][-80:]

    def translated(self, delta):
        now = self._clock()
        if now - self._last_out > 1.5:                # intervención nueva: se decide de nuevo
            self._out, self._out_tail = [], ""
            self.state = self.HOLD
            self._hold_since = None
        self._last_out = now
        done, self._out_tail = self._words(self._out_tail, delta)
        self._out = (self._out + done)[-12:]
        self._decide()

    def _decide(self):
        """Compara las palabras con contenido (4 letras o más) de lo que dice el modelo con lo recién escuchado."""
        now = self._clock()
        heard = {w for t, w in self._src if now - t < 6.0}
        tail = _norm(self._src_tail)
        partial = tail[-1] if tail else ""

        def strong(w):
            return len(w) >= 4 or ord(w[0]) >= 0x2E80

        words = [w for w in self._out if strong(w)][-4:]
        hits = sum(1 for w in words if w in heard or (partial and partial.startswith(w)))
        n = len(words)
        cur = [w for w in _norm(self._out_tail) if strong(w)]
        if cur:                                       # la palabra que el modelo está diciendo cuenta si ya se reconoce
            n += 1
            hits += 1 if any(h.startswith(cur[-1]) for h in heard) or partial.startswith(cur[-1]) else 0
        if n == 0:
            return
        frac = hits / n
        if not self._same:                            # el filtro de «ya viene en tu idioma» está apagado
            self.state = self.PASS
            return
        if self.state == self.HOLD:
            if hits == 0:
                self.state = self.PASS                # la primera palabra ya es distinta: es traducción, sin esperar
            elif n >= 2:
                self.state = self.ECHO if frac >= 0.6 else self.PASS
        elif self.state == self.PASS and n >= 3 and frac >= 0.75:
            self.state = self.ECHO
        elif self.state == self.ECHO and n >= 3 and frac <= 0.34:
            self.state = self.PASS

    # Audio ------------------------------------------------------------------------------------------------

    def from_team(self):
        """Lo que se está escuchando es la traducción que emite un compañero de la sala."""
        c = self.compas
        if c is None:
            return False
        now = self._clock()
        if c.hablando():
            self._team_until = now + 0.8
            return True
        # Por el texto: lo recién escuchado coincide con lo que un compañero avisó que estaba emitiendo. Cubre la
        # demora de la llamada y del modelo, que siguen entregando esa voz después de que el compañero calló.
        heard = [w for t, w in self._src if now - t < 6.0 and (len(w) >= 4 or ord(w[0]) >= 0x2E80)][-8:]
        if len(heard) >= 2:
            said = c.palabras()
            if said and sum(1 for w in heard if w in said) / len(heard) >= 0.5:
                self._team_until = now + 0.8
                return True
        return now < self._team_until

    def audio(self, samples):
        """Devuelve lo que hay que reproducir (puede ser nada)."""
        now = self._clock()
        if self.from_team():
            self.skipped_team += (sum(len(p) for p in self._pending) + len(samples)) / RATE
            self._pending = []
            return None
        if self.state == self.HOLD:
            if self._hold_since is None:
                self._hold_since = now
            if now - self._hold_since < 0.7:
                self._pending.append(samples)
                return None
            self.state = self.PASS                    # sin texto a tiempo: ante la duda, se traduce
        if self.state == self.ECHO:
            self.skipped += (sum(len(p) for p in self._pending) + len(samples)) / RATE
            self._pending = []
            return None
        if self._pending:
            samples = np.concatenate(self._pending + [samples])
            self._pending = []
        return samples

    @property
    def same_language(self):
        """Cierto mientras quien habla ya lo hace en el idioma de quien escucha: el original debe oírse normal."""
        now = self._clock()
        if self.compas is not None and self.from_team():
            return True
        if not self._same:
            return False
        if self.state == self.ECHO and now - self._last_out < 2.5:
            return True
        # El modelo a veces ni siquiera repite: se oye hablar hace rato y no dice nada.
        return now - self._last_src < 1.5 and now - self._src_run > 2.5 and now - self._last_out > 3.0


class Ring:
    """Cola de audio para reproducir: se llena a trozos y se vacía al ritmo del dispositivo."""

    def __init__(self, cushion=0.2, limit=20.0):
        self._buf = np.zeros(0, dtype=np.float32)
        self._lock = threading.Lock()
        self._cushion = int(RATE * cushion)
        self._limit = int(RATE * limit)
        self._primed = False
        self.last_loud = 0.0            # cuándo salió sonido por última vez

    def write(self, samples):
        with self._lock:
            self._buf = np.concatenate([self._buf, np.asarray(samples, dtype=np.float32)])
            if len(self._buf) > self._limit:          # nunca debería: es un seguro contra atrasos sin fin
                self._buf = self._buf[-self._cushion:]

    def read(self, n):
        """Siempre devuelve n muestras; si no hay audio, silencio."""
        out = np.zeros(n, dtype=np.float32)
        with self._lock:
            have = len(self._buf)
            if not self._primed:
                self._primed = have >= self._cushion
            if self._primed:
                k = min(n, have)
                out[:k] = self._buf[:k]
                self._buf = self._buf[k:]
                if k < n:
                    self._primed = False
        if n and float(np.max(np.abs(out))) > 0.01:
            self.last_loud = time.monotonic()
        return out

    @property
    def seconds(self):
        with self._lock:
            return len(self._buf) / RATE

    @property
    def speaking(self):
        return time.monotonic() - self.last_loud < 0.25

    def clear(self):
        with self._lock:
            self._buf = np.zeros(0, dtype=np.float32)
            self._primed = False


class Chunker:
    """Junta el audio que llega en trozos de cualquier tamaño y lo entrega en trozos exactos de 200 ms."""

    def __init__(self, sink):
        self._sink = sink
        self._buf = np.zeros(0, dtype=np.float32)
        self.peak = 0.0
        self.last_speech = 0.0

    def feed(self, samples):
        s = np.asarray(samples, dtype=np.float32)
        if len(s):
            p = float(np.max(np.abs(s)))
            self.peak = max(self.peak, p)
            if p > 0.02:
                self.last_speech = time.monotonic()
        self._buf = np.concatenate([self._buf, s])
        while len(self._buf) >= CHUNK:
            self._sink(self._buf[:CHUNK])
            self._buf = self._buf[CHUNK:]


class Smooth:
    """Volumen con transiciones suaves (baja rápido, sube lento), para la voz original de fondo."""

    def __init__(self, idle, ducked):
        self.idle, self.ducked = idle, ducked
        self._gain = idle

    def apply(self, samples, ducked):
        target = self.ducked if ducked else self.idle
        n = len(samples)
        if n == 0:
            return samples
        tau = 0.04 if target < self._gain else 0.30
        k = 1 - np.exp(-np.arange(1, n + 1) / (tau * RATE))
        g = self._gain + (target - self._gain) * k
        self._gain = float(g[-1])
        return samples * g.astype(np.float32)


class Agc:
    """Nivela lo que se captura: si el sistema tiene el volumen bajo, el modelo igual escucha bien."""

    def __init__(self, target=0.12, max_gain=12.0, release=2.0):
        self.target, self.max_gain, self.release = target, max_gain, release
        self._level = target
        self.gain = 1.0

    def apply(self, samples):
        if len(samples) == 0:
            return samples
        p = float(np.max(np.abs(samples)))
        if p > 0.004:                               # solo se mide cuando hay algo sonando
            tau = 0.05 if p > self._level else self.release          # sube al instante, baja en un par de segundos
            self._level += (p - self._level) * (1 - float(np.exp(-len(samples) / (tau * RATE))))
        self.gain = float(min(self.max_gain, max(1.0, self.target / max(self._level, 1e-4))))
        return np.clip(samples * self.gain, -1, 1)


def resample(samples, src, dst=RATE):
    """Cambio de frecuencia por interpolación lineal. Suficiente para voz."""
    if src == dst or len(samples) == 0:
        return np.asarray(samples, dtype=np.float32)
    n = int(round(len(samples) * dst / src))
    x = np.linspace(0, len(samples) - 1, n)
    return np.interp(x, np.arange(len(samples)), samples).astype(np.float32)
