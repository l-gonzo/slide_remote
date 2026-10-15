#!/usr/bin/env bash
# Crea el instalador de la app de escritorio para macOS:
#   dist/SlideRemote-<versión>-macos.dmg   (arrastrar a Aplicaciones)
#
#   tool/package_macos.sh            # compila y empaqueta
#   tool/package_macos.sh --no-build
#
# Firma: por defecto "ad hoc" (sin cuenta de Apple). Para firmar con tu certificado
# Developer ID:  SIGN_ID="Developer ID Application: Tu Nombre (EQUIPO)" tool/package_macos.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

[[ "${1:-}" == "--no-build" ]] || flutter build macos --release

VERSION=$(sed -n -E 's/^version: *([0-9.]+).*/\1/p' pubspec.yaml)
APP="build/macos/Build/Products/Release/Slide Remote.app"
[[ -d "$APP" ]] || { echo "No existe $APP. Compila primero."; exit 1; }

SIGN_ID=${SIGN_ID:--}
echo "==> Firmando (${SIGN_ID})"
# Una firma estable hace que el permiso de Accesibilidad no se pierda al actualizar
codesign --force --deep --options runtime --sign "$SIGN_ID" \
  --entitlements macos/Runner/Release.entitlements "$APP"

mkdir -p dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Aplicaciones"
DMG="dist/SlideRemote-${VERSION}-macos.dmg"
rm -f "$DMG"
echo "==> Creando $DMG"
hdiutil create -volname "Slide Remote" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Listo: $DMG"
if [[ "$SIGN_ID" == "-" ]]; then
  echo "Sin firma de Apple: la primera vez abre la app con clic derecho → Abrir"
  echo "(o: xattr -dr com.apple.quarantine \"/Applications/Slide Remote.app\")."
fi
