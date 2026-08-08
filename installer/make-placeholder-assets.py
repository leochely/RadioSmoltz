# -*- coding: utf-8 -*-
"""Genere les assets binaires manquants du payload client.

Les assets d'origine (RadioSmoltz.ico, sounds/*.wav) ne sont pas versionnes
dans le depot : `client/sounds/` est meme dans .gitignore. Ce script cree des
remplacants neutres pour que l'installeur produise une application complete,
sans jamais ecraser un fichier existant.

Ce qui est genere, et pourquoi :

  <icone>.ico      Icone de fenetre / barre des taches. Le client l'ignore
                   silencieusement si absente, mais Inno Setup s'en sert
                   aussi comme icone de l'installeur et des raccourcis, et
                   les lanceurs serveur l'embarquent au moment de leur
                   compilation. Cf. --icon-name.
  sounds/alarm.wav Son du soundboard. SEUL asset sans repli cote code :
                   sans le fichier, le bouton est inutilisable.

Ce qui n'est PAS genere : ring.wav, dial.wav et notif.wav. Le client
synthetise ses propres motifs quand ils manquent (cf. _synth_phone_*_pattern
dans radiosmoltz_audio_io.py), et un placeholder serait moins bon que le repli.

Les WAV sont ecrits en PCM 16 bits mono 48 kHz : c'est le seul format que
_load_wav_as_float32 accepte sans conversion.

Usage : python make-placeholder-assets.py [options] <dossier_app>

  --icon-only        ne genere que l'icone (payload serveur : pas de
                     soundboard ni de sonneries a remplacer)
  --sounds-only      ne genere que les sons
  --icon-name NOM    nom du fichier icone a creer (defaut RadioSmoltz.ico)

--icon-name existe parce qu'un payload embarque plusieurs icones :
RadioSmoltz.ico pour le client, RadioSmoltzAdmin.ico pour la console
d'administration, RadioSmoltzServer.ico cote serveur. Chacune peut manquer
independamment des autres.
"""

import math
import struct
import sys
import wave
from pathlib import Path

SAMPLE_RATE = 48000


# ----------------------------------------------------------------------
# WAV
# ----------------------------------------------------------------------

def _write_wav(path: Path, samples: list) -> None:
    """Ecrit une liste de floats [-1, 1] en WAV PCM 16 bits mono 48 kHz."""
    frames = bytearray()
    for s in samples:
        clamped = max(-1.0, min(1.0, s))
        frames += struct.pack("<h", int(clamped * 32767.0))
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(bytes(frames))


def _alarm_samples() -> list:
    """Deux balayages de sirene 600 -> 1200 Hz, facon klaxon d'alerte.

    Enveloppe attaque/chute de 15 ms sur chaque balayage pour eviter le clic
    de debut et de fin (le mix soundboard est diffuse tel quel aux autres
    joueurs, un clic serait audible).
    """
    sweep_sec = 0.55
    gap_sec = 0.12
    n_sweep = int(SAMPLE_RATE * sweep_sec)
    n_gap = int(SAMPLE_RATE * gap_sec)
    fade = int(SAMPLE_RATE * 0.015)

    out = []
    for _ in range(2):
        phase = 0.0
        for i in range(n_sweep):
            t = i / n_sweep
            freq = 600.0 + 600.0 * t
            phase += 2.0 * math.pi * freq / SAMPLE_RATE
            env = 0.6
            if i < fade:
                env *= i / fade
            elif i > n_sweep - fade:
                env *= (n_sweep - i) / fade
            # Onde triangulaire douce : plus percante qu'une sinus pure sans
            # etre aussi agressive qu'un carre.
            val = math.sin(phase) + 0.25 * math.sin(2.0 * phase)
            out.append(env * val * 0.7)
        out.extend([0.0] * n_gap)
    return out


# ----------------------------------------------------------------------
# ICO
# ----------------------------------------------------------------------

def _draw_icon(size: int) -> list:
    """Retourne une matrice size x size de tuples (b, g, r, a).

    Motif : disque bleu (#58a6ff, la couleur d'accent du theme RadioSmoltz)
    sur fond transparent, avec une etoile a quatre branches evidee au centre.
    Volontairement simple : c'est un placeholder assume, pas un logo.
    """
    cx = cy = (size - 1) / 2.0
    radius = size * 0.46
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            dx = x - cx
            dy = y - cy
            dist = math.hypot(dx, dy)

            # Anti-aliasing du bord du disque sur 1 pixel.
            if dist > radius + 0.5:
                row.append((0, 0, 0, 0))
                continue
            alpha = 255
            if dist > radius - 0.5:
                alpha = int(255 * (radius + 0.5 - dist))

            # Etoile a quatre branches : superellipse d'exposant 1/2
            # (astroide). sqrt(|x|/R) + sqrt(|y|/R) <= 1 donne des cotes
            # concaves, donc des pointes fines, en une seule expression.
            arm = radius * 0.86
            star = math.sqrt(abs(dx) / arm) + math.sqrt(abs(dy) / arm)
            if star <= 1.0:
                # Interieur de l'etoile : bleu tres clair.
                b, g, r = 0xF5, 0xFA, 0xFF
            else:
                b, g, r = 0xFF, 0xA6, 0x58   # BGR de #58a6ff
            row.append((b, g, r, alpha))
        rows.append(row)
    return rows


