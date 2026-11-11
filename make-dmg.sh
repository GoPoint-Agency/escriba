#!/bin/bash
# Arma el instalador para compartir: dist/Escriba.dmg (app universal + instrucciones).
# Nunca incluye config.json, claves ni certs/.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh --no-install
VER=$(date +%Y%m%d)
STAGE=$(mktemp -d)
mkdir -p "$STAGE/Escriba"
ditto build/Escriba.app "$STAGE/Escriba/Escriba.app"
ln -s /Applications "$STAGE/Escriba/Aplicaciones"
cp "LEEME-instalar.txt" "$STAGE/Escriba/Cómo instalar.txt"
mkdir -p dist
rm -f "dist/Escriba-$VER.dmg"
hdiutil create -volname "Escriba" -srcfolder "$STAGE/Escriba" -ov -format UDZO "dist/Escriba-$VER.dmg" >/dev/null
rm -rf "$STAGE"
# Control: dentro no puede haber nada privado.
MNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "dist/Escriba-$VER.dmg" >/dev/null
if find "$MNT" -name "config.json" -o -name "*.p12" -o -name "*.pem" -o -name "*.bin" | grep -q .; then
  hdiutil detach "$MNT" >/dev/null; echo "ERROR: el instalador trae archivos privados"; exit 1
fi
grep -rl "sk-proj\|sk-[A-Za-z0-9]\{20\}" "$MNT" && { hdiutil detach "$MNT" >/dev/null; echo "ERROR: hay una clave dentro"; exit 1; } || true
ls "$MNT"
hdiutil detach "$MNT" >/dev/null
ls -la "dist/Escriba-$VER.dmg"
