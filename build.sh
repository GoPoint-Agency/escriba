#!/bin/bash
# Compila Escriba, la firma y la instala en ~/Applications/Escriba.app.
set -euo pipefail
cd "$(dirname "$0")"
# La identidad de firma es de cada equipo y no va en el repositorio: se lee de .firma.local
# (variables KC, IDENT y CLAVE). Sin ese archivo la app se firma sin identidad: funciona igual,
# pero macOS vuelve a pedir los permisos cada vez que se recompila.
KC=""; IDENT=""; CLAVE=""
[ -f .firma.local ] && . ./.firma.local
APP="build/Escriba.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal: chip Apple (con GPU) e Intel, desde macOS 13.
ARCHS="${ARCHS:-arm64 x86_64}"
SLICES=()
for A in $ARCHS; do
  LIBS="vendor/whisper/lib-$A"
  EXTRA=()
  [ -f "$LIBS/libggml-metal.a" ] && EXTRA=(-lggml-metal -framework Metal -framework MetalKit)
  swiftc -O -swift-version 5 -target $A-apple-macos13.0 Sources/*.swift \
    -import-objc-header Sources/Bridge.h -Xcc -Ivendor/whisper/include \
    -L"$LIBS" -lwhisper -lggml -lggml-cpu -lggml-blas ${EXTRA[@]+"${EXTRA[@]}"} -lggml-base -lc++ -framework Accelerate \
    -o "build/Escriba-$A" 2>&1 | grep -v "warning:" | grep -vE "^\s*(\||[0-9]+ \|)" | grep -v "^\[#" || true
  test -x "build/Escriba-$A"
  SLICES+=("build/Escriba-$A")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Escriba"
rm -f "${SLICES[@]}"
test -x "$APP/Contents/MacOS/Escriba"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -n "$IDENT" ] && [ -f "$KC" ]; then
  security unlock-keychain -p "$CLAVE" "$KC"
  codesign --force --sign "$IDENT" --keychain "$KC" --identifier com.gopoint.escriba "$APP"
  codesign -d -r- "$APP" 2>&1 | grep designated
else
  codesign --force --sign - --identifier com.gopoint.escriba "$APP"
  echo "Firmada sin identidad (no hay .firma.local)"
fi

if [ "${1:-}" != "--no-install" ]; then
  pkill -x Escriba 2>/dev/null && sleep 1 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Escriba.app"
  ditto "$APP" "$HOME/Applications/Escriba.app"
  echo "Instalada en ~/Applications/Escriba.app"
fi
