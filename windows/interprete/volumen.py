"""Baja el volumen de las demás aplicaciones mientras suena la traducción (solo Windows).

Así la llamada original queda de fondo, bajita, y la traducción se entiende. Al terminar se devuelve cada
aplicación al volumen que tenía. Los volúmenes originales se guardan en los ajustes por si la app se cierra mal.
"""
import os
import threading
import time

from .config import Config, log


def _sessions():
    from pycaw.pycaw import AudioUtilities
    out = []
    for s in AudioUtilities.GetAllSessions():
        try:
            pid = s.ProcessId
            if pid and pid != os.getpid():
                out.append((pid, s.SimpleAudioVolume))
        except Exception:
            pass
    return out


def restore_saved():
    """Si la vez anterior no se alcanzó a devolver el volumen, se devuelve ahora."""
    saved = Config.get("volumenes_previos") or {}
    if not saved:
        return
    try:
        import comtypes
        comtypes.CoInitialize()
        for pid, vol in _sessions():
            if str(pid) in saved:
                vol.SetMasterVolume(float(saved[str(pid)]), None)
    except Exception as e:
        log(f"No pude devolver el volumen de otras apps: {e}")
    Config.update(volumenes_previos={})


class Ducker:
    def __init__(self, level):
        self.level = max(0.0, min(1.0, level))
        self.speaking = False
        self._orig = {}
        self._run = False
        self._thread = None

    def set_level(self, level):
        self.level = max(0.0, min(1.0, level))

    def start(self):
        self._run = True
        self._thread = threading.Thread(target=self._loop, name="interprete.volumen", daemon=True)
        self._thread.start()

    def _loop(self):
        try:
            import comtypes
            comtypes.CoInitialize()
        except Exception:
            pass
        last = None
        while self._run:
            try:
                for pid, vol in _sessions():
                    if pid not in self._orig:
                        self._orig[pid] = vol.GetMasterVolume()
                        Config.update(volumenes_previos={str(k): v for k, v in self._orig.items()})
                    vol.SetMasterVolume(self._orig[pid] * self.level, None)
                if last is None:
                    log(f"Volumen de la llamada original al {int(self.level * 100)} % en {len(self._orig)} aplicaciones")
                last = self.level
            except Exception as e:
                if last is None:
                    log(f"No pude bajar el volumen de la llamada: {e}")
                    return
            time.sleep(0.5)
        try:
            for pid, vol in _sessions():
                if pid in self._orig:
                    vol.SetMasterVolume(self._orig[pid], None)
        except Exception as e:
            log(f"No pude devolver el volumen de otras apps: {e}")
        Config.update(volumenes_previos={})

    def stop(self):
        self._run = False
        if self._thread:
            self._thread.join(timeout=3)