def _bmp_dib(size: int) -> bytes:
    """Image 32 bits ARGB au format DIB (BITMAPINFOHEADER + pixels bottom-up).

    C'est la variante d'ICO la plus simple a produire sans dependance : pas
    de compression PNG a gerer, juste un en-tete de 40 octets. Le masque AND
    est omis (hauteur doublee non requise pour du 32 bits avec canal alpha,
    accepte par Windows et par Qt).
    """
    pixels = _draw_icon(size)
    header = struct.pack(
        "<IiiHHIIiiII",
        40,             # biSize
        size,           # biWidth
        size * 2,       # biHeight (image XOR + masque AND, cf. format ICO)
        1,              # biPlanes
        32,             # biBitCount
        0,              # biCompression = BI_RGB
        size * size * 4,
        0, 0, 0, 0,
    )
    body = bytearray()
    for y in range(size - 1, -1, -1):      # DIB = bottom-up
        for (b, g, r, a) in pixels[y]:
            body += struct.pack("<BBBB", b, g, r, a)
    # Masque AND : tout a zero (l'alpha du XOR fait la transparence). Chaque
    # ligne est alignee sur 4 octets.
    mask_row = ((size + 31) // 32) * 4
    body += bytes(mask_row * size)
    return header + bytes(body)


def _write_ico(path: Path, sizes=(16, 32, 48, 256)) -> None:
    images = [(s, _bmp_dib(s)) for s in sizes]
    out = bytearray(struct.pack("<HHH", 0, 1, len(images)))   # ICONDIR
    offset = 6 + 16 * len(images)
    for size, data in images:
        out += struct.pack(
            "<BBBBHHII",
            0 if size >= 256 else size,   # 0 signifie 256
            0 if size >= 256 else size,
            0, 0, 1, 32,
            len(data), offset,
        )
        offset += len(data)
    for _, data in images:
        out += data
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(out))


# ----------------------------------------------------------------------
# main
# ----------------------------------------------------------------------

def main() -> int:
    args = sys.argv[1:]
    icon_only = "--icon-only" in args
    sounds_only = "--sounds-only" in args
    icon_name = "RadioSmoltz.ico"
    if "--icon-name" in args:
        i = args.index("--icon-name")
        if i + 1 >= len(args):
            print("[ASSETS] --icon-name attend un nom de fichier")
            return 2
        icon_name = args[i + 1]
        del args[i:i + 2]
    positional = [a for a in args if not a.startswith("--")]
    if not positional:
        print("usage: make-placeholder-assets.py [--icon-only] [--sounds-only] "
              "[--icon-name NOM] <dossier_app>")
        return 2
    app_dir = Path(positional[0]).resolve()
    if not app_dir.is_dir():
        print(f"[ASSETS] Dossier introuvable : {app_dir}")
        return 1

    created = []

    if not sounds_only:
        ico = app_dir / icon_name
        if ico.exists():
            print(f"[ASSETS] Conserve : {ico.name}")
        else:
            _write_ico(ico)
            created.append(ico.name)

    # --icon-only : payload serveur. Il n'a ni soundboard ni sonneries, mais
    # il a besoin de l'icone -- pour l'installeur, les raccourcis et les
    # lanceurs compiles.
    if not icon_only:
        alarm = app_dir / "sounds" / "alarm.wav"
        if alarm.exists():
            print(f"[ASSETS] Conserve : sounds/{alarm.name}")
        else:
            _write_wav(alarm, _alarm_samples())
            created.append("sounds/alarm.wav")

        for name in ("ring.wav", "dial.wav", "notif.wav"):
            target = app_dir / "sounds" / name
            if target.exists():
                print(f"[ASSETS] Conserve : sounds/{name}")
            else:
                print(f"[ASSETS] sounds/{name} absent : le client synthetisera "
                      f"son propre motif (pas de placeholder).")

    if created:
        print(f"[ASSETS] Placeholders generes : {', '.join(created)}")
        print("[ASSETS] Deposer les vrais assets dans client\\ (et "
              "client\\sounds\\) pour qu'ils soient utilises a la place.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
