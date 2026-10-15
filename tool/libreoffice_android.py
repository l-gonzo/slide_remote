#!/usr/bin/env python3
"""
Comparte el convertidor de LibreOffice para Android entre computadoras (Linux, Mac y Windows).

LibreOffice para Android solo se puede COMPILAR en Linux (tool/build_libreoffice_android.sh),
pero el resultado (bibliotecas + archivos, ~100 MB) se puede subir una vez a un "release" de
GitHub y descargarlo desde cualquier sistema para compilar el APK completo.

    python3 tool/libreoffice_android.py fetch     # descargar e instalar en el plugin (cualquier SO)
    python3 tool/libreoffice_android.py status    # ¿está instalado?
    python3 tool/libreoffice_android.py pack      # (Linux, tras compilar) crear el .zip en dist/
    python3 tool/libreoffice_android.py upload    # pack + subir al release de GitHub (necesita gh)

Variables opcionales:
    SLIDE_REMOTE_REPO=l-gonzo/slide_remote   repositorio de GitHub (por defecto: el remoto "origin")
    LO_BRANCH=libreoffice-26-8              versión de LibreOffice (igual que el script de compilación)
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
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
PLUGIN = ROOT / "packages" / "slide_native" / "android" / "src" / "main"
PARTS = ["jniLibs", "assets"]
LO_BRANCH = os.environ.get("LO_BRANCH", "libreoffice-26-8")
VERSION = LO_BRANCH.replace("libreoffice-", "").replace("-", ".")  # 26.8
TAG = f"libreoffice-android-{VERSION}"
ASSET = f"libreoffice-android-arm64-{VERSION}.zip"
MARKER = PLUGIN / "assets" / ".libreoffice-android.json"


def log(msg):
    print(f"==> {msg}", flush=True)


def die(msg):
    print(f"[x] {msg}", file=sys.stderr)
    sys.exit(1)


def repo():
    env = os.environ.get("SLIDE_REMOTE_REPO")
    if env:
        return env
    try:
        url = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout.strip()
        m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", url)
        if m:
            return m.group(1)
    except Exception:
        pass
    return "l-gonzo/slide_remote"


def installed():
    return (PLUGIN / "jniLibs" / "arm64-v8a" / "liblo-native-code.so").is_file() and \
        (PLUGIN / "assets" / "program").is_dir()


def gh():
    return shutil.which("gh")


# ---------------------------------------------------------------- status

def cmd_status():
    if not installed():
        print("LibreOffice para Android: NO instalado.")
        print("  Descárgalo:  python3 tool/libreoffice_android.py fetch")
        print("  o compílalo en Linux:  tool/build_libreoffice_android.sh")
        return 1
    info = {}
    if MARKER.is_file():
        info = json.loads(MARKER.read_text(encoding="utf-8"))
    size = sum(f.stat().st_size for p in PARTS for f in (PLUGIN / p).rglob("*") if f.is_file())
    print(f"LibreOffice para Android: instalado ({size / 1e6:.0f} MB, versión {info.get('version', '?')}).")
    return 0


# ---------------------------------------------------------------- pack / upload

def cmd_pack():
    if not installed():
        die("No hay nada que empaquetar: primero compila con tool/build_libreoffice_android.sh")
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    out = dist / ASSET
    MARKER.write_text(json.dumps({"version": VERSION, "branch": LO_BRANCH}), encoding="utf-8")
    log(f"Empaquetando {out.relative_to(ROOT)}")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for part in PARTS:
            for f in sorted((PLUGIN / part).rglob("*")):
                if f.is_file():
                    z.write(f, f.relative_to(PLUGIN).as_posix())
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    (dist / (ASSET + ".sha256")).write_text(f"{digest}  {ASSET}\n", encoding="utf-8")
    log(f"Listo: {out.stat().st_size / 1e6:.0f} MB  (sha256 {digest[:16]}…)")
    return out


def cmd_upload():
    out = cmd_pack()
    if not gh():
        die("Falta gh (GitHub CLI). Instálalo y ejecuta: gh auth login")
    r = repo()
    sha = out.with_name(out.name + ".sha256")
    exists = subprocess.run([gh(), "release", "view", TAG, "--repo", r],
                            capture_output=True).returncode == 0
    if exists:
        log(f"Actualizando el release {TAG} en {r}")
        subprocess.run([gh(), "release", "upload", TAG, str(out), str(sha), "--clobber", "--repo", r], check=True)
    else:
        log(f"Creando el release {TAG} en {r}")
        subprocess.run([gh(), "release", "create", TAG, str(out), str(sha), "--repo", r,
                        "--title", f"LibreOffice {VERSION} para Android (convertidor)",
                        "--notes", "Bibliotecas y archivos de LibreOffice para el convertidor a PDF de "
                                   "Slide Remote en Android. Se instalan con "
                                   "`python3 tool/libreoffice_android.py fetch`. Licencia MPL 2.0."],
                       check=True)
    log("Subido. En cualquier computadora: python3 tool/libreoffice_android.py fetch")


# ---------------------------------------------------------------- fetch

def download(dest: Path):
    r = repo()
    # 1) gh: funciona también con repositorios privados
    if gh():
        res = subprocess.run([gh(), "release", "download", TAG, "--repo", r, "--pattern", ASSET,
                              "--dir", str(dest.parent), "--clobber"])
        if res.returncode == 0 and dest.is_file():
            return
        print("    (gh no pudo descargarlo; intento directo)")
    # 2) descarga directa (repositorio público)
    url = f"https://github.com/{r}/releases/download/{TAG}/{ASSET}"
    log(f"Descargando {url}")
    try:
        with urllib.request.urlopen(url) as resp, open(dest, "wb") as f:
            total = int(resp.headers.get("Content-Length") or 0)
            done = 0
            while True:
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                if total:
                    print(f"\r    {done / 1e6:.0f} / {total / 1e6:.0f} MB", end="", flush=True)
        print()
    except Exception as e:
        die(f"No se pudo descargar ({e}).\n"
            f"    ¿Ya se subió? En Linux, tras compilar: python3 tool/libreoffice_android.py upload\n"
            f"    Si el repositorio es privado, instala gh y ejecuta: gh auth login")


def cmd_fetch():
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / ASSET
        download(dest)
        log("Instalando en el plugin")
        for part in PARTS:
            shutil.rmtree(PLUGIN / part, ignore_errors=True)
        with zipfile.ZipFile(dest) as z:
            for name in z.namelist():
                if name.startswith("/") or ".." in Path(name).parts:
                    die(f"Ruta inválida en el zip: {name}")
            z.extractall(PLUGIN)
    if not installed():
        die("El archivo descargado no trae el convertidor completo.")
    cmd_status()
    print("Ahora: python3 tool/configure.py  y  flutter build apk --release --split-per-abi")
    return 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    actions = {"fetch": cmd_fetch, "status": cmd_status, "pack": cmd_pack, "upload": cmd_upload}
    if cmd not in actions:
        print(__doc__)
        sys.exit(2)
    res = actions[cmd]()
    sys.exit(res if isinstance(res, int) else 0)


if __name__ == "__main__":
    main()
