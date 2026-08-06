# -*- coding: utf-8 -*-
"""Verifie une installation CircusVOIP client produite par l'installeur.

A executer AVEC LE RUNTIME EMBARQUE de l'installation a tester, pas avec un
Python systeme -- c'est justement ce runtime qu'on veut valider :

    <InstallDir>\\runtime\\python.exe installer\\smoke-test.py <InstallDir>

Controles :
  1. presence des fichiers que les raccourcis et le code attendent ;
  2. circusvoip_version.json lisible (tolerant au BOM, comme le client) ;
  3. compilation de toutes les sources embarquees par ce CPython ;
  4. import des dependances ;
  5. creation d'une QApplication (valide le plugin de plateforme Qt, que
     l'elagage du runtime pourrait casser).

Sortie 0 si tout ce qui est obligatoire passe, 1 sinon. Les dependances
optionnelles (sounddevice, pytesseract, pynvml, bettercam) sont signalees mais
ne font pas echouer : le client les enveloppe toutes dans un try/except, et
sounddevice ouvre PortAudio des l'import, ce qui est peu fiable sur une VM
sans carte son.

N'importe PAS circusvoip_client : son bootstrap pip declencherait le
telechargement d'easyocr + torch (~2 Go).
"""

import json
import subprocess
import sys
from pathlib import Path

REQUIRED_FILES = [
    r"runtime\python.exe",
    r"runtime\pythonw.exe",
    r"app\circusvoip_client.py",
    r"app\circusvoip_core.py",
    r"app\circusvoip_audio_io.py",
    r"app\circusvoip_sc_ocr.py",
    r"app\circusvoip_security.py",
    r"app\circusvoip_audio_rx_logger.py",
    # Console d'administration : vient de server\ dans le depot, mais est
    # livree avec le client (cf. client.iss). Un oubli du build ne se verrait
    # qu'au clic sur son raccourci.
    r"app\circusvoip_admin.py",
    r"app\circusvoip_version.json",
]

REQUIRED_MODULES = [
    "PySide6.QtWidgets", "PySide6.QtGui", "PySide6.QtCore",
    "numpy", "cv2", "mss", "pynput", "psutil",
    "websockets", "cryptography", "PIL.Image",
    # Interface de la console d'administration. Le runtime ne l'elague plus
    # depuis qu'elle est livree avec le client.
    "tkinter",
]

OPTIONAL_MODULES = ["sounddevice", "pytesseract", "pynvml", "bettercam"]

_failures = []


def check(label, ok, detail=""):
    print(f"  {'OK    ' if ok else 'ECHEC '} {label}{(' : ' + detail) if detail else ''}")
    if not ok:
        _failures.append(label)
    return ok


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: smoke-test.py <dossier_installation>")
        return 2
    root = Path(sys.argv[1]).resolve()
    print(f"[SMOKE] Installation : {root}")
    print(f"[SMOKE] Runtime      : {sys.executable}")
    print(f"[SMOKE] Python       : {sys.version.split()[0]}")

    if not root.is_dir():
        print(f"[SMOKE] Dossier introuvable : {root}")
        return 1

    print("\n[SMOKE] Fichiers")
    for rel in REQUIRED_FILES:
        check(rel, (root / rel).exists())

    print("\n[SMOKE] Version")
    try:
        # utf-8-sig : meme tolerance que _load_version_info cote client.
        data = json.loads(
            (root / "app" / "circusvoip_version.json").read_text(encoding="utf-8-sig")
        )
        check("circusvoip_version.json",
              bool(data.get("version")),
              f"{data.get('version')} {data.get('channel')} {data.get('build')}")
    except Exception as e:
        check("circusvoip_version.json", False, f"{type(e).__name__}: {e}")

    print("\n[SMOKE] Compilation des sources embarquees")
    sources = sorted((root / "app").glob("*.py"))
    if not sources:
        check("sources .py", False, "aucun fichier trouve")
    else:
        proc = subprocess.run(
            [sys.executable, "-m", "py_compile"] + [str(p) for p in sources],
            capture_output=True, text=True,
        )
        check(f"py_compile ({len(sources)} modules)", proc.returncode == 0,
              proc.stderr.strip()[:300])

    print("\n[SMOKE] Dependances obligatoires")
    import importlib
    for mod in REQUIRED_MODULES:
        try:
            importlib.import_module(mod)
            check(mod, True)
        except Exception as e:
            check(mod, False, f"{type(e).__name__}: {e}")

    print("\n[SMOKE] Dependances optionnelles (non bloquantes)")
    for mod in OPTIONAL_MODULES:
        try:
            importlib.import_module(mod)
            print(f"  OK     {mod}")
        except Exception as e:
            print(f"  absent {mod} : {type(e).__name__}: {e}")

    print("\n[SMOKE] Qt")
    try:
        from PySide6.QtWidgets import QApplication
        QApplication([])
        check("QApplication (plugin de plateforme charge)", True)
    except Exception as e:
        check("QApplication", False, f"{type(e).__name__}: {e}")

    print("\n[SMOKE] pip (indispensable au bootstrap du premier lancement)")
    proc = subprocess.run([sys.executable, "-m", "pip", "--version"],
                          capture_output=True, text=True)
    check("pip", proc.returncode == 0, proc.stdout.strip()[:120])

    print()
    if _failures:
        print(f"[SMOKE] ECHEC : {len(_failures)} controle(s) -> {', '.join(_failures)}")
        return 1
    print("[SMOKE] Tout est OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
