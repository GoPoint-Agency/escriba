# Intérprete para Windows

Misma idea que la app del Mac: traduce en vivo los dos sentidos de una llamada.

- **Traducir lo que escucho**: lo que suena en el computador se traduce al español y sale por tus audífonos; la llamada original queda bajita de fondo.
- **Traducir mi voz**: tu micrófono se traduce al inglés y sale por un micrófono virtual (VB-CABLE). En la llamada se elige «CABLE Output (VB-Audio Virtual Cable)» como micrófono. Por debajo va tu voz original, bajita.
- **Voz con que me escuchan**: automática (la más rápida), hombre o mujer.

## Piezas
- `interprete/core.py`: conexión con OpenAI (dos motores) y colas de audio. No toca dispositivos; se prueba en cualquier sistema.
- `interprete/audio.py`: micrófono, micrófono virtual, captura de lo que suena (WASAPI por `soundcard`).
- `helper/captura.cpp`: entrega el audio del sistema sin el de la app (captura por proceso de WASAPI, Windows 10 2004+). Sin él se usa el modo simple.
- `interprete/volumen.py`: baja las demás apps mientras se traduce y las devuelve al terminar.
- `interprete/app.py`: ícono de bandeja y menú.

## Probar
```
python -m venv .venv && .venv\Scripts\activate && pip install -r requirements.txt
python -m unittest discover -s tests            # núcleo, sin OpenAI ni audio
python -m interprete.prueba dispositivos
python -m interprete.prueba traducir entrada.wav salida.wav en [hombre|mujer]    # necesita OPENAI_API_KEY
python interprete_main.py                        # la app
```
Variables de prueba: `INTERPRETE_DIR`, `INTERPRETE_VOZ_ARCHIVO`, `INTERPRETE_ESCUCHA_ARCHIVO`, `INTERPRETE_SALIDA`, `INTERPRETE_MIC_VIRTUAL`.

## Compilar
`.github/workflows/windows.yml` compila `captura.exe`, corre las pruebas y arma `Interprete.exe` con PyInstaller en un Windows de GitHub.

## Estado (23-nov-2026)
Probado en macOS con BlackHole: los dos sentidos, los dos motores y la voz original de fondo. **Sin probar en un Windows real**: la captura por proceso, el control de volumen, VB-CABLE y el ícono de bandeja.
