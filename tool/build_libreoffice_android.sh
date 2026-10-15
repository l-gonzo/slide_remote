#!/usr/bin/env bash
# Compila LibreOffice para Android (arm64) y mete el convertidor de presentaciones → PDF
# en el plugin de Slide Remote. Se corre UNA vez (y al actualizar LibreOffice).
#
#   tool/build_libreoffice_android.sh               # compilar e instalar en el plugin
#   tool/build_libreoffice_android.sh --deps        # además instala dependencias con apt
#   tool/build_libreoffice_android.sh --copy-only   # solo volver a copiar (ya compilado)
#
# Variables opcionales:
#   LO_DIR=~/libreoffice-android   dónde clonar/compilar (necesita ~40 GB libres)
#   LO_BRANCH=libreoffice-26-8     rama estable de LibreOffice
#   NDK_VERSION=27.2.12479018      NDK de Android (LibreOffice pide 27.x–29.x)
#   SLIM=0                         0 = componentes como la app oficial (recomendado); 1 = recorte experimental
#   JOBS=$(nproc)                  núcleos para compilar
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLUGIN="$ROOT/packages/slide_native/android/src/main"
LO_DIR=${LO_DIR:-$HOME/libreoffice-android}
LO_BRANCH=${LO_BRANCH:-libreoffice-26-8}
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}
NDK_VERSION=${NDK_VERSION:-27.2.12479018}
NDK="$SDK/ndk/$NDK_VERSION"
ABI=arm64-v8a
SLIM=${SLIM:-0}
JOBS=${JOBS:-$(nproc)}

DO_DEPS=0
COPY_ONLY=0
for a in "$@"; do
  case "$a" in
    --deps) DO_DEPS=1 ;;
    --copy-only) COPY_ONLY=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $a"; exit 1 ;;
  esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*"; exit 1; }

# Carpeta de la app Android dentro de LibreOffice (se renombró de source/ a app/ en master)
lo_app_dir() {
  if [[ -d "$LO_DIR/android/app" ]]; then echo "$LO_DIR/android/app"; else echo "$LO_DIR/android/source"; fi
}

# ---------------------------------------------------------------- 1. requisitos
if [[ $COPY_ONLY -eq 0 ]]; then
  [[ -d "$SDK" ]] || die "No encontré el SDK de Android en $SDK (define ANDROID_HOME)."

  mkdir -p "$(dirname "$LO_DIR")"
  free_gb=$(df -Pk "$(dirname "$LO_DIR")" | awk 'NR==2 {print int($4/1024/1024)}')
  if (( free_gb < 40 )); then
    warn "Solo hay ${free_gb} GB libres en $(dirname "$LO_DIR"); la compilación usa ~40 GB."
    read -r -p "¿Continuar de todos modos? [s/N] " ans; [[ "$ans" =~ ^[sS]$ ]] || exit 1
  fi

  if [[ $DO_DEPS -eq 1 ]]; then
    log "Instalando dependencias (pide sudo)"
    sudo apt-get update
    sudo apt-get install -y git build-essential zip unzip ccache autoconf automake libtool \
      pkg-config gperf bison flex nasm gettext xsltproc libxml2-utils libxml2-dev libxslt1-dev \
      zlib1g-dev python3 python3-dev openjdk-17-jdk ant junit4 libkrb5-dev graphviz \
      libnss3-dev libfontconfig1-dev
  fi

  if [[ ! -d "$NDK" ]]; then
    log "Instalando el NDK $NDK_VERSION"
    SDKMANAGER=$(command -v sdkmanager || true)
    [[ -z "$SDKMANAGER" && -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]] && SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"
    [[ -n "$SDKMANAGER" ]] || die "No encontré sdkmanager; instala el NDK $NDK_VERSION desde Android Studio."
    "$SDKMANAGER" "ndk;$NDK_VERSION"
  fi

  # -------------------------------------------------------------- 2. código de LibreOffice
  if [[ ! -d "$LO_DIR/.git" ]]; then
    log "Descargando LibreOffice ($LO_BRANCH)… (unos 2-3 GB)"
    git clone --depth 1 --branch "$LO_BRANCH" https://git.libreoffice.org/core "$LO_DIR" \
      || git clone --depth 1 --branch "$LO_BRANCH" https://github.com/LibreOffice/core.git "$LO_DIR"
  else
    log "Usando el código existente en $LO_DIR"
  fi

  APP=$(lo_app_dir)

  # -------------------------------------------------------------- 3. recortar a Impress + PDF
  if [[ $SLIM -eq 0 ]] && grep -q -- '-j -g core -g draw >' "$APP/Makefile"; then
    log "Restaurando la lista completa de componentes"
    sed -i -E 's/-j -g core -g draw >/-j -g core -g writer -g calc -g draw -g edit >/' "$APP/Makefile"
    rm -f "$APP/native-code.cxx"
  fi
  if [[ $SLIM -eq 1 ]]; then
    log "Modo reducido: solo los componentes de presentaciones y exportación a PDF"
    sed -i -E 's/-j -g core -g writer -g calc -g draw -g edit/-j -g core -g draw/' "$APP/Makefile"
    grep -q -- '-j -g core -g draw' "$APP/Makefile" || warn "No pude aplicar el recorte (cambió el Makefile); se compila completo."
    rm -f "$APP/native-code.cxx"
  fi

  # -------------------------------------------------------------- 4. configurar y compilar
  log "Configurando (arm64, NDK $NDK_VERSION)"
  {
    echo "--with-distro=LibreOfficeAndroidAarch64"
    echo "--with-android-sdk=$SDK"
    echo "--with-android-ndk=$NDK"
    echo "--with-parallelism=$JOBS"
    command -v ccache >/dev/null && echo "--enable-ccache"
  } > "$LO_DIR/autogen.input"
  (cd "$LO_DIR" && ./autogen.sh)

  log "Compilando LibreOffice para Android. Tarda de 1 a 4 horas según tu PC; puedes dejarlo solo."
  if ! (cd "$LO_DIR" && make); then
    # El último paso (el APK de ejemplo de LibreOffice, con su lint) puede fallar sin que importe:
    # lo que necesitamos son las bibliotecas y los assets, que se generan antes.
    if [[ -f "$LO_DIR/android/jniLibs/$ABI/liblo-native-code.so" && -d "$APP/assets/program" ]]; then
      warn "make terminó con error, pero el convertidor ya se generó. Continúo."
    else
      die "La compilación falló. Revisa el error de arriba (si falta un paquete, instálalo o usa --deps)."
    fi
  fi
