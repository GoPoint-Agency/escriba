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
