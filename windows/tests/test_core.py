"""Pruebas del núcleo sin OpenAI ni dispositivos: un servidor falso imita los dos dialectos de la API."""
import base64
import json
import threading
import time
import unittest

import numpy as np
from websockets.sync.server import serve

from interprete import core


class FakeOpenAI:
    """Devuelve como «traducción» el mismo audio que recibe, y registra lo que le mandan."""

    def __init__(self, reject_voice=False):
        self.events = []
        self.reject_voice = reject_voice
        self.server = serve(self.handle, "127.0.0.1", 0)
        self.port = self.server.socket.getsockname()[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def handle(self, ws):
        agent = "translations" not in ws.request.path
        ws.send(json.dumps({"type": "session.created"}))
        n = 0
        for raw in ws:
            j = json.loads(raw)
            self.events.append(j)
            t = j["type"]
            if t == "session.update":
                if agent and self.reject_voice:
                    ws.send(json.dumps({"type": "error", "error": {"message": "Invalid value: voice"}}))
                else:
                    ws.send(json.dumps({"type": "session.updated"}))
            elif t == "session.input_audio_buffer.append":
                ws.send(json.dumps({"type": "session.output_audio.delta", "delta": j["audio"]}))
                ws.send(json.dumps({"type": "session.output_transcript.delta", "delta": "x"}))
            elif t == "input_audio_buffer.append":
                n += 1
                if n % 3 == 0:                      # cada tres trozos «termina una frase»
                    ws.send(json.dumps({"type": "input_audio_buffer.committed", "item_id": f"item{n}"}))
            elif t == "response.create":
                ws.send(json.dumps({"type": "response.output_audio.delta",
                                    "delta": base64.b64encode(np.full(480, 1000, dtype="<i2").tobytes()).decode()}))
                time.sleep(0.05)
                ws.send(json.dumps({"type": "response.done"}))
            elif t == "session.close":
                ws.send(json.dumps({"type": "session.closed"}))

    def close(self):
        self.server.shutdown()


def socket_for(fake, voice=None, **kw):
    s = core.TranslateSocket("clave", "en", voice=voice, **kw)
    import interprete.core as c
    real = c.connect
    c.connect = lambda url, **k: real(f"ws://127.0.0.1:{fake.port}" + url.split("api.openai.com")[1],
                                      **{x: y for x, y in k.items() if x != "additional_headers"})
    try:
        s.connect()
    finally:
        c.connect = real
    return s


class Socket(unittest.TestCase):
    def test_automatico(self):
        fake = FakeOpenAI()
        got, text = [], []
        s = socket_for(fake, on_audio=got.append, on_text=text.append)
        tone = (np.sin(np.arange(core.CHUNK) / 10) * 0.5).astype(np.float32)
        for _ in range(3):
            s.append(tone)
        time.sleep(0.3)
        s.close()
        fake.close()
        self.assertEqual(len(got), 3)
        self.assertEqual(len(got[0]), core.CHUNK)
        self.assertAlmostEqual(float(np.max(got[0])), 0.5, places=2)
        self.assertEqual("".join(text), "xxx")
        self.assertEqual(fake.events[0]["session"], {"audio": {"output": {"language": "en"}}})
        self.assertEqual(fake.events[-1]["type"], "session.close")

    def test_voz_fija_una_respuesta_por_frase(self):
        fake = FakeOpenAI()
        got = []
        s = socket_for(fake, voice="cedar", on_audio=got.append)
        for _ in range(9):                          # tres frases
            s.append(np.zeros(core.CHUNK, dtype=np.float32))
        time.sleep(0.6)
        s.close()
        fake.close()
        upd = fake.events[0]["session"]
        self.assertEqual(upd["audio"]["output"]["voice"], "cedar")
        self.assertFalse(upd["audio"]["input"]["turn_detection"]["create_response"])
        creates = [e for e in fake.events if e["type"] == "response.create"]
        self.assertEqual([c["response"]["input"][0]["id"] for c in creates], ["item3", "item6", "item9"])
        self.assertTrue(all(c["response"]["conversation"] == "none" for c in creates))
        self.assertEqual(len([e for e in fake.events if e["type"] == "conversation.item.delete"]), 3)
        self.assertEqual(len(got), 3)

    def test_voz_rechazada_no_manda_audio(self):
        fake = FakeOpenAI(reject_voice=True)
        with self.assertRaises(core.TranslateError):
            socket_for(fake, voice="noexiste")
        fake.close()
        self.assertFalse([e for e in fake.events if "append" in e["type"]])


class Colas(unittest.TestCase):
    def test_ring_entrega_silencio_y_luego_audio(self):
        r = core.Ring(cushion=0.1)
        self.assertEqual(float(np.max(np.abs(r.read(480)))), 0)
        r.write(np.ones(1200, dtype=np.float32))          # 50 ms: aún bajo el colchón
        self.assertEqual(float(np.max(r.read(480))), 0)
        r.write(np.ones(2400, dtype=np.float32))
        out = r.read(480)
        self.assertEqual(float(np.min(out)), 1)
        self.assertTrue(r.speaking)

    def test_chunker_trozos_exactos(self):
        got = []
        c = core.Chunker(got.append)
        for _ in range(11):
            c.feed(np.zeros(1000, dtype=np.float32))
        self.assertEqual([len(g) for g in got], [core.CHUNK, core.CHUNK])

    def test_smooth_baja_cuando_suena_la_traduccion(self):
        s = core.Smooth(0.10, 0.05)
        a = s.apply(np.ones(core.RATE, dtype=np.float32), ducked=True)
        self.assertAlmostEqual(float(a[-1]), 0.05, places=2)
        b = s.apply(np.ones(core.RATE * 2, dtype=np.float32), ducked=False)
        self.assertAlmostEqual(float(b[-1]), 0.10, places=2)

    def test_agc_sube_lo_bajo_sin_saturar(self):
        g = core.Agc()
        quiet = (np.sin(np.arange(core.CHUNK) / 8) * 0.01).astype(np.float32)
        for _ in range(60):
            out = g.apply(quiet)
        self.assertGreater(float(np.max(np.abs(out))), 0.08)
        self.assertLessEqual(float(np.max(np.abs(g.apply(np.ones(100, dtype=np.float32))))), 1.0)

    def test_agc_de_salida_sube_la_voz_baja_sin_saturar(self):
        agc = core.Agc(target=0.5, max_gain=6.0, release=1.0)
        t = np.arange(core.RATE * 4) / core.RATE
        bajo = (0.05 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
        out = np.concatenate([agc.apply(bajo[i:i + 2400]) for i in range(0, len(bajo), 2400)])
        self.assertGreater(float(np.max(np.abs(out[-core.RATE:]))), 0.25)
        self.assertLessEqual(float(np.max(np.abs(out))), 1.0)
        fuerte = (0.9 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
        out = np.concatenate([agc.apply(fuerte[i:i + 2400]) for i in range(0, len(fuerte), 2400)])
        self.assertLessEqual(float(np.max(np.abs(out[-core.RATE:]))), 1.0)

    def test_resample(self):
        self.assertEqual(len(core.resample(np.zeros(48000, dtype=np.float32), 48000)), 24000)


class Repeticion(unittest.TestCase):
    """EchoGuard: lo que ya viene en el idioma de quien escucha no se repite; la traducción real sí suena."""

    def run_guard(self, events):
        now = [0.0]
        g = core.EchoGuard(clock=lambda: now[0])
        played = 0
        for t, kind, value in events:
            now[0] = t
            if kind == "o":
                g.source(value)
            elif kind == "t":
                g.translated(value)
            else:
                out = g.audio(np.zeros(int(value * core.RATE), dtype=np.float32))
                played += 0 if out is None else len(out)
        return g, played / core.RATE

    def test_no_repite_lo_que_ya_viene_en_el_idioma(self):
        ev = [(1.5, "o", " ¿Qué pasa con"), (2.1, "t", "¿Qué"), (2.2, "o", " otro"), (2.4, "t", " pasa"),
              (2.5, "o", " tipo de"), (2.6, "a", 0.4), (2.9, "o", " negocios?"), (3.0, "t", " con"), (3.1, "a", 0.4),
              (3.2, "t", " otro"), (3.4, "t", " tipo"), (3.5, "a", 0.4), (3.8, "t", " de negocios"), (3.9, "a", 0.4)]
        g, played = self.run_guard(ev)
        self.assertEqual(g.state, g.ECHO)
        self.assertEqual(played, 0)
        self.assertTrue(g.same_language)

    def test_la_traduccion_real_suena_completa_y_sin_espera(self):
        ev = [(2.8, "o", " Good morning"), (3.2, "t", "Buenos"), (3.7, "o", " everyone"), (3.75, "t", " días"),
              (3.8, "a", 0.4), (4.1, "t", " a"), (4.3, "a", 0.4), (4.5, "t", " todos"), (4.7, "a", 0.4)]
        g, played = self.run_guard(ev)
        self.assertEqual(g.state, g.PASS)
        self.assertAlmostEqual(played, 1.2, places=3)
        self.assertFalse(g.same_language)

    def test_frase_anterior_en_el_otro_idioma_no_confunde(self):
        ev = [(2.3, "o", " gracias por conectarse."), (9.8, "t", "Gracias"), (10.0, "a", 0.4),
              (10.1, "o", " Thanks for having me."), (10.4, "t", " por invitarme"), (10.6, "a", 0.4)]
        g, played = self.run_guard(ev)
        self.assertAlmostEqual(played, 0.8, places=3)

    def test_sin_texto_a_tiempo_se_traduce(self):
        ev = [(1.0, "t", " Sí"), (1.1, "a", 0.3), (1.5, "a", 0.3), (1.9, "a", 0.3)]
        g, played = self.run_guard(ev)
        self.assertAlmostEqual(played, 0.9, places=3)



class Reloj:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t


class SalaDeEquipo(unittest.TestCase):
    """Lo que emite un compañero de la sala no se traduce de vuelta; lo demás sigue igual."""

    def setUp(self):
        from interprete import sala
        self.sala = sala
        self.reloj = Reloj()
        self.compas = sala.Compas(clock=self.reloj)
        self.guard = core.EchoGuard(clock=self.reloj, compas=self.compas)
        self.audio = np.ones(2400, dtype=np.float32)

    def test_codigo(self):
        c = self.sala.nuevo_codigo()
        self.assertEqual(len(c), 8)
        self.assertEqual(self.sala.limpiar_codigo(" " + self.sala.bonito(c).lower() + " "), c)
        self.assertEqual(self.sala.limpiar_codigo("abc"), "")
        self.assertEqual(self.sala.limpiar_codigo(None), "")

    def test_sin_companeros_traduce(self):
        self.guard.source("We should move the launch to next quarter. ")
        self.guard.translated("Deberíamos mover el lanzamiento al próximo trimestre. ")
        self.assertIsNotNone(self.guard.audio(self.audio))
        self.assertEqual(self.guard.skipped_team, 0)

    def test_companero_hablando_no_se_traduce(self):
        self.compas.voz(2, True)
        self.guard.source("We should move the launch to next quarter. ")
        self.guard.translated("Deberíamos mover el lanzamiento. ")
        self.assertIsNone(self.guard.audio(self.audio))
        self.assertTrue(self.guard.same_language)          # el original debe oírse normal
        self.assertGreater(self.guard.skipped_team, 0)

    def test_cola_despues_de_callar_y_luego_vuelve(self):
        self.compas.voz(2, True)
        self.reloj.t += 3
        self.compas.voz(2, False)
        self.reloj.t += 0.5
        self.assertIsNone(self.guard.audio(self.audio))    # la llamada todavía trae su voz
        self.reloj.t += 6
        self.guard.source("Thanks, what about the budget for marketing? ")
        self.guard.translated("Gracias, y el presupuesto de marketing? ")
        self.assertIsNotNone(self.guard.audio(self.audio)) # ahora habla alguien de verdad en inglés

    def test_aviso_perdido_caduca(self):
        self.compas.voz(2, True)
        self.reloj.t += 10                                 # nunca llegó el «callé» ni se renovó
        self.assertFalse(self.compas.hablando())

    def test_por_el_texto_aunque_ya_callo(self):
        self.compas.texto(["should", "move", "launch", "next", "quarter"])
        self.reloj.t += 4                                  # el compañero calló hace rato, el modelo va atrasado
        self.guard.source("We should move the launch to next quarter. ")
        self.guard.translated("Deberíamos mover el lanzamiento. ")
        self.assertIsNone(self.guard.audio(self.audio))

    def test_texto_distinto_si_se_traduce(self):
        self.compas.texto(["should", "move", "launch", "next", "quarter"])
        self.reloj.t += 4
        self.guard.source("Honestly the budget numbers look wrong again. ")
        self.guard.translated("La verdad, los números del presupuesto. ")
        self.assertIsNotNone(self.guard.audio(self.audio))

    def test_solo_sala_sin_filtro_de_idioma(self):
        g = core.EchoGuard(clock=self.reloj, compas=self.compas, same_language=False)
        g.source("Hola a todos, partamos la reunión ahora. ")
        g.translated("Hola a todos, partamos la reunión ahora. ")
        self.reloj.t += 1
        self.assertIsNotNone(g.audio(self.audio))          # con el filtro apagado, el español se repite como antes
        self.compas.voz(3, True)
        self.assertIsNone(g.audio(self.audio))

if __name__ == "__main__":
    unittest.main()
