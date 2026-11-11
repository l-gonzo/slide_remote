#!/usr/bin/env python3
"""
Compila Zlide y deja los instaladores en dist/. Funciona igual en Linux, macOS y Windows.

    python3 tool/build.py            # todo lo que se puede compilar en esta computadora
    python3 tool/build.py android    # APK (cualquier sistema)
    python3 tool/build.py play       # .aab firmado para Google Play (cualquier sistema)
    python3 tool/build.py linux      # .deb + .tar.gz   (solo en Linux)
    python3 tool/build.py windows    # .exe + .zip      (solo en Windows)
    python3 tool/build.py macos      # .dmg             (solo en macOS)
    python3 tool/build.py ios        # .ipa             (solo en macOS, con cuenta de Apple)
    python3 tool/build.py doctor     # revisa qué falta

En Windows usa "py" en lugar de "python3".
"""
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Consola de Windows: UTF-8 y colores
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
        os.system("")
    except Exception:
        pass
DIST = ROOT / "dist"
HOST = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}.get(platform.system(), "?")
PY = sys.executable


def log(msg):
    print(f"\n\033[1;32m==>\033[0m {msg}", flush=True)


def warn(msg):
    print(f"\033[1;33m[!]\033[0m {msg}", flush=True)


def die(msg):
    print(f"\033[1;31m[x]\033[0m {msg}", file=sys.stderr)
    sys.exit(1)


def tool(name):
    return shutil.which(name)


def run(cmd, **kw):
    exe = tool(cmd[0]) or cmd[0]
    print("   $ " + " ".join(str(c) for c in cmd), flush=True)
    r = subprocess.run([exe, *[str(c) for c in cmd[1:]]], cwd=ROOT, **kw)
    if r.returncode != 0:
        die(f"Falló: {' '.join(str(c) for c in cmd)}")
    return r


