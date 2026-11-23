"""Intérprete para Windows: ícono en la bandeja con el mismo menú que la app del Mac."""
import os
import sys
import threading
import time
import webbrowser

from . import audio, core
from .config import Config, carpeta, log

VERSION = "20261123b"
VOCES = [("Automática (la más rápida)", "auto"), ("Hombre (voz fija)", "hombre"), ("Mujer (voz fija)", "mujer")]
NIVELES = [("Apagada", 0.0), ("Muy baja", 0.05), ("Baja (recomendada)", 0.10), ("Media", 0.20)]
CABLE_URL = "https://vb-audio.com/Cable/"


class App:
    def __init__(self):
        self.listen = None
        self.voice = None
        self.busy = False
        self.icon = None

    # Ícono ---------------------------------------------------------------------------------------------------

    def image(self, active=False):
        from PIL import Image, ImageDraw
        img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.ellipse((2, 2, 62, 62), fill=(255, 66, 0, 255))
        for x, h in ((18, 12), (27, 26), (36, 18), (45, 30)):       # onda de voz
            d.rounded_rectangle((x - 3, 32 - h // 2, x + 3, 32 + h // 2), radius=3, fill="white")
        if active:
            d.ellipse((42, 42, 62, 62), fill=(30, 200, 90, 255), outline="white", width=3)
        return img

    def refresh(self):
        if not self.icon:
            return
        on = self.listen is not None or self.voice is not None
        self.icon.icon = self.image(on)
        partes = []
        if self.listen:
            partes.append("escuchas en español")
        if self.voice:
            partes.append("te escuchan en inglés")
        self.icon.title = "Intérprete: " + (" y ".join(partes) if partes else "en espera")
        self.icon.update_menu()

    def notify(self, title, body):
        log(f"Aviso: {title}: {body}")
        try:
            self.icon.notify(body, title)
        except Exception:
            pass

    # Acciones ------------------------------------------------------------------------------------------------

    def _run(self, fn):
        """Las conexiones tardan un par de segundos: van en un hilo para no congelar el menú."""
        if self.busy:
            return
        self.busy = True

        def work():
            try:
                fn()
            except core.TranslateError as e:
                self.notify("Intérprete", str(e))
            except Exception as e:
                log(f"Error inesperado: {type(e).__name__}: {e}")
                self.notify("Intérprete", f"Algo falló: {str(e)[:120]}")
            finally:
                self.busy = False
                self.refresh()
        threading.Thread(target=work, daemon=True).start()

    def _need_key(self):
        if Config.api_key():
            return False
        self.ask_key()
        return not Config.api_key()

    def toggle_listen(self, *_):
        def go():
            if self.listen:
                s, self.listen = self.listen, None
                s.stop()
                return
            if self._need_key():
                return
            s = audio.Listen(on_stop=lambda m: self._stopped("listen", m))
            s.start()
            self.listen = s
            if not s.exclusive:
                self.notify("Traducción de lo que escucho", "Este Windows no permite separar el audio: usa audífonos y "
                            "ten presente que mientras suena la traducción no se traduce lo que digan encima.")
        self._run(go)

    def toggle_voice(self, *_):
        def go():
            if self.voice:
                s, self.voice = self.voice, None
                s.stop()
                return
            if audio.virtual_mic() is None:
                self.install_cable()
                return
            if self._need_key():
                return
            s = audio.VoiceOut(on_stop=lambda m: self._stopped("voice", m))
            s.start()
            self.voice = s
            self.notify("Te escuchan en inglés", f"Hablas por «{s.mic_name}». En la llamada elige como micrófono "
                        "«CABLE Output (VB-Audio Virtual Cable)».")
        self._run(go)

    def toggle_both(self, *_):
        def go():
            if self.listen or self.voice:
                for name in ("listen", "voice"):
                    s = getattr(self, name)
                    setattr(self, name, None)
                    if s:
                        s.stop()
                return
            if audio.virtual_mic() is None:
                self.install_cable()
                return
            if self._need_key():
                return
            l = audio.Listen(on_stop=lambda m: self._stopped("listen", m))
            l.start()
            self.listen = l
            v = audio.VoiceOut(on_stop=lambda m: self._stopped("voice", m))
            v.start()
            self.voice = v
            self.notify("Modo intérprete", "Tú escuchas en español y a ti te escuchan en inglés. En la llamada elige "
                        "como micrófono «CABLE Output (VB-Audio Virtual Cable)» y usa audífonos.")
        self._run(go)

    def _stopped(self, which, reason):
        setattr(self, which, None)
        self.notify("Intérprete se detuvo", reason)
        self.refresh()

    def install_cable(self, *_):
        webbrowser.open(CABLE_URL)
        self.notify("Falta el micrófono virtual", "Se abrió la página de VB-CABLE (gratis). Descárgalo, descomprime, "
                    "clic derecho en VBCABLE_Setup_x64 > Ejecutar como administrador, y reinicia el computador.")

    def ask_key(self, *_):
        """Ventana simple para pegar la clave de OpenAI. Se guarda solo en este computador."""
        done = threading.Event()

        def ui():
            try:
                import tkinter as tk
                from tkinter import simpledialog
                root = tk.Tk()
                root.withdraw()
                root.attributes("-topmost", True)
                v = simpledialog.askstring("Intérprete", "Pega la clave de OpenAI (empieza con sk-).\n"
                                           "Se guarda solo en este computador.", show="*", parent=root)
                root.destroy()
                if v and v.strip():
                    Config.update(openai_api_key=v.strip())
                    log("Clave de OpenAI guardada")
            except Exception as e:
                log(f"No pude mostrar la ventana de la clave: {e}")
            done.set()
        threading.Thread(target=ui, daemon=True).start()
        done.wait(300)

    def open_log(self, *_):
        p = os.path.join(carpeta(), "interprete.log")
        if sys.platform == "win32":
            os.startfile(p)        # noqa
        else:
            webbrowser.open("file://" + p)

    def quit(self, *_):
        for s in (self.listen, self.voice):
            if s:
                s.stop()
        self.icon.stop()

    # Menú ----------------------------------------------------------------------------------------------------

    def menu(self):
        import pystray
        Item, Menu = pystray.MenuItem, pystray.Menu

        def set_cfg(key, value, live=None):
            def f(*_):
                Config.update(**{key: value})
                if live:
                    live(value)
                if key == "voz_traduccion" and self.voice:
                    self.notify("Voz de la traducción", "El cambio se aplica la próxima vez que actives la traducción de tu voz.")
            return f

        def choice(key, value):
            return lambda _: (abs(Config.get(key) - value) < 0.011) if isinstance(value, float) else Config.get(key) == value

        voces = Menu(*[Item(n, set_cfg("voz_traduccion", k), checked=choice("voz_traduccion", k), radio=True) for n, k in VOCES])
        propia = Menu(*[Item(n, set_cfg("mi_voz_original", v, lambda x: self.voice and self.voice.set_own_voice(x)),
                             checked=choice("mi_voz_original", v), radio=True) for n, v in NIVELES])
        original = Menu(*[Item(n, set_cfg("volumen_original", v, lambda x: self.listen and self.listen.set_original_volume(x)),
                               checked=choice("volumen_original", v), radio=True) for n, v in NIVELES])
        return Menu(
            Item(lambda _: "Detener el modo intérprete" if (self.listen and self.voice) else "Modo intérprete: traducir en los dos sentidos",
                 self.toggle_both, default=True),
            Item(lambda _: "Detener traducción de lo que escucho" if self.listen else "Traducir al español lo que escucho",
                 self.toggle_listen),
            Item(lambda _: "Detener traducción de mi voz" if self.voice else "Traducir mi voz al inglés para los demás",
                 self.toggle_voice),
            Menu.SEPARATOR,
            Item("Voz con que me escuchan", voces),
            Item("Mi voz original de fondo (para quien me escucha)", propia),
            Item("Volumen de la llamada original (para mí)", original),
            Menu.SEPARATOR,
            Item("Instalar el micrófono virtual (VB-CABLE)…", self.install_cable, visible=lambda _: audio.virtual_mic() is None),
            Item(lambda _: "Clave de OpenAI…" if Config.api_key() else "Poner la clave de OpenAI…",
                 lambda *_: threading.Thread(target=self.ask_key, daemon=True).start()),
            Item("Ver el registro", self.open_log),
            Item(f"Intérprete {VERSION}", None, enabled=False),
            Item("Salir", self.quit),
        )

    def run(self):
        import pystray
        if sys.platform == "win32":
            try:
                from . import volumen
                volumen.restore_saved()
            except Exception as e:
                log(f"Volumen: {e}")
        log(f"Intérprete {VERSION} iniciado (clave={'sí' if Config.api_key() else 'no'}, "
            f"micrófono virtual={'sí' if audio.virtual_mic() else 'no'}, captura por app={'sí' if audio.helper_path() else 'no'})")
        self.icon = pystray.Icon("Interprete", self.image(), "Intérprete: en espera", self.menu())
        self.icon.run(setup=self._ready)

    def _ready(self, icon):
        icon.visible = True
        if not Config.api_key():
            threading.Thread(target=self.ask_key, daemon=True).start()


def single_instance():
    """Una sola copia a la vez (dos copias se pisarían el micrófono virtual)."""
    if sys.platform != "win32":
        return True
    import ctypes
    ctypes.windll.kernel32.CreateMutexW(None, False, "Local\\InterpreteGoPoint")
    return ctypes.windll.kernel32.GetLastError() != 183      # ERROR_ALREADY_EXISTS


def main():
    a = sys.argv[1:]
    if a and a[0] == "--version":
        if sys.stdout:
            print(VERSION)
        return 0
    if a and a[0] == "--prueba":                 # pruebas sin bandeja: ver interprete/prueba.py
        sys.argv = [sys.argv[0]] + a[1:]
        from . import prueba
        prueba.main()
        return 0
    if not single_instance():
        return 0
    App().run()
    return 0
