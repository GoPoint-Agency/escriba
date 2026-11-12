#!/bin/bash
# Empaqueta las dos apps ya compiladas (build/) con su instalador, listas para copiar al sitio:
#   dist/web-<versión>/escriba/     -> client/public/escriba/
#   dist/web-<versión>/interprete/  -> client/public/interprete/
# Uso: ./publicar.sh <versión>     (por ejemplo 20261112). Antes: ./build.sh --no-install
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?Uso: ./publicar.sh <versión>}"
D="dist/web-$V"
rm -rf "$D"
empaquetar() {  # app, nombre visible, ruta, bundle, revisión de uso, mensaje final
  local APP="$1" NOMBRE="$2" RUTA="$3" BUNDLE="$4" EN_USO="$5" DESPUES="$6"
  mkdir -p "$D/$RUTA"
  codesign --verify --deep --strict "build/$APP.app"
  ditto -c -k --keepParent "build/$APP.app" "$D/$RUTA/$APP-$V.zip"
  local SHA MB
  SHA=$(shasum -a 256 "$D/$RUTA/$APP-$V.zip" | cut -d' ' -f1)
  MB=$(( ($(stat -f%z "$D/$RUTA/$APP-$V.zip") + 524288) / 1048576 ))
  APP="$APP" NOMBRE="$NOMBRE" RUTA="$RUTA" BUNDLE="$BUNDLE" EN_USO="$EN_USO" DESPUES="$DESPUES" V="$V" SHA="$SHA" MB="$MB" \
  python3 - "$D/$RUTA/instalar.sh" <<'PY'
import os, sys
s = open('instalar.sh.plantilla').read()
for k, v in [('__EN_USO__', os.environ['EN_USO']), ('__DESPUES__', os.environ['DESPUES']), ('__NOMBRE__', os.environ['NOMBRE']),
             ('__APP__', os.environ['APP']), ('__RUTA__', os.environ['RUTA']), ('__BUNDLE__', os.environ['BUNDLE']),
             ('__VERSION__', os.environ['V']), ('__SHA__', os.environ['SHA']), ('__TAMANO__', os.environ['MB'])]:
    s = s.replace(k, v)
open(sys.argv[1], 'w').write(s)
PY
  bash -n "$D/$RUTA/instalar.sh"
  # Control: en el paquete no puede haber nada privado.
  if unzip -l "$D/$RUTA/$APP-$V.zip" | grep -qE "config\.json|\.p12|\.pem|\.firma"; then echo "ERROR: el paquete trae archivos privados"; exit 1; fi
  echo "$RUTA: $APP-$V.zip ($MB MB)"
}
empaquetar Escriba "Escriba" escriba com.gopoint.escriba \
'SES="$HOME/Library/Application Support/Escriba/sesiones"
if pgrep -xq Escriba && [ -d "$SES" ] && [ -n "$(find "$SES" -type f -mmin -2 2>/dev/null | head -1)" ]; then
  fallo "Escriba está grabando una reunión. Detén la grabación y pega la línea de nuevo."
fi' \
'echo "La primera vez te pide tu nombre y tres permisos: micrófono, accesibilidad y grabación de pantalla."
echo ""
echo "La traducción de llamadas ahora es una app aparte, Intérprete. Para instalarla:"
echo "  curl -fsSL https://gopointagency.com/interprete/instalar.sh | bash"'
empaquetar Interprete "Intérprete" interprete com.gopoint.interprete \
'REG="$HOME/Library/Application Support/Interprete/interprete.log"
if pgrep -xq Interprete && [ -f "$REG" ] && grep -E "Traducción (en vivo|de mi voz) (activa|detenida)" "$REG" | tail -1 | grep -q activa; then
  fallo "Intérprete está traduciendo una llamada. Detén la traducción y pega la línea de nuevo."
fi' \
'echo "Necesita una clave de OpenAI. Si ya usas Escriba con clave, la toma sola."
echo "Para que te escuchen traducido, instala el micrófono virtual desde el menú de Intérprete."'
