#!/usr/bin/env bash
# Prepara una Mac desde cero para compilar Slide Remote (app de Mac, iPhone y, opcional, Android).
#
#   bash tool/setup_macos.sh              # Mac + iPhone
#   bash tool/setup_macos.sh --android    # además Java 17 y el SDK de Android
#
# Antes: instala Xcode desde la App Store y ábrelo una vez.
# Se puede volver a correr: salta lo que ya está instalado.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FLUTTER_DIR=${FLUTTER_DIR:-$HOME/flutter}
WITH_ANDROID=0
[[ "${1:-}" == "--android" ]] && WITH_ANDROID=1
PROFILE="$HOME/.zshrc"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*"; exit 1; }
add_line() { grep -qxF "$1" "$PROFILE" 2>/dev/null || echo "$1" >> "$PROFILE"; }

# ---------------------------------------------------------------- Xcode
log "Xcode"
[[ -d /Applications/Xcode.app ]] || die "Instala Xcode desde la App Store, ábrelo una vez y vuelve a correr este script."
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS || true

# ---------------------------------------------------------------- Homebrew
if ! command -v brew >/dev/null; then
  log "Instalando Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"; add_line 'eval "$(/opt/homebrew/bin/brew shellenv)"'; fi
  if [[ -x /usr/local/bin/brew ]]; then eval "$(/usr/local/bin/brew shellenv)"; fi
fi
log "git, Python y CocoaPods"
brew install git python cocoapods

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

# ---------------------------------------------------------------- Android (opcional)
if [[ $WITH_ANDROID -eq 1 ]]; then
  log "Java 17 y SDK de Android"
  brew install --cask temurin@17 android-commandlinetools
  ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
  add_line "export ANDROID_HOME=\"$ANDROID_HOME\""
  add_line "export PATH=\"\$ANDROID_HOME/platform-tools:\$PATH\""
  export ANDROID_HOME PATH="$ANDROID_HOME/platform-tools:$PATH"
  yes | sdkmanager --licenses >/dev/null || true
  sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"
  flutter config --android-sdk "$ANDROID_HOME"
  yes | flutter doctor --android-licenses >/dev/null || true
fi

# ---------------------------------------------------------------- proyecto
log "Preparando el proyecto"
cd "$ROOT"
python3 tool/configure.py
(cd ios && pod install --repo-update) || true
(cd macos && pod install) || true

log "Revisión"
python3 tool/build.py doctor || true

echo
echo "Listo. Abre una terminal nueva y compila con:"
echo "    python3 tool/build.py macos     # dist/SlideRemote-<versión>-macos.dmg"
echo "    python3 tool/build.py ios       # .ipa (necesita tu equipo en Xcode: open ios/Runner.xcworkspace)"
[[ $WITH_ANDROID -eq 1 ]] && echo "    python3 tool/build.py android   # APK"
echo "Para instalar en tu iPhone sin .ipa: flutter run --release -d <id>  (ver: flutter devices)"
