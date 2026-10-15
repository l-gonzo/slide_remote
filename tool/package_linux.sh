#!/usr/bin/env bash
# Crea los instaladores de la app de escritorio para Linux:
#   dist/slide-remote_<versión>_<arq>.deb      (Ubuntu, Debian, Mint, Pop!_OS…)
#   dist/slide-remote_<versión>_linux-<arq>.tar.gz   (cualquier distribución)
#
#   tool/package_linux.sh            # compila y empaqueta
#   tool/package_linux.sh --no-build # solo empaqueta lo ya compilado
#
# El .deb instala la regla de udev para /dev/uinput, así la app puede presionar teclas sin
# pedir nada más (puede hacer falta cerrar y abrir sesión una vez).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

BUILD=1
[[ "${1:-}" == "--no-build" ]] && BUILD=0

VERSION=$(sed -n -E 's/^version: *([0-9.]+).*/\1/p' pubspec.yaml)
DEB_ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
case "$DEB_ARCH" in
  amd64) FL_ARCH=x64 ;;
  arm64) FL_ARCH=arm64 ;;
  *) echo "Arquitectura no soportada: $DEB_ARCH"; exit 1 ;;
esac
BUNDLE="build/linux/$FL_ARCH/release/bundle"
PKG=slide-remote
DIST="$ROOT/dist"

if [[ $BUILD -eq 1 ]]; then
  echo "==> Compilando (flutter build linux --release)"
  flutter build linux --release
fi
[[ -x "$BUNDLE/slide_remote" ]] || { echo "No existe $BUNDLE/slide_remote. Compila primero."; exit 1; }

mkdir -p "$DIST"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# ------------------------------------------------------------------ .tar.gz portátil
echo "==> .tar.gz"
cp -r "$BUNDLE" "$STAGE/slide-remote"
cp assets/icon/icon.png "$STAGE/slide-remote/slide-remote.png"
cat > "$STAGE/slide-remote/LEEME.txt" <<'EOF'
Slide Remote (app de escritorio)

Ejecuta ./slide_remote

Para que pueda presionar teclas necesita permiso sobre /dev/uinput. Ejecuta una vez:

  echo 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/99-slide-remote.rules
  echo uinput | sudo tee /etc/modules-load.d/slide-remote.conf
  sudo modprobe uinput && sudo udevadm control --reload-rules && sudo udevadm trigger --name-match=uinput

y cierra y abre sesión.
EOF
TAR="$DIST/${PKG}_${VERSION}_linux-${DEB_ARCH}.tar.gz"
tar -C "$STAGE" -czf "$TAR" slide-remote
rm -rf "$STAGE/slide-remote"

# ------------------------------------------------------------------ .deb
echo "==> .deb"
D="$STAGE/deb"
mkdir -p "$D/DEBIAN" "$D/opt/$PKG" "$D/usr/bin" "$D/usr/share/applications" \
  "$D/usr/share/icons/hicolor/256x256/apps" "$D/usr/lib/udev/rules.d" "$D/usr/lib/modules-load.d"
cp -r "$BUNDLE/." "$D/opt/$PKG/"
ln -s "/opt/$PKG/slide_remote" "$D/usr/bin/$PKG"
cp assets/icon/icon.png "$D/usr/share/icons/hicolor/256x256/apps/$PKG.png"

cat > "$D/usr/share/applications/$PKG.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Slide Remote
Comment=Cambia las diapositivas desde el teléfono
Exec=/opt/$PKG/slide_remote
Icon=$PKG
Terminal=false
Categories=Office;Presentation;Utility;
StartupWMClass=slide_remote
EOF

echo 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' \
  > "$D/usr/lib/udev/rules.d/70-slide-remote.rules"
echo uinput > "$D/usr/lib/modules-load.d/slide-remote.conf"

SIZE_KB=$(du -sk "$D" | cut -f1)
cat > "$D/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: Luis Gonzalo Méndez <l-gonzo@users.noreply.github.com>
Installed-Size: $SIZE_KB
Depends: libgtk-3-0t64 | libgtk-3-0
Recommends: libreoffice-impress
Section: utils
Priority: optional
Homepage: https://github.com/l-gonzo/slide_remote
Description: Cambia las diapositivas con los botones de volumen del teléfono
 Receptor de escritorio de Slide Remote: recibe los comandos del teléfono por WiFi o
 Bluetooth LE y presiona AvPág/RePág, y manda las notas del presentador al teléfono.
EOF

cat > "$D/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  modprobe uinput 2>/dev/null || true
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --name-match=uinput 2>/dev/null || true
  fi
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
exit 0
EOF
chmod 0755 "$D/DEBIAN/postinst"

DEB="$DIST/${PKG}_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --root-owner-group --build "$D" "$DEB" >/dev/null

echo
echo "Listo:"
ls -lh "$DEB" "$TAR" | awk '{print "  " $5 "  " $9}'
echo
echo "Instalar:  sudo apt install ./dist/$(basename "$DEB")"
