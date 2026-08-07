# Construire les installeurs Windows

Le dépôt amont publie `CircusVOIP_Client_Setup_vX.Y.Z.exe` et
`CircusVOIP_Server_Setup_vX.Y.Z.exe` dans ses releases, mais la chaîne de
packaging n'est pas versionnée. Ce dossier la reconstitue.

## Ce que produit l'installeur

Le layout installé n'est pas arbitraire : c'est celui que le code attend.
`circusvoip_audio_io.py` cherche ses sons dans `app/sounds/` (« packaging par
l'installateur Inno Setup, `[Files]` embarque `app/*` récursivement ») et
`circusvoip_client.py` cherche les paquets pip dans
`runtime/Lib/site-packages/` (« pour un PBS embarqué »). D'où :

```
<InstallDir>\                       %LOCALAPPDATA%\CircusVOIP par défaut
├── app\
│   ├── circusvoip_client.py        sources, mises à jour en place par
│   ├── circusvoip_core.py          l'updater intégré du client
│   ├── circusvoip_audio_io.py
│   ├── circusvoip_sc_ocr.py
│   ├── circusvoip_security.py
│   ├── circusvoip_audio_rx_logger.py
│   ├── circusvoip_admin.py         console d'admin (vient de server\)
│   ├── circusvoip_version.json     version affichée + comparée au serveur
│   ├── StarCircus.ico
│   ├── sounds\alarm.wav, ...
│   └── (à l'usage) circusvoip_client_config.json, circusphone_*.json,
│       circusvoip_profile_photo*, logs, ptt_press.wav / ptt_release.wav
└── runtime\
    ├── python.exe / pythonw.exe    CPython embarqué (python-build-standalone)
    └── Lib\site-packages\          PySide6, numpy, cv2, sounddevice, …
                                    puis easyocr + torch au 1er lancement
```

Le raccourci du menu Démarrer lance
`runtime\pythonw.exe "app\circusvoip_client.py"`. Aucun Python système n'est
requis sur la machine du joueur.

### Répartition client / serveur

Trois interfaces graphiques cohabitent dans le dépôt, et elles ne s'installent
pas au même endroit :

| Interface | Source | Installeur | Pourquoi |
|---|---|---|---|
| Client de jeu | `client\circusvoip_client.py` | client | — |
| **Console d'administration** | `server\circusvoip_admin.py` | **client** | elle administre un serveur **à distance** (`wss://…:8888` + token admin) : sa place est sur le poste de l'administrateur |
| Serveur de positions (8888) | `server\circusvoip_server.py` | serveur | |
| Serveur audio (8889) | `server\circusvoip_audio_server.py` | serveur | |

La console d'administration vit dans `server\` parce qu'elle parle le
protocole d'administration du serveur, mais la machine qui héberge les
serveurs est le plus souvent un VPS ou un `docker compose` — sans session
graphique pour y afficher quoi que ce soit. Elle est donc **livrée avec le
client**, où ses dépendances (websockets, tkinter, `circusvoip_security`) sont
déjà présentes.

Conséquence côté runtime : `tkinter` n'est plus élagué du runtime client
(l'interface du client est en Qt, celle de la console en Tk). Coût : ~12 Mo
non compressés, ~2,7 Mo sur la taille de l'installeur.

### Installation serveur : les lanceurs

L'installeur serveur livre les **deux** serveurs et pose trois exécutables à la
racine de l'installation :

```
<InstallDir>\                       %LOCALAPPDATA%\CircusVOIP-Server par défaut
├── CircusVOIP-Servers.exe          démarre les DEUX interfaces d'un coup
├── CircusVOIP-Positions.exe        positions (8888) seul
├── CircusVOIP-Audio.exe            audio (8889) seul
├── app\
└── runtime\
```

Ce sont de vrais binaires, compilés au build à partir de
[`launcher\launcher-template.cs`](launcher/launcher-template.cs) par `csc.exe`,
le compilateur C# du .NET Framework — livré avec Windows, donc aucune
dépendance de build en plus, ni en local ni sur les runners GitHub.

Un raccourci vers `pythonw.exe` aurait suffi pour lancer *un* serveur, mais pas
pour en lancer deux, et un `.lnk` ne se copie ni ne s'appelle depuis une tâche
planifiée. Chaque lanceur résout `runtime\` et `app\` **relativement à sa
propre position** : l'installation reste déplaçable. Les arguments sont
transmis tels quels, et `--headless` bascule sur `python.exe` (console
visible) puisque c'est justement le mode où le serveur n'a plus d'interface et
n'écrit que sur la sortie standard :

```powershell
.\CircusVOIP-Positions.exe --headless
```

Ce que les lanceurs ne font **pas** : renommer le processus. Ils démarrent
`pythonw.exe` et rendent la main ; dans le gestionnaire de tâches, les deux
serveurs restent deux `pythonw.exe` indiscernables.

Le serveur de mise à jour (8080) reste un simple raccourci vers `python.exe` :
c'est un service HTTP sans interface, sa sortie console **est** son journal.

**L'installation se fait dans `%LOCALAPPDATA%`, pas dans `Program Files`.** Le
client écrit sa configuration, ses conversations CircusPhone *et ses mises à
jour auto-appliquées* dans `app\` : sous `Program Files`, ces écritures
exigeraient des droits admin et l'updater intégré échouerait. L'installeur
prévient si un chemin sous `Program Files` est choisi malgré tout.

## Prérequis

| Outil | Version | Notes |
|---|---|---|
| Windows | 10 / 11 x64 | `curl.exe`, `tar.exe` et `csc.exe` fournis par l'OS |
| PowerShell | 5.1+ | celui de Windows suffit |
| .NET Framework | 4.x | déjà présent sur Windows 8+ ; fournit le `csc.exe` qui compile les lanceurs serveur |
| Inno Setup | **6.3+** | pour `ArchitecturesAllowed=x64compatible` ; valide avec 6.7.3. Un Inno Setup 7 deja installe est detecte et utilise |
| Espace disque | ~3 Go | ~15 Go pour `-Deps full` |

Le runtime Python est téléchargé automatiquement (aucun Python local requis)
et mis en cache dans `installer\.cache\`.

Installer Inno Setup, au choix :

```powershell
winget install -e --id JRSoftware.InnoSetup
# ou laisser le script le faire (téléchargement + install silencieuse) :
.\installer\build-installer.ps1 -InstallInnoSetup
```

## Utilisation

```powershell
# Client, dépendances « bundled » (défaut)
.\installer\build-installer.ps1

# Client + serveur
.\installer\build-installer.ps1 -Component both

# Build de test rapide : runtime nu, pas de pip install
.\installer\build-installer.ps1 -Deps none -Clean

# Tout embarqué, y compris easyocr/torch
.\installer\build-installer.ps1 -Deps full
```

Résultat dans `installer\out\` :
`CircusVOIP_Client_Setup_v<version>.exe`. Si le canal n'est pas `stable`, le
canal et le build sont suffixés (`…_v0.2.0-alpha057.exe`).

Le premier build télécharge le runtime (~45 Mo) puis les wheels ; comptez
10-20 min. Les suivants réutilisent `installer\.cache\` et le runtime déjà
préparé dans `installer\work\` — quelques minutes, dont l'essentiel en
compression LZMA.

### Niveaux de dépendances

| `-Deps` | Contenu | Taille installeur | Premier lancement |
|---|---|---|---|
| `bundled` (défaut) | PySide6-Essentials, numpy, opencv-headless, mss, sounddevice, pynput, psutil, cryptography, Pillow + optionnels | **107 Mo** (481 Mo installés) | télécharge le moteur OCR (243 Mo en CPU) |
| `full` | idem + moteur OCR selon `-OcrBackend` | +243 Mo (CPU) ou +2 Go (CUDA) | rien à télécharger |
| `none` | runtime nu | **23 Mo** | télécharge tout |

Tailles mesurées sur un build réel (CPython 3.12.13, PySide6-Essentials 6.11.1,
OpenCV 4.14, Inno Setup 6.7.3). L'installeur serveur fait 28 Mo.

### Moteur OCR : CPU ou CUDA

Le moteur (EasyOCR, qui tourne sur PyTorch) est la plus grosse dépendance, et
la seule dont la variante se choisit.

**Sous Windows, PyPI ne publie que des wheels torch CPU.** Toutes versions
confondues elles pèsent 100 à 200 Mo (`torch 2.13.0` = 116 Mo) ; les builds
CUDA, eux, ne vivent que sur `download.pytorch.org` et pèsent 1,8 Go (cu130) à
2,7 Go (cu128). Concrètement :

| Variante | torch | Total `pip install easyocr` | Pour qui |
|---|---|---|---|
| CPU (défaut) | 116 Mo | **243 Mo**, 26 paquets | AMD, Intel, et NVIDIA sans accélération |
| CUDA (cu130) | 1 826 Mo | **~2 Go** | NVIDIA uniquement |

Donc une carte AMD ne télécharge **aucun** payload CUDA aujourd'hui : le
bootstrap du client tombe déjà sur la variante CPU. C'est l'inverse qui
surprend — un joueur NVIDIA n'a pas non plus d'accélération GPU par défaut,
alors que le code fait bien `torch.cuda.is_available()` et que le README
principal recommande une carte NVIDIA.

Le choix se fait par un `extra-index-url` écrit dans `runtime\pip.ini`. pip lit
ce fichier comme configuration « site » du préfixe, donc **tout** pip lancé
avec ce runtime en hérite — y compris le bootstrap du client au premier
lancement, sans toucher une ligne de `circusvoip_client.py`. Ça compte : les
sources sont écrasées par l'updater intégré depuis le manifeste du serveur, un
patch dans le code ne survivrait pas. Une version locale PEP 440
(`2.13.0+cu130`) l'emportant sur la version simple (`2.13.0`), un banal
`pip install easyocr` résout la bonne variante.

**À la construction** : `-OcrBackend cpu|cuda` fixe la valeur par défaut du
payload, et la variante réellement embarquée avec `-Deps full`.

```powershell
.\installer\build-installer.ps1 -Deps full -OcrBackend cpu     # tout inclus, 243 Mo de plus
.\installer\build-installer.ps1 -Deps full -OcrBackend cuda    # NVIDIA, plusieurs Go
```

**À l'installation** (quand le moteur n'est pas embarqué) : l'installeur ajoute
une page proposant CPU (243 Mo) / NVIDIA CUDA (~2 Go) / ne rien télécharger
maintenant. La présence de `nvcuda.dll` dans System32 — posé par le pilote
NVIDIA — présélectionne CUDA. Le téléchargement lui-même reste une case à
cocher de la dernière page, dans une console visible.

Si l'utilisateur choisit « ne rien télécharger », son choix de variante est
quand même enregistré dans `pip.ini` : le client installera la bonne au premier
lancement.

En installation silencieuse : `/OCR=cpu`, `/OCR=cuda` ou `/OCR=skip` (sans
paramètre, la détection NVIDIA décide).

```powershell
.\CircusVOIP_Client_Setup_v0.2.0.exe /VERYSILENT /OCR=cpu
```

Pour changer d'avis après coup, éditer `runtime\pip.ini` et relancer
`runtime\python.exe -m pip install --upgrade --force-reinstall torch torchvision`.

> Le moteur OCR ne peut pas être rendu *facultatif* : sans lui, pas de lecture
> de position, donc pas de VOIP de proximité. Le bootstrap du client le traite
> comme obligatoire et `sys.exit(1)` si son installation échoue. Ce qui se
> choisit, c'est la variante et le moment du téléchargement, pas son principe.

`bundled` correspond à ce que fait l'amont : ses installeurs client pèsent
163 Mo (v0.2.0) et 348 Mo (v0.3.0), bien trop peu pour contenir torch. Le
client s'en charge lui-même au démarrage via son bootstrap pip
(`_bootstrap_dependencies()` dans `circusvoip_client.py`), qui installe ce
qui manque avec `python -m pip install`. C'est pour ça que `pip` doit rester
présent dans le runtime embarqué — ne pas l'élaguer.

L'installeur propose une case à cocher en fin d'installation pour faire ce
téléchargement tout de suite, dans une console visible, plutôt que de laisser
le joueur devant une fenêtre qui semble figée 20 minutes.

### Construire depuis GitHub Actions

[`.github/workflows/build-installer.yml`](../.github/workflows/build-installer.yml)
fait tourner exactement la même chaîne sur un runner `windows-latest`, qui
fournit déjà Inno Setup (6.7.1 au moment de l'écriture ; sinon le workflow
l'installe via Chocolatey).

**Sur push d'un tag** `client-v*` ou `server-v*` : le composant est déduit du
préfixe, la version du tag, et les `.exe` + `SHA256SUMS.txt` sont attachés à la
release (créée avec `--generate-notes` si elle n'existe pas encore).

```bash
git tag client-v0.2.1 && git push origin client-v0.2.1
```

**À la demande** : onglet Actions → *build-installer* → *Run workflow*, avec le
choix du composant et du niveau de dépendances. Les installeurs sont alors
récupérables en artefact (14 jours).

**Sur pull request** touchant `installer/`, `client/`, `server/` ou le workflow
lui-même : build **des deux composants** + smoke test, sans rien publier
(l'étape de release est conditionnée au tag). Les deux `.exe` et leur
`SHA256SUMS.txt` sont téléchargeables en artefact depuis la page du run.

Les deux, parce que `server/` est dans le filtre de chemins : ne construire que
le client ferait tourner quinze minutes de CI sans rien dire de la modification.
Un tag, lui, ne publie que le composant de son préfixe.

C'est aussi le moyen de valider le workflow **avant** de le merger :
`workflow_dispatch` n'apparaît dans l'interface qu'une fois le fichier présent
sur la branche par défaut, donc le bouton *Run workflow* n'existe pas tant que
la PR n'est pas mergée.

> Le smoke test ne couvre que le client — il y vérifie aussi la présence de
> `circusvoip_admin.py` et l'import de `tkinter`. L'installeur serveur est
> construit et publié en artefact, mais rien ne vérifie encore son contenu ni
> ses lanceurs.

Le tag fait foi sur le numéro de version, pas `circusvoip_version.json` : ce
fichier est régulièrement en retard (côté serveur il est resté en 0.1.1 alors
que la release publiée est en 0.3.0). Un tag qui ne correspond pas au motif
`<composant>-vX.Y.Z` déclenche un warning et retombe sur le JSON.

Avant publication, le workflow **installe l'exe qu'il vient de produire** sur
le runner, lance `smoke-test.py` avec le runtime embarqué, puis désinstalle. Un
payload cassé (module oublié, élagage trop agressif, wheel manquant) est
attrapé là plutôt que par les joueurs. Le même script tourne en local :

```powershell
$env:QT_QPA_PLATFORM = 'offscreen'
& "$env:LOCALAPPDATA\CircusVOIP\runtime\python.exe" .\installer\smoke-test.py "$env:LOCALAPPDATA\CircusVOIP"
```

Deux limites côté CI : `-Deps full -OcrBackend cuda` n'y est pas raisonnable
(~2 Go de téléchargement puis plusieurs Go installés, pour une dizaine de Go
libres sur un runner ; `-OcrBackend cpu` passe sans problème), et les
installeurs produits ne sont pas signés — voir plus bas.

### Paramètres utiles

| Paramètre | Effet |
|---|---|
| `-Component client\|server\|both` | quoi construire |
| `-Deps bundled\|full\|none` | cf. tableau ci-dessus |
| `-OcrBackend cpu\|cuda` | variante de PyTorch (défaut `cpu`) |
| `-Version 0.2.1 -Build 58 -Channel stable` | surcharge `circusvoip_version.json` |
| `-PythonVersion 3.12` | série CPython embarquée |
| `-FullQt` | wheel `PySide6` complet au lieu de `PySide6-Essentials` |
| `-Clean` | vide `installer\work\` (re-extraction + réinstallation des deps) |
| `-SkipPrune` | garde tout le runtime (debug d'un import manquant) |
| `-NoPlaceholders` | ne génère pas les assets manquants |
| `-IsccPath …\ISCC.exe` | Inno Setup hors des emplacements standards |

## Points d'attention

### Les assets binaires ne sont pas dans le dépôt

`StarCircus.ico` et `client/sounds/*.wav` n'ont jamais été versionnés
(`client/sounds/` est même dans `.gitignore`).
`make-placeholder-assets.py` génère donc :

- `StarCircus.ico` — étoile bleue sur disque, placeholder assumé ;
- `sounds/alarm.wav` — sirène de synthèse, le son du soundboard étant le
  **seul** asset sans repli côté code.

`ring.wav`, `dial.wav` et `notif.wav` ne sont volontairement pas générés : le
client synthétise ses propres motifs quand ils manquent
(`_synth_phone_*_pattern`), ce qui vaut mieux qu'un placeholder.

#### Utiliser ses propres assets

Il suffit de les déposer dans l'arbre de travail : rien n'est jamais écrasé,
le placeholder n'est généré que si le fichier manque.

| Ce que vous déposez | Utilisé par |
|---|---|
| `client\StarCircus.ico` | le client **et**, à défaut d'icône propre, le serveur |
| `server\StarCircus.ico` | le serveur seul (prioritaire sur celle du client) |
| `client\sounds\*.wav` | le client (`alarm.wav`, `ring.wav`, `dial.wav`, `notif.wav`) |

Une seule icône dans `client\` suffit donc à habiller les deux installeurs.
Elle sert à quatre choses : icône des fenêtres, des raccourcis, de
l'installeur lui-même (`SetupIconFile`) et des lanceurs serveur, ces derniers
la recevant via `/win32icon` au moment de la compilation.

Le format doit être un vrai `.ico` — un `.png` renommé ne passera pas
`/win32icon`. Prévoir plusieurs tailles dans le fichier (16, 32, 48, 256), le
256 étant celui qu'affichent l'explorateur en grandes icônes et la boîte de
dialogue de l'installeur. Pour convertir depuis un PNG :

```powershell
magick convert logo.png -define icon:auto-resize=256,48,32,16 client\StarCircus.ico
```

Les `.ico` ne sont pas dans `.gitignore` (contrairement à `client/sounds/`) :
une icône déposée là est versionnable, et tous les builds — y compris ceux de
GitHub Actions — l'utiliseront. Sans ça, la CI reproduit le placeholder.

Après changement d'icône, rebuilder avec `-Clean` n'est pas nécessaire, mais
les lanceurs serveur doivent être recompilés : ils le sont à chaque build, donc
un simple `-Component server` suffit.

### La suppression de bruit (pyrnnoise) n'est pas embarquée

`pyrnnoise` est volontairement absent de la liste des dépendances : la chaîne
publiée sur PyPI est cassée. `pyrnnoise` 0.4.3 importe `audiolab` dès le
chargement du module, `audiolab` 0.5.1 fait `from av.option import OptionType`,
et `av` 18 n'expose plus `av.option`. Résultat : `ImportError` garanti, pour
132 Mo de dépendances (`av`, `matplotlib`, `soundfile`, `requests`…).

Le client gère l'absence sans broncher : `NOISE_SUPPRESSION_AVAILABLE = False`
et la case correspondante est grisée dans l'onglet Audio. Pour retenter,
ajouter `'pyrnnoise'` (et probablement `'av<15'`) dans `$ClientDepsOptional`
en tête de `build-installer.ps1`, puis **vérifier l'import avant de publier** :

```powershell
.\installer\work\client\runtime\python.exe -c "from pyrnnoise import RNNoise"
```

### Fenêtre de console

Le client est une application Qt : elle ne doit pas traîner une console noire
derrière elle. Le lanceur détermine tout :

| Lanceur | Console | Où c'est utilisé |
|---|---|---|
| `runtime\pythonw.exe` | non | raccourcis menu Démarrer et Bureau, console d'administration, lancement en fin d'installation |
| `runtime\python.exe` | oui | raccourci « console de diagnostic » (tâche optionnelle, décochée), téléchargement du moteur OCR |
| `CircusVOIP-*.exe` (serveur) | non | compilés en sous-système GUI (`/target:winexe`), ils passent par `pythonw.exe` — sauf avec `--headless`, où ils basculent sur `python.exe` |

Le client s'accommode très bien de l'absence de console : avec `pythonw`,
`sys.stdout` vaut `None` et `print()` devient un no-op silencieux côté CPython
— rien ne lève —, et le journal de session part de toute façon dans un fichier.
`pip` lancé par le bootstrap fonctionne aussi sans console (vérifié : code de
sortie 0, paquet correctement installé).

Une seule exception délibérée : si l'utilisateur a refusé le téléchargement du
moteur OCR pendant l'installation, le bouton « Lancer maintenant » utilise
`python.exe`. Sinon le bootstrap téléchargerait 243 Mo sans que rien
n'apparaisse à l'écran pendant plusieurs minutes, ce qui se lit comme un
plantage. Dès que le moteur est présent, tout passe par `pythonw.exe`.

**Sur une installation existante**, il suffit de repointer le raccourci :

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\CircusVOIP\CircusVOIP.lnk")
$s.TargetPath = $s.TargetPath -replace 'python\.exe$', 'pythonw.exe'
$s.Save()
```

Et supprimer le raccourci « console de diagnostic » s'il a été créé.

### Les bornes de version des dépendances

Les majeures à risque sont bornées dans `$ClientDepsRequired` :
`opencv-python-headless>=4.9,<5` (le code est écrit contre l'API OpenCV 4.x, or
5.0 est sorti), `PySide6-Essentials>=6.6,<7` et `numpy>=1.26,<3`. Sans ces
bornes, un build fait dans six mois peut ramasser une majeure incompatible et
casser l'OCR ou l'UI sans que rien n'échoue à la compilation.

Le wheel `headless` d'OpenCV est utilisé parce que le code n'appelle jamais
`cv2.imshow` / `cv2.namedWindow` — seulement `resize`, `cvtColor`, `threshold`,
`connectedComponentsWithStats` et consorts.

### L'AppId diffère de celui de l'amont

Inno reconnaît « une version déjà installée » par son `AppId`. Celui des
`.iss` de ce dossier a été généré ici, il ne peut pas correspondre à celui de
l'amont (inconnu, enfoui dans ses `.exe`). Conséquences pour un poste qui a
déjà l'installeur amont :

- deux entrées dans « Applications installées » ;
- le désinstalleur amont reste séparé.

Le dossier d'installation par défaut étant vraisemblablement le même, les
fichiers, eux, sont bien mis à jour en place. Pour une continuité parfaite, il
faut extraire l'`AppId` de l'installeur amont (par ex. avec
[innounp](https://sourceforge.net/projects/innounp/) : `innounp -x setup.exe`
puis lire `install_script.iss`) et le recopier dans `client.iss`. **Ne jamais
changer l'`AppId` entre deux de vos propres releases**, sinon vous créez le
problème chez vos utilisateurs.

### L'installeur n'est pas signé

Windows SmartScreen affichera « Éditeur inconnu » au lancement. Avec un
certificat de signature de code, ajouter dans la section `[Setup]` :

```ini
SignTool=mysigntool
SignedUninstaller=yes
```

et déclarer `mysigntool` dans les paramètres d'Inno Setup (`Tools` →
`Configure Sign Tools…`), ou passer
`/Smysigntool="signtool.exe sign /f cert.pfx /p pass $f"` à ISCC.

### Modules manquants dans l'arbre de travail

Le script refuse de builder si un module attendu manque et affiche lesquels.
C'est délibéré : `circusvoip_security.py` (contexte TLS) et
`circusvoip_audio_rx_logger.py` (log audio RX) sont importés au runtime, et
une release amputée planterait chez les joueurs. Si les fichiers sont
supprimés dans l'arbre de travail sans l'être dans le dépôt :

```powershell
git restore client/
```

La validation couvre aussi les modules repris dans l'autre dossier
(`server\circusvoip_admin.py` pour le client) : le build échoue avant la copie,
avec le nom du dossier où regarder.

### Mise à jour vs updater intégré

Deux mécanismes coexistent, indépendants :

- **l'installeur** (ce dossier) : release complète, remplace `app\` et
  `runtime\` en conservant la configuration ;
- **l'updater intégré du client** : interroge
  `http://<serveur>:8080/manifest.json` et remplace les `.py` un par un dans
  `app\` (cf. `circusvoip_update_server.py` côté serveur).

Après une release par installeur, régénérer le manifeste du serveur d'update
pour que les deux versions concordent, sinon les clients retéléchargeront des
`.py` plus anciens ou plus récents que ceux installés.

### Pare-feu (serveur)

L'installeur serveur ne pose pas de règle : il tourne sans élévation et
`netsh advfirewall` exige des droits admin. Au premier démarrage, Windows
affiche sa propre demande d'autorisation pour `python.exe`. Sinon, dans une
invite **administrateur** :

```powershell
netsh advfirewall firewall add rule name="CircusVOIP positions 8888" dir=in action=allow protocol=TCP localport=8888 profile=private
netsh advfirewall firewall add rule name="CircusVOIP audio 8889" dir=in action=allow protocol=TCP localport=8889 profile=private
```

Rappel du README principal : exposer ces ports sur Internet expose le serveur
aux scans automatiques.

## Dépannage

**« Inno Setup 6 introuvable »** — installer Inno Setup, ou passer
`-InstallInnoSetup`, ou `-IsccPath`.

**« Unknown directive: ArchitecturesAllowed » / valeur `x64compatible`
refusée** — Inno Setup antérieur à 6.3. Mettre à jour, ou remplacer
`x64compatible` par `x64` dans les deux `.iss`.

**Une dépendance optionnelle échoue au pip install** — c'est un avertissement,
pas une erreur : `bettercam` (capture DirectX), `pytesseract` (fallback OCR) et
`nvidia-ml-py` (métriques GPU) sont tous dans un `try/except` côté code, la
feature est simplement désactivée.
`--only-binary=:all:` est passé à pip pour qu'aucun paquet ne tente une
compilation locale ; un paquet sans wheel pour la série CPython choisie
échouera donc au lieu de bloquer le build.

**Le client installé plante à l'import** — lancer le raccourci « console de
diagnostic » (à cocher pendant l'installation) : les logs `[BOOT]` /
`[BOOTSTRAP]` indiquent le module fautif. Rebuilder avec `-SkipPrune` si un
fichier élagué du runtime est en cause.

**L'installeur ne peut pas remplacer un fichier** — une instance du client
tourne encore. `CloseApplications=yes` demande la fermeture, mais un process
`pythonw.exe` orphelin peut subsister : le terminer dans le gestionnaire de
tâches.

## Ce qui a été vérifié

La chaîne a été exécutée de bout en bout sur Windows 11 x64 avec Inno Setup
6.7.3 :

- build `-Deps none` et `-Deps bundled`, client et serveur, compilation ISCC OK ;
- installation silencieuse (`/VERYSILENT /DIR=…`), layout `app\` + `runtime\`
  conforme, `circusvoip_version.json` régénéré sans BOM et relu correctement ;
- import des 13 dépendances embarquées dans le runtime installé, y compris la
  création d'une `QApplication` (le plugin de plateforme Qt survit à
  l'élagage) ;
- `py_compile` des 7 modules client sous CPython 3.12 ;
- **lancement réel du client installé** : bootstrap pip satisfait en 10 ms
  (aucun téléchargement), fenêtre visible en 0,9 s, rien sur `stderr` ;
- désinstallation : `runtime\` entièrement supprimé (y compris les paquets
  ajoutés après-coup et les caches `.pyc`), configuration et `ptt_*.wav`
  personnalisés conservés, aucune entrée résiduelle dans la base de registre ;
- choix du moteur OCR : `/OCR=cpu`, `/OCR=cuda`, `/OCR=skip` et détection
  automatique écrivent bien l'index attendu dans `pip.ini`, et la commande
  exacte du bootstrap client (`pip install --upgrade easyocr`) résout ensuite
  `torch 2.13.0+cu130` ou `torch 2.13.0+cpu` selon le choix.

Les lanceurs et la nouvelle répartition client / serveur ont été vérifiés de la
même façon :

- installation silencieuse de l'installeur serveur (27,9 Mo), puis lancement
  des trois exécutables :
  `CircusVOIP-Servers.exe` ouvre bien **deux** fenêtres
  (« CircusVOIP — Serveur » et « CircusVOIP - Audio Server »),
  `CircusVOIP-Positions.exe` et `CircusVOIP-Audio.exe` une seule chacun ;
- aucune fenêtre de console dans les trois cas, et le port 8889 passe bien en
  écoute ;
- `CircusVOIP-Positions.exe --headless` bascule bien sur `python.exe`, aucun
  `pythonw.exe` lancé, port 8888 en écoute : l'argument est transmis ;
- payload serveur conforme — plus de `circusvoip_admin.py`, et un
  `[InstallDelete]` retire la copie orpheline laissée par les versions
  précédentes de l'installeur ;
- désinstallation serveur : les trois lanceurs et `runtime\` supprimés, seuls
  les secrets et l'état généré à l'exécution (`cert.pem`, `key.pem`,
  `circusvoip_server_config.json`, `circusvoip_admin_token.json`) restent —
  volontairement ;
- côté client, `circusvoip_admin.py` est bien embarqué, `tkinter` importable
  dans le runtime élagué, et la console d'administration démarre depuis le
  payload (fenêtre « CircusVOIP - Admin »).

Un installeur client (0.2.0, `bundled`) et un installeur serveur déjà
construits se trouvent dans `out\`. Ils ont été produits depuis les sources de
`HEAD`, pas depuis l'arbre de travail.

## Fichiers

| Fichier | Rôle |
|---|---|
| `build-installer.ps1` | orchestration : runtime, pip, staging, lanceurs, ISCC |
| `client.iss` | script Inno Setup du client (+ console d'administration) |
| `server.iss` | script Inno Setup du serveur (les deux serveurs) |
| `launcher\launcher-template.cs` | modèle des lanceurs `CircusVOIP-*.exe`, compilé par `csc.exe` |
| `make-placeholder-assets.py` | génère les assets binaires manquants |
| `smoke-test.py` | valide une installation (fichiers, imports, Qt, pip) |
| `.cache\` | runtime PBS et installeur Inno téléchargés (non versionné) |
| `work\` | payload intermédiaire `app\` + `runtime\` (non versionné) |
| `out\` | installeurs produits (non versionné) |
