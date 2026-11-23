# Traspaso de Intérprete (12-nov-2026)

Desde el 12-nov Intérprete se sigue en el chat APP INTERPRETE; APP ESCRIBA queda solo para Escriba.

## Qué es
App separada de Escriba el 12-nov. Escriba = lo que escribe (reuniones, dictado, dictado traducido). Intérprete = lo que habla (escuchar en español, que te escuchen en inglés, modo intérprete).

## Dónde vive
- Código: ~/Developer/escriba (mismo repo para las dos), público en https://github.com/GoPoint-Agency/escriba, main, MIT.
  - Sources/Comun: compartido (Config, Audio, AudioDevices, Base). Si lo cambias, avisa a APP ESCRIBA.
  - Sources/Interprete: App.swift, Ajustes.swift, Translator.swift, Feeder.swift, Playout.swift, SystemTap.swift, VoiceOut.swift, VirtualMicInstaller.swift, main.swift, Identidad.swift.
  - Sources/Escriba: no tocar.
- Compilar: `./build.sh interprete [--no-install]`. Bundle com.gopoint.interprete, ~/Applications/Interprete.app, Info-Interprete.plist, AppIcon-Interprete.icns (tools/icono.swift con argumento `interprete`).
- Ajustes y registro: ~/Library/Application Support/Interprete/config.json e interprete.log.
- Clave de OpenAI: la suya o, si no tiene, la de Escriba (Config.sibling). La primera vez copia los ajustes de traducción de Escriba (Config.adoptFromEscriba).
- Firma: identidad local (.firma.local, fuera del repo). Sin Developer ID ni notarización (Toma ya la tiene; ver chat APP TOMA).

## Publicado (web-gopoint, commit 5a69aa2)
- Landing /interprete: client/src/pages/Interprete.tsx e Interprete.css. Reusa clases ep- de Escriba.css y suma in-. Cambios de clases ep- van en Interprete.css. Logo GitHub: client/src/components/LogoGitHub.tsx.
- Instalador: `curl -fsSL https://gopointagency.com/interprete/instalar.sh | bash` (client/public/interprete/). En menú Productos, /productos, sitemap, robots, route-meta.js, server.js (REACT_PAGES_WITH_STATIC_DIR).
- Versión nueva: `./build.sh --no-install`, `./publicar.sh <versión>`, copiar SOLO dist/web-<versión>/interprete/ a client/public/interprete/ borrando el zip anterior.

## Convivencia con Escriba (probado)
- Ventana ancla invisible al abrir: sin ella Escriba no puede excluir su audio de las grabaciones.
- Cuando Intérprete pone el micrófono virtual como del sistema, Escriba lee el micrófono real aparte.
- Micrófono puente «Micrófono Intérprete» (UID com.gopoint.interprete.microfono); el viejo «Micrófono Escriba» se reconoce y se limpia.
- El dictado de Escriba avisa que no funciona mientras Intérprete traduce la voz.

## Traducción (medido 10-nov)
- gpt-realtime-translate, wss://api.openai.com/v1/realtime/translations, PCM16 24 kHz en trozos de 200 ms, US$0,034/min por sentido.
- Empieza entre 1 s antes y 1,4 s después del fin de la frase; termina ~3 s después. No hay parámetro de velocidad.
- Descartado: adelantar silencio al modelo (ganaba 0,3-0,8 s, +16-29 % costo, 3 de 26 pruebas mal).
- Volumen del original 10 % / 4 % mientras suena (macOS 14.2).
- Log por sesión: «retraso: en N frases… Cola… Red…».
- Telegram sí; WhatsApp no (rechaza micrófonos virtuales). Meet/Zoom/Teams sin probar.
- Alternativa vista por Seba: Gemini 3.5 Live Translate (vista previa, ~US$0,037/min, sesiones de 15 min). Sin probar.

## Pruebas (Interprete --…)
--traducir, --simular, --reproducir, --acelerar, --escuchar, --grabar-app, --apps-microfono (mirar antes de probar con sonido), --que-microfono, --probar-microfono-virtual; con la app --autotest-traducir|voz|interprete (ESCRIBA_PRUEBA_S, ESCRIBA_DIR, ESCRIBA_VOZ_ARCHIVO). Audios en build/lat/. Las pruebas suenan por los audífonos de Seba.

## Pendiente
1. Probar en una llamada real desde la separación.
2. Jesús debe instalar Intérprete aparte (BlackHole ya lo tiene).
3. Developer ID y notarización.
4. Probar en Meet, Zoom y Teams.

## 23-nov-2026: voz fija, voz original de fondo y retraso (pedido de Seba por los comentarios de Jesús)
- **Voz con que me escuchan** (menú, `voz_traduccion`: auto | hombre | mujer). `gpt-realtime-translate` NO deja elegir voz (`Unknown parameter: 'session.audio.output.voice'`, probado); imita la que escucha y a veces sale de otro género. Con hombre o mujer se usa otro motor: `gpt-realtime-2.1` por `wss://api.openai.com/v1/realtime` como intérprete (voces `cedar` y `marin`, velocidad 1,15, `server_vad` con 250 ms de silencio y `create_response: false`).
- Con voz fija cada frase se traduce sola: al llegar `input_audio_buffer.committed` se pide `response.create` con `conversation: "none"` e `input: [item_reference]`, una a la vez y en orden, y se borra el ítem al terminar. Con la conversación normal y respuesta automática se vio: frases perdidas («Conversation already has an active response»), una repetida y una inventada. No volver a ese esquema.
- No se manda audio hasta recibir `session.updated`: si OpenAI rechaza los ajustes, el modelo queda sin instrucciones y contesta como asistente (se vio en una prueba).
- Retraso medido (es5p.wav, 5 frases): automática empieza -0,2 s respecto del fin de la frase y termina +2,7 s; voz fija empieza +1,5 a +1,7 s y termina +3,6 a +4,0 s. Bajar el silencio a 200 ms, el colchón a 80 ms o usar `semantic_vad` no mejoró (semantic empeoró). El piso es el modelo.
- **Mi voz original de fondo** (menú, `mi_voz_original`, por defecto 0,10): la voz del micrófono real se mezcla en el micrófono virtual por debajo de la traducción y baja a la mitad mientras suena (`ownVoice` en VoiceOut.swift). Probado grabando BlackHole.
- Pruebas: `ESCRIBA_VOZ_FIJA=cedar|marin Interprete --traducir|--simular ...`; variables `ESCRIBA_VOZ_SILENCIO_MS`, `ESCRIBA_VOZ_VELOCIDAD`, `ESCRIBA_VOZ_SEMANTICA`, `ESCRIBA_COLCHON_MS`, `ESCRIBA_SALIDA_EXTRA` (JSON extra para audio.output del modelo de traducción).
- Sin medir: costo real del motor de voz fija (precio de lista de audio: US$32 entrada y US$64 salida por millón de tokens). Sin probar: llamada real con voz fija, y si `cedar` y `marin` suenan bien en español (solo se probó hacia inglés).
