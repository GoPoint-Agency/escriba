#!/bin/bash
# Compila, firma e instala las dos apps que salen de este repositorio:
#   Escriba     transcribe reuniones y dicta        (Sources/Comun + Sources/Escriba)
#   Intérprete  traduce las llamadas en vivo        (Sources/Comun + Sources/Interprete)
# Uso: ./build.sh [escriba|interprete|todo] [--no-install]
set -euo pipefail
cd "$(dirname "$0")"
# La identidad de firma es de cada equipo y no va en el repositorio: se lee de .firma.local
# (variables KC, IDENT y CLAVE). Sin ese archivo la app se firma sin identidad: funciona igual,
# pero macOS vuelve a pedir los permisos cada vez que se recompila.
KC=""; IDENT=""; CLAVE=""
[ -f .firma.local ] && . ./.firma.local
CUAL="todo"; INSTALAR=1
for a in "$@"; do
  case "$a" in
    escriba|interprete|todo) CUAL="$a" ;;
    --no-install) INSTALAR=0 ;;
    *) echo "Uso: ./build.sh [escriba|interprete|todo] [--no-install]"; exit 1 ;;
  esac
done
# Universal: chip Apple (con GPU) e Intel, desde macOS 13.
ARCHS="${ARCHS:-arm64 x86_64}"

# armar <ejecutable> <carpeta de fuentes> <Info.plist> <ícono> <identificador> <whisper: si|no>
armar() {
  local NOMBRE="$1" FUENTES="$2" PLIST="$3" ICONO="$4" ID="$5" WHISPER="$6"
  local APP="build/$NOMBRE.app" SLICES=()
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  for A in $ARCHS; do
    local EXTRA=()
    if [ "$WHISPER" = si ]; then
      local LIBS="vendor/whisper/lib-$A"
      EXTRA=(-import-objc-header Sources/Escriba/Bridge.h -Xcc -Ivendor/whisper/include -L"$LIBS" -lwhisper -lggml -lggml-cpu -lggml-blas)
      [ -f "$LIBS/libggml-metal.a" ] && EXTRA+=(-lggml-metal -framework Metal -framework MetalKit)
      EXTRA+=(-lggml-base -lc++ -framework Accelerate)
    fi
    swiftc -O -swift-version 5 -target $A-apple-macos13.0 Sources/Comun/*.swift "$FUENTES"/*.swift \
      ${EXTRA[@]+"${EXTRA[@]}"} -o "build/$NOMBRE-$A" 2>&1 | grep -v "warning:" | grep -vE "^\s*(\||[0-9]+ \|)" | grep -v "^\[#" || true
    test -x "build/$NOMBRE-$A"
    SLICES+=("build/$NOMBRE-$A")
  done
  lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$NOMBRE"
  rm -f "${SLICES[@]}"
  cp "$PLIST" "$APP/Contents/Info.plist"
  [ -f "$ICONO" ] && cp "$ICONO" "$APP/Contents/Resources/AppIcon.icns"
  if [ -n "$IDENT" ] && [ -f "$KC" ]; then
    security unlock-keychain -p "$CLAVE" "$KC"
    codesign --force --sign "$IDENT" --keychain "$KC" --identifier "$ID" "$APP"
    codesign -d -r- "$APP" 2>&1 | grep designated
  else
    codesign --force --sign - --identifier "$ID" "$APP"
    echo "$NOMBRE firmada sin identidad (no hay .firma.local)"
  fi
  if [ "$INSTALAR" = 1 ]; then
    pkill -x "$NOMBRE" 2>/dev/null && sleep 1 || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$NOMBRE.app"
    ditto "$APP" "$HOME/Applications/$NOMBRE.app"
    echo "Instalada en ~/Applications/$NOMBRE.app"
  fi
}

if [ "$CUAL" != interprete ]; then armar Escriba Sources/Escriba Info.plist AppIcon.icns com.gopoint.escriba si; fi
if [ "$CUAL" != escriba ]; then armar Interprete Sources/Interprete Info-Interprete.plist AppIcon-Interprete.icns com.gopoint.interprete no; fi
