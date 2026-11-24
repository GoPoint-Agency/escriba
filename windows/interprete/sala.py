"""Sala de equipo: las apps de Intérprete de una misma reunión se avisan entre sí.

Cuando un compañero habla con Intérprete, a la llamada sale su voz y la traducción. Sin sala, el Intérprete de
los demás compañeros toma esa traducción por alguien que habla otro idioma y la traduce de vuelta. Con sala,
cada app avisa «esto lo estoy emitiendo yo» (y las palabras de lo que emite) y las otras no lo traducen.
Por el servidor viajan solo esos avisos; el audio no.
"""
import asyncio
import json
import os
import secrets
import threading
import time

from . import core

SERVIDOR = os.environ.get("INTERPRETE_SALA_URL", "wss://sala.31-97-248-157.sslip.io")
LETRAS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"      # sin 0, O, 1 ni I: se dictan por teléfono sin confundirse


def nuevo_codigo():
    return "".join(secrets.choice(LETRAS) for _ in range(8))


def limpiar_codigo(texto):
    """Lo que la persona pega o escribe -> código válido, o cadena vacía."""
    c = "".join(ch for ch in (texto or "").upper() if ch.isalnum())
    return c if 6 <= len(c) <= 12 else ""


def bonito(codigo):
    return f"{codigo[:4]}-{codigo[4:]}" if len(codigo) == 8 else codigo


class Compas:
    """Lo que se sabe de los compañeros de la sala. Sin red: se prueba sola y la usa EchoGuard."""

    COLA = 1.2          # segundos que se sigue contando la voz de un compañero después de que avisa que calló
    VIGENCIA = 4.0      # un «estoy hablando» sin renovar caduca (por si se pierde el aviso de que calló)
    MEMORIA = 14.0      # cuánto se recuerdan las palabras que emitió un compañero

    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._lock = threading.Lock()
        self._on = {}           # compañero -> último «estoy hablando»
        self._off = -1e9        # último «callé»
        self._words = []        # (momento, palabra) de lo que los compañeros emiten traducido
        self.conectados = 0

    def voz(self, quien, on):
        with self._lock:
            now = self._clock()
            if on:
                self._on[quien] = now
            elif self._on.pop(quien, None) is not None:
                self._off = now

    def texto(self, palabras):
        with self._lock:
            now = self._clock()
            self._words += [(now, w) for w in palabras if isinstance(w, str)][:40]
            self._words = [(t, w) for t, w in self._words if now - t < self.MEMORIA][-200:]

    def vaciar(self):
        with self._lock:
            self._on, self._words, self._off = {}, [], -1e9

    def hablando(self):
        """Un compañero está emitiendo su traducción ahora (o recién terminó)."""
        with self._lock:
            now = self._clock()
            return any(now - t < self.VIGENCIA for t in self._on.values()) or now - self._off < self.COLA

    def palabras(self):
        with self._lock:
            now = self._clock()
            return {w for t, w in self._words if now - t < self.MEMORIA}


