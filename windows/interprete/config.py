"""Ajustes de Intérprete: un archivo JSON en la carpeta de datos del usuario."""
import json
import os
import sys
import threading


def carpeta():
    if os.environ.get("INTERPRETE_DIR"):
        base = os.environ["INTERPRETE_DIR"]
    elif sys.platform == "win32":
        base = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "Interprete")
    else:
        base = os.path.expanduser("~/.interprete-windows")     # solo para probar fuera de Windows
    os.makedirs(base, exist_ok=True)
    return base


class Config:
    _lock = threading.Lock()
    DEFAULTS = {
        "traducir_a": "es",            # idioma en que escuchas a los demás
        "mi_voz_a": "en",              # idioma en que te escuchan
        "voz_traduccion": "auto",      # auto | hombre | mujer
        "mi_voz_original": 0.10,       # cuánto se oye tu voz original por debajo de la traducción
        "volumen_original": 0.10,      # cuánto se oye a los demás por debajo de la traducción
        "no_repetir_mi_idioma": True,  # si alguien ya habla en tu idioma, no se traduce ni se repite
        "sala_codigo": "",             # sala de equipo: código compartido con los compañeros que usan Intérprete
        "microfono": "",               # parte del nombre; vacío = el del sistema
        "microfono_virtual": "CABLE Input",
    }

    @classmethod
    def path(cls):
        return os.path.join(carpeta(), "config.json")

    @classmethod
    def load(cls):
        try:
            with open(cls.path(), encoding="utf-8") as f:
                d = json.load(f)
        except Exception:
            d = {}
        return {**cls.DEFAULTS, **d}

    @classmethod
    def get(cls, key):
        return cls.load().get(key)

    @classmethod
    def update(cls, **changes):
        with cls._lock:
            d = cls.load()
            d.update(changes)
            tmp = cls.path() + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(d, f, ensure_ascii=False, indent=1)
            os.replace(tmp, cls.path())

    @classmethod
    def api_key(cls):
        return os.environ.get("OPENAI_API_KEY") or cls.load().get("openai_api_key") or None


def log(msg):
    import datetime
    line = f"[{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    try:
        with open(os.path.join(carpeta(), "interprete.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    if sys.stdout:
        try:
            print(line)
        except Exception:
            pass