fi

# ---------------------------------------------------------------- 5. copiar al plugin
APP=$(lo_app_dir)
JNI_SRC="$LO_DIR/android/jniLibs/$ABI"
[[ -f "$JNI_SRC/liblo-native-code.so" ]] || die "No existe $JNI_SRC/liblo-native-code.so. ¿Ya compilaste?"
[[ -d "$APP/assets/program" ]] || die "No existen los assets en $APP/assets. ¿Terminó la compilación?"

log "Copiando bibliotecas nativas ($ABI)"
rm -rf "$PLUGIN/jniLibs"
mkdir -p "$PLUGIN/jniLibs/$ABI"
cp "$JNI_SRC"/*.so "$PLUGIN/jniLibs/$ABI/"

log "Copiando archivos de LibreOffice (assets)"
rm -rf "$PLUGIN/assets"
mkdir -p "$PLUGIN/assets"
cp -r "$APP/assets/." "$PLUGIN/assets/"
[[ -d "$APP/assets_strippedUI" ]] && cp -r "$APP/assets_strippedUI/." "$PLUGIN/assets/"

# fontconfig guarda su caché en /data/data/<id de la app>/: usar el id de Slide Remote
APP_ID=$(sed -n -E 's/.*applicationId *= *"([^"]+)".*/\1/p' "$ROOT/android/app/build.gradle.kts" 2>/dev/null | head -1)
APP_ID=${APP_ID:-dev.lgonzo.slide_remote}
FONTS_CONF="$PLUGIN/assets/unpack/etc/fonts/fonts.conf"
if [[ -f "$FONTS_CONF" ]]; then
  sed -i -E "s#/data/data/[^/<]+/fontconfig#/data/data/$APP_ID/fontconfig#" "$FONTS_CONF"
fi

log "Actualizando las clases JNI de LibreOfficeKit (misma versión que las bibliotecas)"
KIT_DST="$PLUGIN/java/org/libreoffice/kit"
mkdir -p "$KIT_DST"
for f in LibreOfficeKit.java Office.java Document.java; do
  cp "$LO_DIR/android/Bootstrap/src/org/libreoffice/kit/$f" "$KIT_DST/$f"
done

# Licencia de LibreOffice (MPL 2.0): debe acompañar a la app
for lic in "$LO_DIR/instdir/LICENSE" "$LO_DIR/COPYING.MPL"; do
  if [[ -f "$lic" ]]; then cp "$lic" "$PLUGIN/assets/LIBREOFFICE-LICENSE.txt"; break; fi
done

so_mb=$(du -sm "$PLUGIN/jniLibs" | cut -f1)
as_mb=$(du -sm "$PLUGIN/assets" | cut -f1)
log "Listo: bibliotecas ${so_mb} MB + archivos ${as_mb} MB (sin comprimir)."
echo "    Ahora compila la app normalmente:  flutter build apk --release --split-per-abi"
echo "    El convertidor está en el APK arm64-v8a (todos los teléfonos actuales)."
echo "    Para usarlo en otras computadoras (Mac/Windows) súbelo una vez:  python3 tool/libreoffice_android.py upload"
