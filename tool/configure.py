#!/usr/bin/env python3
"""
Genera las carpetas de plataforma de Flutter y les aplica la configuración de Slide Remote.

    python3 tool/configure.py

Se puede volver a ejecutar sin problema (es idempotente). Hace:
  1. flutter create (solo agrega lo que falta; no toca lib/ ni pubspec.yaml)
  2. permisos y textos en Info.plist (iOS/macOS), entitlements de macOS (sin sandbox, Bluetooth)
  3. versión mínima iOS 14 / macOS 10.15
  4. nombre "Slide Remote" y tamaño de ventana en escritorio
  5. flutter pub get + íconos
"""
import os
import plistlib
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
PLATFORMS = "android,ios,macos,windows,linux"
APP_NAME = "Slide Remote"
BONJOUR = ["_slideremote._udp"]

# iOS solo muestra un texto por permiso (sin archivos .lproj en el proyecto): va en los dos idiomas.
BT_TEXT = ("Slide Remote uses Bluetooth to change your presentation slides. / "
           "Slide Remote usa Bluetooth para cambiar las diapositivas de tu presentación.")
LAN_TEXT = ("Slide Remote uses the local network to find your computer and show your presentation. / "
            "Slide Remote usa la red local para encontrar tu computadora y proyectar tu presentación.")
# Idiomas de la app (para que iOS/macOS muestren sus diálogos del sistema en el idioma correcto)
LOCALIZATIONS = ["en", "es"]


def log(msg):
    print(f"\033[1;32m==>\033[0m {msg}")


def warn(msg):
    print(f"\033[1;33m[!]\033[0m {msg}")


def run(cmd, check=True):
    exe = shutil.which(cmd[0])
    if exe is None:
        sys.exit(f"No se encontró '{cmd[0]}' en el PATH. Instala Flutter: https://docs.flutter.dev/get-started/install")
    return subprocess.run([exe, *cmd[1:]], cwd=ROOT, check=check)


def edit_text(path: Path, fn):
    if not path.exists():
        return False
    old = path.read_text(encoding="utf-8")
    new = fn(old)
    if new != old:
        path.write_text(new, encoding="utf-8")
    return True


def edit_plist(path: Path, fn):
    if not path.exists():
        return False
    with path.open("rb") as f:
        data = plistlib.load(f)
    fn(data)
    with path.open("wb") as f:
        plistlib.dump(data, f)
    return True


def raise_min_version(text, key, minimum):
    def repl(m):
        try:
            current = tuple(int(x) for x in m.group(2).split("."))
            wanted = tuple(int(x) for x in minimum.split("."))
        except ValueError:
            return m.group(0)
        return m.group(0) if current >= wanted else f"{m.group(1)}{minimum};"
    return re.sub(rf"({key} = )([0-9.]+);", repl, text)