class Sala:
    """Conexión con la sala: un hilo que se reconecta solo. Segura para llamar desde los hilos de audio."""

    def __init__(self, codigo, log=print, url=None):
        self.codigo = codigo
        self.compas = Compas()
        self._log = log
        self._url = (url or SERVIDOR).rstrip("/") + "/s/" + codigo
        self._loop = None
        self._queue = None
        self._running = True
        self._task = None
        self._speaking = False
        self._last_voz = 0.0
        self._tail = ""
        self.conectada = False
        self._thread = threading.Thread(target=self._run, name="interprete.sala", daemon=True)
        self._thread.start()

    # Lo que esta app emite ----------------------------------------------------------------------------------

    def emitiendo(self, on):
        """Se llama a menudo desde el hilo de audio: avisa al cambiar y renueva el aviso mientras dure."""
        now = time.monotonic()
        if on != self._speaking or (on and now - self._last_voz > 1.5):
            self._speaking, self._last_voz = on, now
            self._send({"t": "voz", "on": bool(on)})

    def dije(self, delta):
        """Texto de la traducción que esta app está emitiendo, a trozos."""
        text = self._tail + delta
        cut = len(text)
        while cut > 0 and text[cut - 1].isalnum():
            cut -= 1
        self._tail = text[cut:][-40:]
        words = [w for w in core._norm(text[:cut]) if len(w) >= 4 or ord(w[0]) >= 0x2E80]
        if words:
            self._send({"t": "txt", "w": words[:20]})

    def _send(self, msg):
        loop, q = self._loop, self._queue
        if loop and q and self.conectada:
            try:
                loop.call_soon_threadsafe(q.put_nowait, json.dumps(msg, separators=(",", ":")))
            except RuntimeError:
                pass

    # Conexión -----------------------------------------------------------------------------------------------

    def _run(self):
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        self._task = self._loop.create_task(self._main())
        try:
            self._loop.run_until_complete(self._task)
        except asyncio.CancelledError:
            pass
        except Exception as e:
            if self._running:
                self._log(f"Sala: se detuvo ({type(e).__name__}: {str(e)[:120]})")
        finally:
            self.conectada = False
            try:
                self._loop.run_until_complete(self._loop.shutdown_asyncgens())
                self._loop.close()
            except Exception:
                pass

    async def _main(self):
        from websockets.asyncio.client import connect
        self._queue = asyncio.Queue()
        wait = 1.0
        while self._running:
            try:
                async with connect(self._url, open_timeout=10, ping_interval=20, ping_timeout=20,
                                              max_size=4096) as ws:
                    self.conectada = True
                    wait = 1.0
                    self._log(f"Sala {bonito(self.codigo)}: conectada")
                    _cambio()
                    sender = asyncio.ensure_future(self._pump(ws))
                    try:
                        async for raw in ws:
                            self._recv(raw)
                    finally:
                        sender.cancel()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                if self._running:
                    self._log(f"Sala: sin conexión ({type(e).__name__}), reintento en {wait:.0f} s")
            self.conectada = False
            self.compas.conectados = 0
            self.compas.vaciar()
            _cambio()
            if self._running:
                await asyncio.sleep(wait)
                wait = min(wait * 2, 20.0)

    async def _pump(self, ws):
        while True:
            await ws.send(await self._queue.get())

    def _recv(self, raw):
        try:
            j = json.loads(raw)
        except (ValueError, TypeError):
            return
        if not isinstance(j, dict):
            return
        t = j.get("t")
        if t == "sala":
            n = int(j.get("n") or 0)
            if n != self.compas.conectados:
                self._log(f"Sala {bonito(self.codigo)}: {n} conectados")
            self.compas.conectados = n
            _cambio()
        elif t == "voz":
            self.compas.voz(j.get("de"), bool(j.get("on")))
        elif t == "txt" and isinstance(j.get("w"), list):
            self.compas.texto(j["w"])

    def close(self):
        self._running = False
        loop = self._loop
        task = getattr(self, "_task", None)
        if loop and task and loop.is_running():
            try:
                loop.call_soon_threadsafe(task.cancel)      # cancela con orden: el servidor ve la salida al instante
            except RuntimeError:
                pass


_actual = None
_lock = threading.Lock()
al_cambiar = None       # la app pone aquí una función para refrescar el menú cuando cambia la sala


def _cambio():
    f = al_cambiar
    if f:
        try:
            f()
        except Exception:
            pass


def actual():
    return _actual


def entrar(codigo, log=print):
    """Deja a la app en esa sala (y sale de la anterior). Código vacío = salir."""
    global _actual
    with _lock:
        if _actual and _actual.codigo == codigo:
            return _actual
        if _actual:
            _actual.close()
            _actual = None
        if codigo:
            _actual = Sala(codigo, log=log)
        return _actual
