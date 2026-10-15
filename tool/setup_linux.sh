#!/usr/bin/env bash
# Prepara una computadora con Linux (Ubuntu/Debian) desde cero para compilar Slide Remote:
# Flutter, compilador de la app de Linux, Java 17 y el SDK de Android. Luego prepara el proyecto.
#
#   bash tool/setup_linux.sh               # todo
#   bash tool/setup_linux.sh --no-android  # sin el SDK de Android
#
# Variables opcionales: FLUTTER_DIR=~/flutter   ANDROID_HOME=~/Android/Sdk
# Se puede volver a correr: salta lo que ya está instalado.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FLUTTER_DIR=${FLUTTER_DIR:-$HOME/flutter}
ANDROID_HOME=${ANDROID_HOME:-$HOME/Android/Sdk}
CMDLINE_FALLBACK=13114758   # versión de las "command line tools" si no se puede consultar la última
WITH_ANDROID=1
[[ "${1:-}" == "--no-android" ]] && WITH_ANDROID=0

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
PROFILE="$HOME/.bashrc"
[[ "${SHELL:-}" == */zsh ]] && PROFILE="$HOME/.zshrc"

add_line() { grep -qxF "$1" "$PROFILE" 2>/dev/null || echo "$1" >> "$PROFILE"; }

command -v apt-get >/dev/null || { echo "Este script es para Ubuntu/Debian (apt). En otra distribución instala lo equivalente."; exit 1; }

# ---------------------------------------------------------------- paquetes
log "Paquetes del sistema (pide sudo)"
sudo apt-get update
sudo apt-get install -y git curl unzip xz-utils zip python3 file \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev build-essential dpkg-dev
if [[ $WITH_ANDROID -eq 1 ]]; then
  sudo apt-get install -y openjdk-17-jdk || sudo apt-get install -y openjdk-21-jdk
fi

# ---------------------------------------------------------------- Flutter
if command -v flutter >/dev/null; then
  log "Flutter ya está instalado: $(command -v flutter)"
elif [[ -x "$FLUTTER_DIR/bin/flutter" ]]; then
  log "Flutter ya está en $FLUTTER_DIR"
else
  log "Descargando Flutter (stable) en $FLUTTER_DIR"
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
fi
add_line "export PATH=\"$FLUTTER_DIR/bin:\$PATH\""
export PATH="$FLUTTER_DIR/bin:$PATH"
flutter config --no-analytics >/dev/null 2>&1 || true
flutter --version

# ---------------------------------------------------------------- Android SDK
if [[ $WITH_ANDROID -eq 1 ]]; then
  SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
  if [[ ! -x "$SDKMANAGER" ]]; then
    log "Descargando el SDK de Android (command line tools) en $ANDROID_HOME"
    ver=$(curl -fsSL https://dl.google.com/android/repository/repository2-3.xml 2>/dev/null \
      | grep -oE 'commandlinetools-linux-[0-9]+_latest\.zip' | grep -oE '[0-9]+' | sort -n | tail -1 || true)
    ver=${ver:-$CMDLINE_FALLBACK}
    tmp=$(mktemp -d)
    curl -fL -o "$tmp/tools.zip" "https://dl.google.com/android/repository/commandlinetools-linux-${ver}_latest.zip"
    mkdir -p "$ANDROID_HOME/cmdline-tools"
    unzip -q "$tmp/tools.zip" -d "$tmp"
    rm -rf "$ANDROID_HOME/cmdline-tools/latest"
    mv "$tmp/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
    rm -rf "$tmp"
  else
    log "SDK de Android ya está en $ANDROID_HOME"
  fi
  add_line "export ANDROID_HOME=\"$ANDROID_HOME\""
  add_line "export PATH=\"\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH\""
  export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
  export ANDROID_HOME

  log "Componentes del SDK"
  yes | sdkmanager --licenses >/dev/null || true
  sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"
  flutter config --android-sdk "$ANDROID_HOME"
  yes | flutter doctor --android-licenses >/dev/null || true

  # Reglas para que adb vea el teléfono por USB sin sudo
  if [[ ! -f /etc/udev/rules.d/51-android.rules ]] && ! dpkg -s android-sdk-platform-tools-common >/dev/null 2>&1; then
    sudo apt-get install -y android-sdk-platform-tools-common || true
  fi
fi

# ---------------------------------------------------------------- proyecto
log "Preparando el proyecto"
cd "$ROOT"
python3 tool/configure.py

log "Revisión"
python3 tool/build.py doctor || true

echo
echo "Listo. Abre una terminal nueva (o: source $PROFILE) y compila con:"
echo "    python3 tool/build.py          # APK + instaladores de Linux en dist/"
echo "Convertidor a PDF para Android (opcional):"
echo "    python3 tool/libreoffice_android.py fetch    # si ya está subido al release de GitHub"
echo "    tool/build_libreoffice_android.sh --deps     # o compilarlo aquí (~40 GB, 1-4 h)"
