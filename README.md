# Escriba e Intérprete

Dos apps gratuitas para la barra de menú del Mac, hechas por [GoPoint Agency](https://gopointagency.com/escriba). Salen del mismo código.

## Escriba: lo que escribe

- **Reuniones**: graba tu micrófono y el audio de la llamada por separado (Meet, Zoom, Teams o lo que suene en el Mac), transcribe y deja un Word con la transcripción y el audio en Google Drive o en Documentos. Con una clave de OpenAI suma resumen, acuerdos, tareas y nombres.
- **Dictado**: mantén apretada la tecla ⌥ de la derecha, habla y suelta. El texto aparece donde está el cursor.
- **Dictado traducido**: con ⌥ y ⇧ de la derecha a la vez, dictas en español y el texto sale en inglés, portugués, alemán, francés o italiano (se elige en el menú). Necesita una clave de OpenAI.

Transcribe con Whisper dentro del Mac (gratis, sin internet tras una descarga única de 550 MB) o con OpenAI.

## Intérprete: lo que habla

- **Escuchar en español**: lo que te dicen en inglés lo escuchas traducido, mientras el original baja de volumen.
- **Que te escuchen en inglés**: hablas en español y a la llamada llega tu voz traducida, por un micrófono virtual (BlackHole) que la app instala desde su menú.
- **Modo intérprete**: los dos sentidos a la vez.

Usa `gpt-realtime-translate` de OpenAI con tu propia clave. Si Escriba ya tiene una clave puesta, Intérprete la usa.

Las dos apps conviven: si grabas una reunión con Escriba mientras Intérprete traduce, la grabación deja fuera la voz traducida y sigue tomando tu voz real.

## Instalar

En Terminal:

    curl -fsSL https://gopointagency.com/escriba/instalar.sh | bash

Esa línea instala Escriba. Intérprete todavía no tiene instalador público: se compila con `./build.sh interprete`.

Requisitos: macOS 13 o más nuevo, Intel o Apple Silicon. En Intérprete, bajar el volumen del original necesita macOS 14.2, y traducir tu voz necesita el micrófono virtual BlackHole, que la app instala desde su menú.

## Compilar

Solo hacen falta las Command Line Tools de Xcode:

    ./build.sh                          # compila, firma e instala las dos en ~/Applications
    ./build.sh escriba --no-install     # solo Escriba, en build/Escriba.app
    ./build.sh interprete --no-install  # solo Intérprete, en build/Interprete.app

Sin un archivo `.firma.local` las apps se firman sin identidad: funcionan, pero macOS vuelve a pedir los permisos al recompilar. Para firmar con una identidad propia, crea `.firma.local` con `KC` (llavero), `IDENT` (huella del certificado) y `CLAVE` (clave del llavero).

## Cómo está armado

| Carpeta | Qué tiene |
|---|---|
| `Sources/Comun` | Lo que comparten las dos: ajustes (`Config.swift`), audio, dispositivos de sonido y errores |
| `Sources/Escriba` | Menú, grabación y corte por silencios (`Session.swift`, `Track.swift`), transcripción local y por OpenAI, dictado (`Dictation.swift`) y el Word |
| `Sources/Interprete` | Menú, traducción de lo que escuchas (`Translator.swift`, `Feeder.swift`, `Playout.swift`), traducción de tu voz (`VoiceOut.swift`, `SystemTap.swift`) e instalación de BlackHole |
| `vendor/whisper` | whisper.cpp ya compilado (licencia MIT, ver `vendor/whisper/LICENSE`), solo lo usa Escriba |

Los ajustes viven en `~/Library/Application Support/Escriba/config.json` y `~/Library/Application Support/Interprete/config.json`, con su registro al lado (`escriba.log`, `interprete.log`). La clave de OpenAI se guarda ahí, nunca en el código.

Pruebas sin abrir las apps: `Escriba --check`, `--transcribe <audio>`, `--probar-teclas`, `--dictar-traducido <audio> [idioma]`; `Interprete --traducir <audio> [salida.wav] [idioma]`, `--simular <audio> <salida.wav> <idioma>`.

## Privacidad

Con Whisper el audio no sale del Mac. Con una clave de OpenAI, el audio o el texto se envía a OpenAI con la cuenta de quien la puso. GoPoint no recibe audio, transcripciones ni datos de uso.

## Licencia

MIT. Se entrega tal como está, sin soporte garantizado.