def main():
    os.chdir(ROOT)

    # ------------------------------------------------------------------ 1. flutter create
    log("Generando carpetas de plataforma (flutter create)")
    run(["flutter", "create", "--org", "dev.lgonzo", "--project-name", "slide_remote",
         "--platforms", PLATFORMS, "."])

    test = ROOT / "test" / "widget_test.dart"
    if test.exists() and "MyApp" in test.read_text(encoding="utf-8"):
        test.unlink()  # la prueba de ejemplo no aplica a esta app

    # ------------------------------------------------------------------ 2. Android
    log("Android: nombre de la app y empaquetado del convertidor (LibreOffice)")
    edit_text(ROOT / "android/app/src/main/AndroidManifest.xml",
              lambda s: re.sub(r'android:label="[^"]*"', f'android:label="{APP_NAME}"', s, count=1))

    def gradle_packaging(s):
        if "useLegacyPackaging" not in s:
            block = (
                "android {\n"
                "    // LibreOffice (convertidor a PDF): bibliotecas nativas comprimidas en el APK y\n"
                "    // extraídas al instalar, como espera LibreOfficeKit.\n"
                "    packaging {\n"
                "        jniLibs {\n"
                "            useLegacyPackaging = true\n"
                "            pickFirsts += listOf(\"**/libc++_shared.so\")\n"
                "        }\n"
                "    }\n"
            )
            s = re.sub(r"^android \{\n", block, s, count=1, flags=re.M)
        # Versiones anteriores agregaban "noCompress" (no comprimir NADA en el APK). No hace
        # falta —LibreOffice lee sus assets con AAssetManager— y triplicaba el tamaño: quitarlo.
        s = re.sub(
            r"    // LibreOffice lee sus archivos directo del APK[^\n]*\n"
            r"    androidResources \{\n\s*noCompress \+= listOf\(\"\"\)\n\s*\}\n",
            "", s)
        return s

    edit_text(ROOT / "android/app/build.gradle.kts", gradle_packaging)

    def gradle_signing(s):
        # Firma propia si existe android/key.properties (ver README); si no, la de depuración.
        # Versión anterior: "java.util.Properties()" dentro de android { } no compila (ahí `java`
        # es otra cosa). Se cambia por Properties() con import arriba.
        if "java.util.Properties()" in s:
            s = s.replace("java.util.Properties()", "Properties()")
        if "Properties()" in s and "import java.util.Properties" not in s:
            s = "import java.util.Properties\n\n" + s
        if "key.properties" in s or "    buildTypes {" not in s:
            return s
        block = (
            "    signingConfigs {\n"
            "        create(\"release\") {\n"
            "            val f = rootProject.file(\"key.properties\")\n"
            "            if (f.exists()) {\n"
            "                val p = Properties().apply { f.inputStream().use { load(it) } }\n"
            "                keyAlias = p.getProperty(\"keyAlias\")\n"
            "                keyPassword = p.getProperty(\"keyPassword\")\n"
            "                storeFile = file(p.getProperty(\"storeFile\"))\n"
            "                storePassword = p.getProperty(\"storePassword\")\n"
            "            }\n"
            "        }\n"
            "    }\n\n"
            "    buildTypes {"
        )
        s = s.replace("    buildTypes {", block, 1)
        if "import java.util.Properties" not in s:
            s = "import java.util.Properties\n\n" + s
        s = s.replace(
            'signingConfig = signingConfigs.getByName("debug")',
            'signingConfig = signingConfigs.getByName(\n'
            '                if (rootProject.file("key.properties").exists()) "release" else "debug")',
            1)
        return s

    edit_text(ROOT / "android/app/build.gradle.kts", gradle_signing)

    # ------------------------------------------------------------------ 3. iOS
    log("iOS: permisos, Bonjour y versión mínima 14.0")

    def ios_plist(d):
        d["CFBundleDisplayName"] = APP_NAME
        d["CFBundleLocalizations"] = LOCALIZATIONS
        d["NSBluetoothAlwaysUsageDescription"] = BT_TEXT
        d["NSBluetoothPeripheralUsageDescription"] = BT_TEXT
        d["NSLocalNetworkUsageDescription"] = LAN_TEXT
        d["NSBonjourServices"] = BONJOUR
        d["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]
        d["UIStatusBarStyle"] = "UIStatusBarStyleLightContent"

    edit_plist(ROOT / "ios/Runner/Info.plist", ios_plist)
    edit_text(ROOT / "ios/Podfile",
              lambda s: re.sub(r"^#?\s*platform :ios, '[0-9.]+'", "platform :ios, '14.0'", s, count=1, flags=re.M))
    edit_text(ROOT / "ios/Runner.xcodeproj/project.pbxproj",
              lambda s: raise_min_version(s, "IPHONEOS_DEPLOYMENT_TARGET", "14.0"))

    # ------------------------------------------------------------------ 4. macOS
    log("macOS: Bluetooth, red local, sin sandbox (necesario para presionar teclas)")

    def mac_plist(d):
        d["CFBundleLocalizations"] = LOCALIZATIONS
        d["NSBluetoothAlwaysUsageDescription"] = BT_TEXT
        d["NSLocalNetworkUsageDescription"] = LAN_TEXT
        d["NSBonjourServices"] = BONJOUR

    edit_plist(ROOT / "macos/Runner/Info.plist", mac_plist)

    def mac_entitlements(d):
        d["com.apple.security.app-sandbox"] = False
        d["com.apple.security.network.client"] = True
        d["com.apple.security.network.server"] = True
        d["com.apple.security.device.bluetooth"] = True

    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        edit_plist(ROOT / "macos/Runner" / name, mac_entitlements)
    edit_text(ROOT / "macos/Podfile",
              lambda s: re.sub(r"^#?\s*platform :osx, '[0-9.]+'", "platform :osx, '10.15'", s, count=1, flags=re.M))
    edit_text(ROOT / "macos/Runner.xcodeproj/project.pbxproj",
              lambda s: raise_min_version(s, "MACOSX_DEPLOYMENT_TARGET", "10.15"))
    edit_text(ROOT / "macos/Runner/Configs/AppInfo.xcconfig",
              lambda s: re.sub(r"^PRODUCT_NAME = .*$", f"PRODUCT_NAME = {APP_NAME}", s, flags=re.M))

    # ------------------------------------------------------------------ 5. Windows / Linux
    log("Windows y Linux: título y tamaño de ventana")
    edit_text(ROOT / "windows/runner/main.cpp", lambda s: s
              .replace('window.Create(L"slide_remote"', f'window.Create(L"{APP_NAME}"')
              .replace("Win32Window::Size size(1280, 720);", "Win32Window::Size size(640, 820);"))
    edit_text(ROOT / "linux/runner/my_application.cc", lambda s: s
              .replace('"slide_remote"', f'"{APP_NAME}"')
              .replace("gtk_window_set_default_size(window, 1280, 720);",
                       "gtk_window_set_default_size(window, 640, 820);"))

    # ------------------------------------------------------------------ 6. paquetes e íconos
    log("Descargando paquetes (flutter pub get)")
    run(["flutter", "pub", "get"])
    log("Generando íconos")
    if run(["dart", "run", "flutter_launcher_icons"], check=False).returncode != 0:
        warn("No se pudieron generar los íconos (no es grave; la app usa el ícono de Flutter).")

    print()
    log("Listo. Ejemplos:")
    print("    flutter run -d android       # teléfono Android conectado")
    print("    flutter build apk --release  # APK para instalar")
    print("    flutter run -d linux         # app de escritorio en esta PC")
    print("    flutter run -d macos | windows | ios   (cada una en su sistema)")


if __name__ == "__main__":
    main()
