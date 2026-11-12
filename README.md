# Escriba

App gratuita para la barra de menú del Mac: transcribe tus reuniones, te deja dictar en cualquier app y traduce llamadas en tiempo real. Hecha por [GoPoint Agency](https://gopointagency.com/escriba).

## Qué hace

- **Reuniones**: graba tu micrófono y el audio de la llamada por separado (Meet, Zoom, Teams o lo que suene en el Mac), transcribe y deja un Word con la transcripción y el audio en Google Drive o en Documentos. Con una clave de OpenAI suma resumen, acuerdos, tareas y nombres.
- **Dictado**: mantén apretada la tecla ⌥ de la derecha, habla y suelta. El texto aparece donde está el cursor.
- **Dictado traducido**: con ⌥ y ⇧ de la derecha a la vez, dictas en español y el texto sale en inglés, portugués, alemán, francés o italiano (se elige en el menú). Necesita una clave de OpenAI.
- **Traducción en vivo**: escuchas en español lo que te dicen en inglés, y la otra persona te escucha en inglés. Usa `gpt-realtime-translate` de OpenAI con tu propia clave.

Transcribe con Whisper dentro del Mac (gratis, sin internet tras una descarga única de 550 MB) o con OpenAI.

## Instalar

En Terminal:

    curl -fsSL https://gopointagency.com/escriba/instalar.sh | bash

Requisitos: macOS 13 o más nuevo, Intel o Apple Silicon. Bajar el volumen del original al traducir necesita macOS 14.2. Traducir tu voz necesita el micrófono virtual BlackHole, que la app instala desde su menú.

## Compilar

Solo hacen falta las Command Line Tools de Xcode:

    ./build.sh              # compila, firma e instala en ~/Applications
    ./build.sh --no-install # solo compila en build/Escriba.app

Sin un archivo `.firma.local` la app se firma sin identidad: funciona, pero macOS vuelve a pedir los permisos al recompilar. Para firmar con una identidad propia, crea `.firma.local` con `KC` (llavero), `IDENT` (huella del certificado) y `CLAVE` (clave del llavero).

## Cómo está armado

| Archivo | Qué hace |
|---|---|
| `Sources/App.swift` | Menú, avisos y arranque |
| `Sources/Session.swift`, `Track.swift`, `Audio.swift` | Grabación, corte por silencios y mezcla |
| `Sources/LocalWhisper.swift`, `OpenAI.swift` | Transcripción local (whisper.cpp) y por OpenAI |
| `Sources/Dictation.swift` | Dictado con ⌥ derecha |
| `Sources/Translator.swift`, `Feeder.swift`, `Playout.swift` | Traducción de lo que escuchas, envío de audio y cola de reproducción |
| `Sources/VoiceOut.swift`, `SystemTap.swift` | Traducción de tu voz hacia el micrófono virtual y captura del audio del sistema |
| `Sources/VirtualMicInstaller.swift` | Instalación de BlackHole desde el menú |
| `vendor/whisper` | whisper.cpp ya compilado (licencia MIT, ver `vendor/whisper/LICENSE`) |

Los ajustes viven en `~/Library/Application Support/Escriba/config.json` y el registro en `escriba.log`, en la misma carpeta. La clave de OpenAI se guarda ahí, nunca en el código.

Pruebas sin abrir la app: `Escriba --check`, `--transcribe <audio>`, `--process <mic> <sys> [carpeta]`, `--simular <audio> <salida.wav> <idioma>`.

## Privacidad

Con Whisper el audio no sale del Mac. Con una clave de OpenAI, el audio o el texto se envía a OpenAI con la cuenta de quien la puso. GoPoint no recibe audio, transcripciones ni datos de uso.

## Licencia

MIT. Se entrega tal como está, sin soporte garantizado.