def version():
    m = re.search(r"^version:\s*([0-9.]+)", (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
    return m.group(1) if m else "0.0.0"


def build_number():
    m = re.search(r"^version:\s*[0-9.]+\+(\d+)", (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
    return m.group(1) if m else "?"


def signing_key():
    """La llave de subida de Play según android/key.properties: (archivo .jks, problema o None)."""
    props = ROOT / "android/key.properties"
    if not props.is_file():
        return None, "falta android/key.properties"
    vals = dict(l.split("=", 1) for l in props.read_text(encoding="utf-8").splitlines() if "=" in l)
    store = vals.get("storeFile", "").strip()
    path = Path(store) if Path(store).is_absolute() else ROOT / "android/app" / store
    if not store or not path.is_file():
        return None, f"android/key.properties apunta a una llave que no existe ({store or 'sin storeFile'})"
    return path, None


def ensure_configured(platform_dir):
    if not (ROOT / platform_dir).is_dir() or not (ROOT / ".dart_tool").is_dir():
        log("Preparando el proyecto (tool/configure.py)")
        run([PY, "tool/configure.py"])


def fix_converter_app_id():
    """El convertidor de LibreOffice tiene escrito el paquete de la app (caché de fuentes):
    que coincida con el applicationId actual antes de compilar."""
    sys.path.insert(0, str(ROOT / "tool"))
    try:
        import libreoffice_android
        if libreoffice_android.fix_fonts_conf():
            print(f"   Convertidor: caché de fuentes en /data/data/{libreoffice_android.app_id()}/")
    finally:
        sys.path.pop(0)


# ---------------------------------------------------------------- objetivos

def build_android():
    ensure_configured("android")
    fix_converter_app_id()
    lo = (ROOT / "packages/slide_native/android/src/main/jniLibs/arm64-v8a/liblo-native-code.so").is_file()
    if not lo:
        warn("Sin LibreOffice: el APK funciona, pero no convierte presentaciones en el modo Navegador.\n"
             "    Para incluirlo: python3 tool/libreoffice_android.py fetch")
    log("Android: APK")
    run(["flutter", "build", "apk", "--release", "--split-per-abi"])
    DIST.mkdir(exist_ok=True)
    out = ROOT / "build/app/outputs/flutter-apk"
    v = version()
    copied = []
    for abi, label in [("arm64-v8a", "arm64"), ("armeabi-v7a", "armv7"), ("x86_64", "x86_64")]:
        src = out / f"app-{abi}-release.apk"
        if src.is_file():
            dst = DIST / f"Zlide-{v}-android-{label}.apk"
            shutil.copy2(src, dst)
            copied.append(dst)
    for f in copied:
        print(f"   {f.stat().st_size / 1e6:6.1f} MB  {f.relative_to(ROOT)}")
    print("   Instala el de arm64 (casi todos los teléfonos): adb install -r dist/"
          f"Zlide-{v}-android-arm64.apk")


def build_play():
    """App Bundle firmado con la llave de subida (android/key.properties), listo para Play Console."""
    ensure_configured("android")
    fix_converter_app_id()
    key, problem = signing_key()
    if problem:
        die(f"No se puede firmar para Google Play: {problem}.\n"
            "    Play rechaza lo firmado con la llave de depuración. Crea tu llave de subida\n"
            "    (README → \"Firma propia\") y vuelve a intentarlo.")
    lo = (ROOT / "packages/slide_native/android/src/main/jniLibs/arm64-v8a/liblo-native-code.so").is_file()
    if not lo:
        warn("Sin LibreOffice: la app de Play NO convertiría presentaciones en «Transmitir desde móvil».\n"
             "    Para incluirlo: python3 tool/libreoffice_android.py fetch")
    v, n = version(), build_number()
    log(f"Google Play: .aab {v} (número de compilación {n}), firmado con {key}")
    run(["flutter", "build", "appbundle", "--release"])
    src = ROOT / "build/app/outputs/bundle/release/app-release.aab"
    DIST.mkdir(exist_ok=True)
    dst = DIST / f"Zlide-{v}-play.aab"
    shutil.copy2(src, dst)
    print(f"   {dst.stat().st_size / 1e6:6.1f} MB  {dst.relative_to(ROOT)}")
    print(f"   Súbelo en Play Console → Versiones. Play no acepta repetir el número de compilación ({n}):\n"
          "   para la siguiente actualización sube la versión en pubspec.yaml (por ejemplo 2.6.4+12).")


def build_linux():
    if HOST != "linux":
        die("La app de Linux solo se compila en Linux.")
    ensure_configured("linux")
    log("Linux: .deb y .tar.gz")
    run(["bash", "tool/package_linux.sh"])


def build_windows():
    if HOST != "windows":
        die("La app de Windows solo se compila en Windows.")
    ensure_configured("windows")
    log("Windows: instalador .exe y .zip")
    run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tool\\package_windows.ps1"])


def build_macos():
    if HOST != "macos":
        die("La app de Mac solo se compila en una Mac.")
    ensure_configured("macos")
    log("macOS: .dmg")
    run(["bash", "tool/package_macos.sh"])


def build_ios():
    if HOST != "macos":
        die("La app de iPhone solo se compila en una Mac.")
    ensure_configured("ios")
    log("iPhone: .ipa (necesita tu equipo de Apple configurado en Xcode)")
    method = os.environ.get("IOS_EXPORT_METHOD", "ad-hoc")  # ad-hoc | app-store | development
    r = subprocess.run([tool("flutter") or "flutter", "build", "ipa", "--release", f"--export-method={method}"],
                       cwd=ROOT)
    if r.returncode != 0:
        warn("No se pudo crear el .ipa (¿falta la firma? Abre ios/Runner.xcworkspace → Signing & Capabilities).\n"
             "    Para instalar en tu iPhone sin .ipa: flutter run --release -d <id del iPhone>")
        return
    DIST.mkdir(exist_ok=True)
    for ipa in (ROOT / "build/ios/ipa").glob("*.ipa"):
        dst = DIST / f"Zlide-{version()}-ios.ipa"
        shutil.copy2(ipa, dst)
        print(f"   {dst.relative_to(ROOT)}")


# ---------------------------------------------------------------- doctor

def doctor():
    ok = True

    def check(cond, good, bad):
        nonlocal ok
        print(("  ✔ " if cond else "  ✘ ") + (good if cond else bad))
        ok &= bool(cond)

    print(f"Sistema: {HOST}")
    flutter = tool("flutter")
    check(flutter, f"Flutter: {flutter}", "Falta Flutter (corre tool/setup_linux.sh, setup_macos.sh o setup_windows.ps1)")
    check(tool("git"), "git", "Falta git")
    java = tool("java")
    check(java or os.environ.get("JAVA_HOME"), "Java (para Android)", "Falta Java 17 (para compilar Android)")
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    check(sdk or tool("adb"), "SDK de Android", "Falta el SDK de Android (o define ANDROID_HOME)")
    lo = (ROOT / "packages/slide_native/android/src/main/jniLibs/arm64-v8a/liblo-native-code.so").is_file()
    print(("  ✔ " if lo else "  · ") + ("LibreOffice para Android instalado" if lo else
          "LibreOffice para Android no instalado (opcional): python3 tool/libreoffice_android.py fetch"))
    key, problem = signing_key()
    print(("  ✔ " if key else "  · ") + (f"Llave de subida de Google Play: {key}" if key else
          f"Sin llave de subida de Google Play ({problem}); solo hace falta para «build.py play»"))
    if HOST == "linux":
        check(tool("clang") and tool("cmake") and tool("ninja"), "Compilador para Linux",
              "Falta clang/cmake/ninja (sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev)")
        check(tool("dpkg-deb"), "dpkg-deb (.deb)", "Falta dpkg-deb")
    if HOST == "macos":
        check(tool("xcodebuild"), "Xcode", "Falta Xcode (App Store)")
        check(tool("pod"), "CocoaPods", "Falta CocoaPods (brew install cocoapods)")
    if HOST == "windows":
        iscc = tool("iscc") or any(Path(p).is_file() for p in [
            os.path.expandvars(r"%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"),
            os.path.expandvars(r"%ProgramFiles%\Inno Setup 6\ISCC.exe"),
            os.path.expandvars(r"%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe")])
        check(iscc, "Inno Setup (instalador .exe)", "Falta Inno Setup (winget install JRSoftware.InnoSetup)")
    if flutter:
        print("\nflutter doctor:")
        subprocess.run([flutter, "doctor"], cwd=ROOT)
    return 0 if ok else 1


def main():
    targets = sys.argv[1:] or ["all"]
    os.chdir(ROOT)
    if targets == ["doctor"]:
        sys.exit(doctor())
    if not tool("flutter"):
        die("No encontré flutter en el PATH. Corre el script de preparación de tu sistema (tool/setup_*).")
    if "all" in targets:
        targets = ["android", HOST]
        if HOST == "macos":
            targets.append("ios")
    actions = {"android": build_android, "play": build_play, "linux": build_linux, "windows": build_windows,
               "macos": build_macos, "ios": build_ios}
    for t in targets:
        if t not in actions:
            print(__doc__)
            sys.exit(2)
    for t in targets:
        actions[t]()
    log(f"Listo. Archivos en {DIST}")


if __name__ == "__main__":
    main()
