"""Pruebas con archivos, sin dispositivos de audio. Sirven en cualquier sistema.

    python -m interprete.prueba traducir <entrada.wav> <salida.wav> <idioma> [hombre|mujer]

La clave de OpenAI se toma de OPENAI_API_KEY o del archivo de ajustes.
"""
import sys
import time
import wave

import numpy as np

from . import core
from .config import Config


def leer_wav(path):
    w = wave.open(path)
    n, sr, ch = w.getnframes(), w.getframerate(), w.getnchannels()
    a = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float32) / 32768
    w.close()
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    return core.resample(a, sr)


def escribir_wav(path, samples):
    w = wave.open(path, "wb")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(core.RATE)
    w.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())
    w.close()


def traducir(entrada, salida, idioma, voz=None):
    """Manda el archivo a ritmo de tiempo real y guarda lo que se habría escuchado, en la misma línea de tiempo."""
    audio = leer_wav(entrada)
    ring = core.Ring()
    texto = []
    caidas = []
    s = core.TranslateSocket(Config.api_key(), idioma, voice=core.VOICES.get(voz), on_audio=ring.write,
                             on_text=texto.append, on_dropped=caidas.append)
    t0 = time.monotonic()
    s.connect()
    print(f"Conectado en {time.monotonic() - t0:.1f} s ({'voz ' + voz if voz else 'voz automática'})")
    oido = []
    total = len(audio) + core.RATE * 6            # seis segundos de silencio al final para oír lo último
    inicio = time.monotonic()
    i = 0
    while i < total and not caidas:
        trozo = audio[i:i + core.CHUNK]
        if len(trozo) < core.CHUNK:
            trozo = np.concatenate([trozo, np.zeros(core.CHUNK - len(trozo), dtype=np.float32)])
        s.append(trozo)
        oido.append(ring.read(core.CHUNK))
        i += core.CHUNK
        espera = inicio + i / core.RATE - time.monotonic()
        if espera > 0:
            time.sleep(espera)
    s.close()
    if caidas:
        print("Se cortó:", caidas[0])
    out = np.concatenate(oido) if oido else np.zeros(0, dtype=np.float32)
    escribir_wav(salida, out)
    con_voz = float(np.sum(np.abs(out) > 0.02)) / core.RATE
    print("Traducción:", "".join(texto))
    print(f"Guardado {salida}: {len(out) / core.RATE:.1f} s, {con_voz:.1f} s con voz")
    return "".join(texto)


def sesion(cual, segundos):
    """Corre un sentido completo con dispositivos reales durante unos segundos (ver variables INTERPRETE_*)."""
    from . import audio
    s = audio.VoiceOut() if cual == "voz" else audio.Listen()
    s.on_stop = lambda motivo: print("Se detuvo sola:", motivo)
    s.start()
    time.sleep(segundos)
    s.stop()


def main():
    global print
    if sys.stdout is None:
        from .config import log as print      # noqa: en el .exe sin consola, lo impreso va al registro
    a = sys.argv[1:]
    if len(a) >= 4 and a[0] == "traducir":
        traducir(a[1], a[2], a[3], a[4] if len(a) > 4 else None)
    elif len(a) >= 2 and a[0] in ("voz", "escucha"):
        sesion(a[0], float(a[1]))
    elif a and a[0] == "dispositivos":
        from . import audio
        print("Entradas:", [m.name for m in audio.microphones()])
        print("Salidas:", [s.name for s in audio.speakers()])
        print("Micrófono real:", getattr(audio.real_mic(), "name", None))
        print("Micrófono virtual:", getattr(audio.virtual_mic(), "name", None))
        print("Audífonos:", getattr(audio.real_speaker(), "name", None))
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
