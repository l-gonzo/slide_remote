#!/usr/bin/env python3
"""
Sube a un Release de GitHub los instaladores que ya compilaste (los que haya).

    python3 tool/release.py              # release v<versión de pubspec.yaml>
    python3 tool/release.py --dry-run    # solo muestra qué subiría
    python3 tool/release.py --tag v2.0.1 --draft
    python3 tool/release.py --notes "Cambios: …"

Busca en dist/ (lo que crea tool/build.py) y, si no están ahí, en las carpetas de build/:
  Android  .apk / .aab      Linux  .deb / .tar.gz      Windows  .exe / .zip
  macOS    .dmg             iPhone .ipa
Si el release ya existe, agrega los archivos y reemplaza los que tengan el mismo nombre.
Necesita gh (GitHub CLI) con sesión iniciada: gh auth login. En Windows usa "py".
"""
import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass


def die(msg):
    print(f"[x] {msg}", file=sys.stderr)
    sys.exit(1)


def version():
    m = re.search(r"^version:\s*([0-9.]+)", (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
    return m.group(1) if m else "0.0.0"


def find_installers(v):
    """Lista de (sistema, archivo local, nombre con el que se sube)."""
    found = []
    seen = set()

    def add(system, path: Path, name=None):
        name = name or path.name
        if path.is_file() and name not in seen:
            seen.add(name)
            found.append((system, path, name))

    # 1) dist/ (tool/build.py y tool/package_*): ya tienen buen nombre
    patterns = [
        ("Android", "*.apk"), ("Android", "*.aab"),
        ("Linux", "*.deb"), ("Linux", "*linux*.tar.gz"),
        ("Windows", "*Setup*.exe"), ("Windows", "*windows*.zip"),
        ("macOS", "*.dmg"),
        ("iPhone", "*.ipa"),
    ]
    for system, pat in patterns:
        for f in sorted(DIST.glob(pat)):
            add(system, f)

    # 2) build/ (si compilaste con flutter directamente): se suben con nombre claro
    apk_dir = ROOT / "build/app/outputs/flutter-apk"
    for abi, label in [("arm64-v8a", "arm64"), ("armeabi-v7a", "armv7"), ("x86_64", "x86_64")]:
        add("Android", apk_dir / f"app-{abi}-release.apk", f"Zlide-{v}-android-{label}.apk")
    if not any(s == "Android" and n.endswith(".apk") for s, _, n in found):
        add("Android", apk_dir / "app-release.apk", f"Zlide-{v}-android.apk")
    add("Android", ROOT / "build/app/outputs/bundle/release/app-release.aab", f"Zlide-{v}-android.aab")
    for ipa in sorted((ROOT / "build/ios/ipa").glob("*.ipa")):
        add("iPhone", ipa, f"Zlide-{v}-ios.ipa")
    return found


def gh():
    exe = shutil.which("gh")
    if not exe:
        die("Falta gh (GitHub CLI): https://cli.github.com  y luego: gh auth login")
    return exe


def main():
    ap = argparse.ArgumentParser(description="Sube los instaladores a un Release de GitHub.")
    ap.add_argument("--tag", help="etiqueta del release (por defecto v<versión de pubspec.yaml>)")
    ap.add_argument("--title", help="título (por defecto 'Zlide <versión>')")
    ap.add_argument("--notes", help="texto del release (por defecto, notas generadas por GitHub)")
    ap.add_argument("--draft", action="store_true", help="crear como borrador (no se publica aún)")
    ap.add_argument("--prerelease", action="store_true", help="marcar como versión de prueba")
    ap.add_argument("--repo", help="owner/repo (por defecto, el del remoto origin)")
    ap.add_argument("--dry-run", action="store_true", help="solo mostrar qué se subiría")
    a = ap.parse_args()

    v = version()
    tag = a.tag or f"v{v}"
    files = find_installers(v)
    if not files:
        die("No encontré instaladores. Compílalos primero: python3 tool/build.py")

    print(f"Release {tag}:")
    for system, path, name in files:
        rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
        extra = f"  (desde {rel})" if name != path.name or path.parent != DIST else ""
        print(f"  {system:8} {path.stat().st_size / 1e6:7.1f} MB  {name}{extra}")
    missing = [s for s in ["Android", "Linux", "Windows", "macOS", "iPhone"] if s not in {f[0] for f in files}]
    if missing:
        print(f"  (sin: {', '.join(missing)})")
    if a.dry_run:
        return

    exe = gh()
    repo_args = ["--repo", a.repo] if a.repo else []

    with tempfile.TemporaryDirectory() as tmp:
        # Copias con el nombre final + SHA256SUMS.txt para verificar las descargas
        upload = []
        sums = []
        for _, path, name in files:
            dst = Path(tmp) / name
            shutil.copy2(path, dst)
            upload.append(str(dst))
            h = hashlib.sha256()
            with open(dst, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            sums.append(f"{h.hexdigest()}  {name}")
        sums_file = Path(tmp) / "SHA256SUMS.txt"
        sums_file.write_text("\n".join(sums) + "\n", encoding="utf-8")
        upload.append(str(sums_file))

        exists = subprocess.run([exe, "release", "view", tag, *repo_args], capture_output=True).returncode == 0
        if exists:
            print(f"\nEl release {tag} ya existe: agrego/reemplazo archivos…")
            cmd = [exe, "release", "upload", tag, *upload, "--clobber", *repo_args]
        else:
            print(f"\nCreando el release {tag}…")
            cmd = [exe, "release", "create", tag, *upload, *repo_args,
                   "--title", a.title or f"Zlide {v}"]
            cmd += ["--notes", a.notes] if a.notes else ["--generate-notes"]
            if a.draft:
                cmd.append("--draft")
            if a.prerelease:
                cmd.append("--prerelease")
        if subprocess.run(cmd, cwd=ROOT).returncode != 0:
            die("gh no pudo subir los archivos (¿gh auth login? ¿ya hiciste git push?).")

    url = subprocess.run([exe, "release", "view", tag, "--json", "url", "-q", ".url", *repo_args],
                         cwd=ROOT, capture_output=True, text=True).stdout.strip()
    print(f"Listo: release {tag} con {len(files)} instalador(es).")
    if url:
        print(f"  {url}")


if __name__ == "__main__":
    main()
