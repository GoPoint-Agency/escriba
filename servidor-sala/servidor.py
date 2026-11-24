"""Sala de equipo de Intérprete: reenvía avisos cortos entre las apps que comparten un código.

No guarda nada ni registra el contenido: solo cuenta conexiones. Cada mensaje que manda una app se
reenvía tal cual a las demás de la misma sala, con el número de quien lo mandó.
"""
import asyncio
import json
import os
import re
import time

import websockets

PUERTO = int(os.environ.get("PUERTO", "8080"))
MAX_SALA = 8            # apps por sala
MAX_TOTAL = 300         # conexiones en total
MAX_BYTES = 700         # tamaño de un mensaje
MAX_POR_SEG = 30        # mensajes por segundo de una app
RX_RUTA = re.compile(r"^/s/([A-Z0-9]{6,12})$")

salas = {}              # código -> {websocket: número}
total = 0


def log(texto):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), texto, flush=True)


async def avisar(sala, mensaje, menos=None):
    datos = json.dumps(mensaje, separators=(",", ":"))
    for ws in list(sala):
        if ws is not menos:
            try:
                await ws.send(datos)
            except Exception:
                pass


async def atender(ws):
    global total
    ruta = getattr(getattr(ws, "request", None), "path", None) or getattr(ws, "path", "")
    m = RX_RUTA.match(ruta.split("?")[0])
    if not m:
        await ws.close(4000, "ruta")
        return
    codigo = m.group(1)
    sala = salas.setdefault(codigo, {})
    if len(sala) >= MAX_SALA or total >= MAX_TOTAL:
        if not sala:
            salas.pop(codigo, None)
        await ws.close(4001, "llena")
        return
    numero = 1 + max(sala.values(), default=0)
    sala[ws] = numero
    total += 1
    log(f"entra: sala de {len(sala)}, {total} conexiones")
    try:
        await avisar(sala, {"t": "sala", "n": len(sala)})
        ventana, cuenta = time.monotonic(), 0
        async for crudo in ws:
            if not isinstance(crudo, str) or len(crudo) > MAX_BYTES:
                continue
            ahora = time.monotonic()
            if ahora - ventana >= 1:
                ventana, cuenta = ahora, 0
            cuenta += 1
            if cuenta > MAX_POR_SEG:
                continue
            try:
                j = json.loads(crudo)
            except ValueError:
                continue
            if not isinstance(j, dict) or j.get("t") not in ("voz", "txt"):
                continue
            j["de"] = numero
            await avisar(sala, j, menos=ws)
    except websockets.ConnectionClosed:
        pass
    finally:
        sala.pop(ws, None)
        total -= 1
        if sala:
            await avisar(sala, {"t": "sala", "n": len(sala)})
            await avisar(sala, {"t": "voz", "on": False, "de": numero})
        else:
            salas.pop(codigo, None)
        log(f"sale: quedan {total} conexiones")


async def main():
    async with websockets.serve(atender, "0.0.0.0", PUERTO, max_size=MAX_BYTES + 100, ping_interval=20, ping_timeout=20):
        log(f"sala de Intérprete escuchando en {PUERTO}")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
