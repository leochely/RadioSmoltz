<#
.SYNOPSIS
    Construit les installeurs .exe Windows de CircusVOIP (client et/ou serveur).

.DESCRIPTION
    Reproduit la chaine de packaging que le projet amont utilise mais qui n'est
    pas versionnee : un runtime Python embarque (python-build-standalone) + les
    sources .py dans app\, le tout emballe par Inno Setup.

    Etapes :
      1. Validation de l'arbre de travail (les modules attendus sont presents).
      2. Telechargement + mise en cache d'un runtime python-build-standalone.
      3. pip install des dependances dans runtime\Lib\site-packages.
      4. Staging du payload : app\ (sources + assets + circusvoip_version.json)
         et runtime\.
      4bis. Cote serveur uniquement : compilation des lanceurs bin\*.exe
         (cf. installer\launcher\launcher-template.cs).
      5. Compilation du .iss par ISCC.exe -> installer\out\*.exe

    Le layout d'installation produit est celui que le code client attend
    (cf. circusvoip_audio_io.py : "app/sounds/<nom>.wav ... packaging par
    l'installateur Inno Setup" et circusvoip_client.py : "_find_site_packages_dir
    ... pour un PBS embarque, c'est typiquement runtime/Lib/site-packages/") :

        <InstallDir>\app\circusvoip_client.py, sounds\, StarCircus.ico, ...
        <InstallDir>\runtime\python.exe, Lib\site-packages\...

    Cote serveur, s'y ajoutent les lanceurs, a la racine de l'installation :

        <InstallDir>\CircusVOIP-Servers.exe     <- demarre les deux GUI
        <InstallDir>\CircusVOIP-Positions.exe   <- port 8888 seul
        <InstallDir>\CircusVOIP-Audio.exe       <- port 8889 seul

    Repartition client / serveur : les deux interfaces de serveur (positions
    et audio) vont dans l'installeur serveur, la console d'administration
    (circusvoip_admin.py) part avec le CLIENT -- elle administre un serveur a
    distance et n'a rien a faire sur la machine qui l'heberge.

.PARAMETER Component
    client, server ou both. Defaut : client.

.PARAMETER Deps
    Niveau de dependances pre-installees dans le runtime :
      bundled : tout sauf le moteur OCR (installeur ~104 Mo). Le moteur est
                telecharge soit en fin d'installation (choix propose a
                l'utilisateur), soit par le bootstrap pip du client au premier
                lancement.
      full    : ajoute le moteur OCR (easyocr + torch) selon -OcrBackend :
                +243 Mo en CPU, +2 Go en CUDA. Aucun telechargement ensuite.
      none    : runtime nu (build de test rapide).
    Defaut : bundled. Ignore pour le serveur (toujours websockets+cryptography).

.PARAMETER OcrBackend
    Variante de PyTorch utilisee par le moteur OCR :
      cpu  : build CPU (243 Mo de telechargement pour tout le moteur).
             C'est deja ce que donne PyPI sous Windows, et ca fonctionne avec
             n'importe quelle carte graphique -- AMD, Intel ou NVIDIA.
      cuda : build CUDA depuis l'index PyTorch (~2 Go). OCR nettement plus
             rapide, mais carte NVIDIA obligatoire.
    Defaut : cpu.

    Le choix est materialise par un extra-index-url ecrit dans
    runtime\pip.ini : tout pip lance ensuite dans ce runtime -- y compris le
    bootstrap du client au premier lancement -- resout la bonne variante. Avec
    -Deps bundled, l'installeur propose le choix a l'utilisateur final et
    reecrit cette cle ; -OcrBackend ne fait alors que fixer la valeur par
    defaut du payload.

.PARAMETER Version
    Force la version affichee (ex. 0.2.0). Par defaut, lue dans
    client\circusvoip_version.json (resp. server\circusvoip_version.json).

.PARAMETER Build
    Force le numero de build. Par defaut lu dans le meme fichier.

.PARAMETER Channel
    stable / rc / beta / alpha. Par defaut lu dans le meme fichier.
    'stable' fait afficher "0.2.0" dans le titre du client, sinon
    "0.2.0 alpha 057" (cf. _format_version_string).

.PARAMETER PythonVersion
    Serie CPython du runtime embarque. Defaut : 3.12.

.PARAMETER IsccPath
    Chemin explicite vers ISCC.exe (le compilateur Inno Setup 6).

.PARAMETER InstallInnoSetup
    Telecharge et installe Inno Setup 6 en silencieux s'il est absent.
    Opt-in explicite : rien n'est installe sur la machine sans ce flag.

.PARAMETER FullQt
    Utilise le wheel PySide6 complet au lieu de PySide6-Essentials.

.PARAMETER Clean
    Vide installer\work avant de builder (force la re-extraction du runtime et
    la reinstallation des dependances).

.PARAMETER SkipPrune
    Ne supprime pas les fichiers inutiles du runtime (test suite, idlelib,
    outils Qt...). Utile pour diagnostiquer un import manquant.

.PARAMETER NoPlaceholders
    N'genere pas les assets manquants (StarCircus.ico, sounds\alarm.wav).

.EXAMPLE
    .\installer\build-installer.ps1
    Build client, dependances bundled.

.EXAMPLE
    .\installer\build-installer.ps1 -Component both -Deps bundled -InstallInnoSetup

.EXAMPLE
    .\installer\build-installer.ps1 -Deps none -Clean
    Build de test rapide (pas de pip install).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('client', 'server', 'both')]
    [string]$Component = 'client',

    [ValidateSet('bundled', 'full', 'none')]
    [string]$Deps = 'bundled',

    [ValidateSet('cpu', 'cuda')]
    [string]$OcrBackend = 'cpu',

    [string]$Version,
    [int]$Build = -1,

    [ValidateSet('stable', 'release', 'rc', 'beta', 'alpha', 'dev')]
    [string]$Channel,

    [string]$PythonVersion = '3.12',
    [string]$IsccPath,
    [switch]$InstallInnoSetup,
    [switch]$FullQt,
    [switch]$Clean,
    [switch]$SkipPrune,
    [switch]$NoPlaceholders
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ----------------------------------------------------------------------
# Constantes
# ----------------------------------------------------------------------

$ScriptDir = $PSScriptRoot
$RepoRoot  = Split-Path -Parent $ScriptDir
$CacheDir  = Join-Path $ScriptDir '.cache'
$WorkRoot  = Join-Path $ScriptDir 'work'
$OutDir    = Join-Path $ScriptDir 'out'

# python-build-standalone : releases taguees par date (ex. 20260805).
# On resout l'asset dynamiquement via l'API GitHub ; ce fallback sert si
# l'API est injoignable (rate limit, pas de reseau sortant vers api.github).
$PbsFallbackUrl = 'https://github.com/astral-sh/python-build-standalone/releases/download/20260805/cpython-3.12.13+20260805-x86_64-pc-windows-msvc-install_only.tar.gz'

# Inno Setup (utilise seulement avec -InstallInnoSetup). Les binaires officiels
# sont publies comme assets de release GitHub (jrsoftware.org/isdl.php ne fait
# que pointer dessus ; download.php/is.exe renvoie une page HTML, pas l'exe).
# On reste sur la serie 6 : les .iss de ce dossier la ciblent, et la serie 7
# est un changement majeur. Un Inno Setup 7 deja installe est detecte et
# utilise tel quel.
$InnoSetupApi = 'https://api.github.com/repos/jrsoftware/issrc/releases'
$InnoSetupFallbackUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe'

# Modules que l'installeur doit embarquer. Une absence est fatale : le client
# les importe (circusvoip_security pour le TLS, circusvoip_audio_rx_logger pour
# le log audio RX) et une release amputee planterait chez les joueurs.
$ClientModules = @(
    'circusvoip_client.py',
    'circusvoip_core.py',
    'circusvoip_audio_io.py',
    'circusvoip_sc_ocr.py',
    'circusvoip_security.py',
    'circusvoip_audio_rx_logger.py'
)

$ServerModules = @(
    'circusvoip_server.py',
    'circusvoip_audio_server.py',
    'circusvoip_security.py',
    'circusvoip_server_config.py',
    'circusvoip_update_server.py'
)

# Modules pris dans l'AUTRE dossier source. circusvoip_admin.py vit dans
# server\ parce qu'il parle le protocole d'administration du serveur, mais
# c'est une console d'administration DISTANTE (wss:// vers le port 8888) :
# elle a sa place sur le poste de l'administrateur, pas sur la machine qui
# heberge les serveurs -- laquelle sera souvent un VPS ou un docker compose,
# sans session graphique. On l'embarque donc avec le client.
#
# Ses dependances sont deja la cote client : websockets, tkinter (fourni par
# le runtime, cf. Optimize-Runtime) et circusvoip_security, dont la copie
# client expose bien build_client_ssl_context_insecure().
$ClientExtraModules = @(
    @{ From = 'server'; File = 'circusvoip_admin.py' }
)

# Lanceurs .exe compiles pour le serveur (cf. installer\launcher\, qui
# detaille le pourquoi). En resume : un raccourci vers pythonw.exe ne sait
# demarrer qu'un seul script, et n'est pas un fichier qu'on peut copier,
# epingler ou appeler depuis une tache planifiee.
$ServerLaunchers = @(
    @{ Name    = 'CircusVOIP-Servers'
       Title   = 'CircusVOIP - Serveurs'
       Scripts = @('circusvoip_server.py', 'circusvoip_audio_server.py') },
    @{ Name    = 'CircusVOIP-Positions'
       Title   = 'CircusVOIP - Serveur de positions'
       Scripts = @('circusvoip_server.py') },
    @{ Name    = 'CircusVOIP-Audio'
       Title   = 'CircusVOIP - Serveur audio'
       Scripts = @('circusvoip_audio_server.py') }
)

# Icones embarquees dans app\, par composant. Chaque application a la sienne :
# le client, la console d'administration livree avec lui, et les serveurs.
#
# 'Name' est le nom dans le payload -- c'est celui que les .iss referencent, ne
# pas le changer sans les mettre a jour. 'Candidates' est essaye dans l'ordre,
# chemins relatifs a la racine du depot ; le dernier fait office de repli quand
# l'icone dediee n'a pas ete fournie. Si aucun candidat n'existe, un
# placeholder est genere sous ce nom.
#
# La PREMIERE entree est l'icone principale du composant : celle de
# l'installeur (SetupIconFile), de l'entree "Applications installees" et, cote
# serveur, celle qu'embarquent les lanceurs compiles.
$ClientIcons = @(
    @{ Name = 'StarCircus.ico'
       Candidates = @('client\StarCircus.ico') },
    @{ Name = 'StarCircusAdmin.ico'
       Candidates = @('client\StarCircusAdmin.ico', 'client\StarCircus.ico') }
)
$ServerIcons = @(
    @{ Name = 'StarCircusServer.ico'
       Candidates = @('server\StarCircusServer.ico', 'client\StarCircus.ico') }
)

# Assets optionnels : le code a un fallback silencieux pour chacun (sonneries
# telephone synthetisees si les wav manquent), sauf alarm.wav dont le
# soundboard n'a pas de fallback. Les icones sont traitees a part, cf.
# $ClientIcons / $ServerIcons.
$ClientSounds = @(
    'ring.wav',      # sonnerie destinataire  (fallback synth)
    'dial.wav',      # tonalite appelant      (fallback synth)
    'notif.wav',     # notification message   (fallback synth)
    'alarm.wav'      # soundboard             (PAS de fallback)
)

# Dependances pip. 'required' : un echec arrete le build. 'optional' : un echec
# est un warning (feature degradee mais client fonctionnel, chaque import est
# dans un try/except cote code).
$ClientDepsRequired = @(
    'websockets>=12,<14',
    'numpy>=1.26,<3',
    # Aucun cv2.imshow dans le code -> le wheel headless suffit et pese moins.
    # Borne <5 : le code a ete ecrit contre l'API OpenCV 4.x, et 5.0 est sorti.
    'opencv-python-headless>=4.9,<5',
    'mss>=9',
    'sounddevice>=0.4',
    'pynput>=1.7',
    'psutil>=5.9',
    'cryptography>=42',
    'Pillow>=10'                     # photos de profil CircusPhone
)
$ClientDepsOptional = @(
    'nvidia-ml-py',                  # module pynvml : metriques GPU
    'pytesseract',                   # fallback OCR (necessite tesseract.exe)
    'bettercam'                      # capture DirectX rapide (fallback MSS)

    # PAS de 'pyrnnoise' (suppression de bruit RNNoise) : la chaine publiee
    # sur PyPI est cassee. pyrnnoise 0.4.3 importe audiolab des le chargement
    # du module, audiolab 0.5.1 fait `from av.option import OptionType`, et av
    # 18 n'expose plus av.option -> ImportError. Cela coute 132 Mo (av,
    # matplotlib, soundfile, requests...) pour une feature qui ne demarre pas.
    # Le client gere l'absence : NOISE_SUPPRESSION_AVAILABLE = False et la
    # case correspondante est grisee. Pour retenter, ajouter ici 'pyrnnoise'
    # et une borne sur av ('av<15') et verifier l'import avant de publier.
)
$ClientDepsFull = @(
    'easyocr>=1.7'                   # tire torch + torchvision
)

# Index PyTorch par variante. Sous Windows, PyPI ne publie QUE des wheels torch
# CPU (~116 Mo) : les builds CUDA (1,8 a 2,7 Go selon la version de CUDA)
# vivent uniquement sur download.pytorch.org. Autrement dit, sans intervention,
# personne ne telecharge de payload CUDA -- et personne n'a d'acceleration GPU
# non plus, malgre la detection torch.cuda.is_available() cote client.
#
# On materialise le choix par un extra-index-url dans runtime\pip.ini (pip le
# lit comme configuration "site" du prefixe). Une version locale PEP 440
# (2.13.0+cu130) l'emporte sur la version simple (2.13.0) : un simple
# `pip install easyocr` resout donc la bonne variante, y compris quand c'est le
# bootstrap du client qui le lance au premier lancement. Aucune modification
# des sources n'est necessaire -- ce qui compte, car l'updater integre
# reecrase les .py depuis le manifeste du serveur.
$TorchIndexUrls = @{
    cpu  = 'https://download.pytorch.org/whl/cpu'
    cuda = 'https://download.pytorch.org/whl/cu130'
}
$ServerDepsRequired = @(
    'websockets>=12,<14',
    'cryptography>=42'
)

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    WARN: $Message" -ForegroundColor Yellow
}

function Invoke-NativeRaw {
    <#
        Lance un executable sans jamais lever ; l'appelant teste $LASTEXITCODE.

        Deux pieges PowerShell 5.1 sont neutralises ici :

        1. La sortie stderr d'un exe natif devient un ErrorRecord des que la
           sortie est redirigee (`.\build.ps1 *> log`, un pipe vers
           Select-String, un runner CI...). Avec $ErrorActionPreference =
           'Stop', un simple warning pip suffirait a casser le build : on
           neutralise donc la preference localement.
        2. Cette fonction ne retourne PAS le code de sortie : la sortie de
           l'exe circule deja dans le flux de succes, et un `return
           $LASTEXITCODE` la ferait suivre dans la valeur de retour (qui
           deviendrait un tableau). $LASTEXITCODE etant global, il reste
           lisible par l'appelant apres l'appel.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $ErrorActionPreference = 'Continue'
    # 2>&1 + normalisation : sans ca, une ligne pip sur stderr ressort dans un
    # bloc rouge "NativeCommandError" avec sa stack PowerShell des que la
    # sortie est redirigee (log de build, runner CI), ce qui se lit comme un
    # echec alors que la commande a reussi.
    & $FilePath @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            Write-Host $_.Exception.Message
        } else {
            Write-Host $_
        }
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$What
    )
    if (-not $What) { $What = Split-Path -Leaf $FilePath }
    Invoke-NativeRaw -FilePath $FilePath -Arguments $Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$What a echoue (code $LASTEXITCODE) : $FilePath $($Arguments -join ' ')"
    }
}

function New-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-CurlPath {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) { return $curl }
    $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'curl.exe introuvable (fourni avec Windows 10 1803+).'
}

function Get-TarPath {
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path -LiteralPath $tar) { return $tar }
    $cmd = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'tar.exe introuvable (fourni avec Windows 10 1803+).'
}

function Save-Url {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        # 'MZ' pour un .exe, 'gz' pour un .tar.gz : plusieurs serveurs
        # repondent 200 avec une page HTML au lieu du binaire attendu, ce que
        # --fail ne detecte pas.
        [ValidateSet('none', 'exe', 'gz')][string]$Expect = 'none'
    )
    $curl = Get-CurlPath
    $tmp  = "$Destination.part"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    Invoke-Native -FilePath $curl -What 'curl' -Arguments @(
        '-L', '--fail', '--retry', '3', '--retry-delay', '2',
        '--progress-bar', '-o', $tmp, $Url
    )

    if ($Expect -ne 'none') {
        $fs = [System.IO.File]::OpenRead($tmp)
        try {
            $magic = New-Object byte[] 2
            $read = $fs.Read($magic, 0, 2)
        } finally {
            $fs.Dispose()
        }
        $ok = $false
        if ($read -eq 2) {
            if ($Expect -eq 'exe') { $ok = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x5A) }   # MZ
            if ($Expect -eq 'gz')  { $ok = ($magic[0] -eq 0x1F -and $magic[1] -eq 0x8B) }   # gzip
        }
        if (-not $ok) {
            $size = (Get-Item -LiteralPath $tmp).Length
            Remove-Item -LiteralPath $tmp -Force
            throw "Le telechargement de $Url n'est pas un fichier $Expect valide ($size octets). URL de mirroir ou page HTML d'interstitiel ?"
        }
    }

    Move-Item -LiteralPath $tmp -Destination $Destination -Force
}

# ----------------------------------------------------------------------
# 1. Validation de l'arbre de travail
# ----------------------------------------------------------------------

function Test-SourceTree {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string[]]$Modules,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $missing = @()
    foreach ($m in $Modules) {
        if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $m))) {
            $missing += $m
        }
    }
    if ($missing.Count -gt 0) {
        $list = ($missing | ForEach-Object { "  - $_" }) -join "`n"
        throw @"
Modules $Label manquants dans $SourceDir :
$list

Ces fichiers sont importes au runtime : un installeur construit sans eux
planterait a l'usage. S'ils sont supprimes dans l'arbre de travail sans
l'etre dans le depot, les restaurer avant de builder :

    git restore $Label/
"@
    }
}

# ----------------------------------------------------------------------
# 2. Version
# ----------------------------------------------------------------------

function Resolve-VersionInfo {
    param([Parameter(Mandatory = $true)][string]$SourceDir)

    $info = [ordered]@{ version = '0.0.0'; channel = 'alpha'; build = 0 }
    $file = Join-Path $SourceDir 'circusvoip_version.json'
    if (Test-Path -LiteralPath $file) {
        $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
        if ($json.PSObject.Properties['version']) { $info.version = [string]$json.version }
        if ($json.PSObject.Properties['channel']) { $info.channel = [string]$json.channel }
        if ($json.PSObject.Properties['build'])   { $info.build   = [int]$json.build }
    } else {
        Write-Warn "circusvoip_version.json absent de $SourceDir : valeurs par defaut."
    }

    if ($Version)      { $info.version = $Version }
    if ($Channel)      { $info.channel = $Channel }
    if ($Build -ge 0)  { $info.build   = $Build }

    if ($info.version -notmatch '^\d+\.\d+(\.\d+)?$') {
        throw "Version invalide '$($info.version)' : attendu X.Y ou X.Y.Z."
    }
    return $info
}

function Get-VersionInfoQuad {
    param([Parameter(Mandatory = $true)]$Info)
    # VersionInfoVersion d'Inno veut du numerique : X.Y.Z.build
    $v = $Info.version
    $parts = $v.Split('.')
    while ($parts.Count -lt 3) { $parts += '0' }
    return "$($parts[0]).$($parts[1]).$($parts[2]).$($Info.build)"
}

# ----------------------------------------------------------------------
# 3. Runtime python-build-standalone
# ----------------------------------------------------------------------

function Resolve-PbsAssetUrl {
    param([Parameter(Mandatory = $true)][string]$Series)

    $pattern = "^cpython-$([regex]::Escape($Series))\.\d+\+\d+-x86_64-pc-windows-msvc-install_only\.tar\.gz$"
    try {
        $api = 'https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest'
        $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'CircusVOIP-build' } -TimeoutSec 30
        foreach ($asset in $rel.assets) {
            if ($asset.name -match $pattern) {
                Write-Note "Runtime : $($asset.name) (release $($rel.tag_name))"
                return $asset.browser_download_url
            }
        }
        Write-Warn "Aucun asset CPython $Series dans la derniere release PBS ($($rel.tag_name))."
    } catch {
        Write-Warn "API GitHub injoignable ($($_.Exception.Message))."
    }

    if ($PythonVersion -ne '3.12') {
        throw "Impossible de resoudre un runtime CPython $Series et le fallback code en dur est en 3.12."
    }
    Write-Warn 'Utilisation de l''URL de fallback codee en dur.'
    return $PbsFallbackUrl
}

function Initialize-Runtime {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDir,
        [Parameter(Mandatory = $true)][string]$WorkDir
    )
    if (Test-Path -LiteralPath (Join-Path $RuntimeDir 'python.exe')) {
        Write-Note 'Runtime deja extrait (reutilise ; -Clean pour repartir de zero).'
        return
    }

    New-Dir $CacheDir
    $url      = Resolve-PbsAssetUrl -Series $PythonVersion
    $fileName = [System.IO.Path]::GetFileName(($url -split '\?')[0])
    $tarball  = Join-Path $CacheDir $fileName

    if (Test-Path -LiteralPath $tarball) {
        Write-Note "Archive en cache : $fileName"
    } else {
        Write-Note "Telechargement : $url"
        Save-Url -Url $url -Destination $tarball -Expect gz
    }

    # L'archive PBS install_only se deplie en python\ ; on la renomme runtime\.
    $extractDir = Join-Path $WorkDir '_pbs'
    if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
    New-Dir $extractDir
    Write-Note 'Extraction du runtime...'
    Invoke-Native -FilePath (Get-TarPath) -What 'tar' -Arguments @('-xzf', $tarball, '-C', $extractDir)

    $inner = Join-Path $extractDir 'python'
    if (-not (Test-Path -LiteralPath $inner)) {
        throw "Structure d'archive inattendue : $inner absent."
    }
    if (Test-Path -LiteralPath $RuntimeDir) { Remove-Item -LiteralPath $RuntimeDir -Recurse -Force }
    Move-Item -LiteralPath $inner -Destination $RuntimeDir
    Remove-Item -LiteralPath $extractDir -Recurse -Force

    $py = Join-Path $RuntimeDir 'python.exe'
    if (-not (Test-Path -LiteralPath $py)) { throw "python.exe absent de $RuntimeDir." }

    # pip est indispensable : le bootstrap du client s'en sert au premier
    # lancement pour installer easyocr/torch (cf. _bootstrap_dependencies).
    Invoke-NativeRaw -FilePath $py -Arguments @('-m', 'pip', '--version')
    if ($LASTEXITCODE -ne 0) {
        Write-Note 'pip absent du runtime : ensurepip...'
        Invoke-Native -FilePath $py -What 'ensurepip' -Arguments @('-m', 'ensurepip', '--upgrade')
    }
    Write-Note "Runtime pret : $((& $py -c 'import sys; print(sys.version.split()[0])'))"
}

function Set-RuntimePipConfig {
    <#
        Ecrit runtime\pip.ini pour fixer la variante de torch.

        pip lit ce fichier comme configuration "site" ({sys.prefix}\pip.ini),
        donc tout pip lance avec ce runtime en herite : l'installation faite
        ici au build, celle que l'installeur propose en fin de parcours, et
        surtout le bootstrap du client au premier lancement.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDir,
        [Parameter(Mandatory = $true)][ValidateSet('cpu', 'cuda')][string]$Backend
    )
    $url = $TorchIndexUrls[$Backend]
    $ini = "[global]`r`nextra-index-url = $url`r`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $RuntimeDir 'pip.ini'), $ini, [System.Text.Encoding]::ASCII
    )
    Write-Note "Variante OCR : $Backend ($url)"
}

function Install-RuntimeDeps {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDir,
        [string[]]$Required = @(),
        [string[]]$Optional = @(),
        [Parameter(Mandatory = $true)][string]$Tier,
        # Valeur ecrite dans le marqueur. Distincte du tier pour que changer de
        # -OcrBackend invalide un runtime deja prepare.
        [string]$MarkerValue
    )
    $py     = Join-Path $RuntimeDir 'python.exe'
    $marker = Join-Path $RuntimeDir '.circusvoip-deps'
    if (-not $MarkerValue) { $MarkerValue = $Tier }

    if (Test-Path -LiteralPath $marker) {
        $done = (Get-Content -LiteralPath $marker -Raw).Trim()
        if ($done -eq $MarkerValue) {
            Write-Note "Dependances '$MarkerValue' deja installees dans le runtime."
            return
        }
        Write-Note "Marqueur de deps '$done' != '$MarkerValue' : reinstallation."
    }

    if ($Tier -eq 'none') {
        Write-Note 'Tier none : aucune dependance pre-installee.'
        Set-Content -LiteralPath $marker -Value $MarkerValue -Encoding ASCII
        return
    }

    Invoke-Native -FilePath $py -What 'pip (upgrade pip)' -Arguments @(
        '-m', 'pip', 'install', '--upgrade', '--no-warn-script-location', 'pip'
    )

    # --only-binary : evite qu'un package sans wheel tente une compilation
    # (pas de MSVC garanti sur la machine de build).
    $common = @('-m', 'pip', 'install', '--upgrade', '--only-binary=:all:', '--no-warn-script-location')

    if ($Required.Count -gt 0) {
        Write-Note "Installation des dependances obligatoires ($($Required.Count))..."
        Invoke-Native -FilePath $py -What 'pip install' -Arguments ($common + $Required)
    }

    $failed = @()
    foreach ($pkg in $Optional) {
        Write-Note "Optionnel : $pkg"
        Invoke-NativeRaw -FilePath $py -Arguments ($common + @($pkg))
        if ($LASTEXITCODE -ne 0) { $failed += $pkg }
    }
    if ($failed.Count -gt 0) {
        Write-Warn "Dependances optionnelles non installees : $($failed -join ', ')"
        Write-Warn 'Les features correspondantes seront degradees (fallback code cote client).'
    }

    Set-Content -LiteralPath $marker -Value $MarkerValue -Encoding ASCII
}

function Install-QtDep {
    param([Parameter(Mandatory = $true)][string]$RuntimeDir)
    $py = Join-Path $RuntimeDir 'python.exe'
    if ($FullQt) {
        $spec = 'PySide6>=6.6,<7'
    } else {
        # Le code n'importe que QtCore / QtGui / QtWidgets : Essentials suffit
        # et pese bien moins lourd que le wheel PySide6 complet.
        $spec = 'PySide6-Essentials>=6.6,<7'
    }
    Write-Note "Qt : $spec"
    Invoke-Native -FilePath $py -What 'pip install (Qt)' -Arguments @(
        '-m', 'pip', 'install', '--upgrade', '--only-binary=:all:',
        '--no-warn-script-location', $spec
    )
}

function Optimize-Runtime {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDir
    )
    if ($SkipPrune) {
        Write-Note 'Pruning desactive (-SkipPrune).'
        return
    }

    $before = Get-DirSizeMb $RuntimeDir

    # Chemins surs a supprimer : jamais importes au runtime par le projet.
    # NE PAS toucher a pip\_vendor\distlib\*.exe : ces stubs (t32/t64/w32/w64)
    # sont les lanceurs que pip pose pour les console_scripts. Sans eux, tout
    # 'pip install' echoue avec "Unable to find resource t64.exe", et le
    # bootstrap du client au premier lancement (easyocr/torch) est mort.
    $targets = @(
        'Lib\test',
        'Lib\idlelib',
        'Lib\site-packages\PySide6\examples',
        'Lib\site-packages\PySide6\include',
        'Lib\site-packages\PySide6\glue',
        'Lib\site-packages\PySide6\typesystems',
        'Lib\site-packages\PySide6\support',
        'Lib\site-packages\PySide6\scripts',
        'Lib\site-packages\PySide6\translations',
        'Lib\site-packages\PySide6\qml',
        'Lib\site-packages\PySide6\Designer.exe',
        'Lib\site-packages\PySide6\assistant.exe',
        'Lib\site-packages\PySide6\linguist.exe',
        'Lib\site-packages\PySide6\lupdate.exe',
        'Lib\site-packages\PySide6\lrelease.exe',
        'Lib\site-packages\shiboken6\include'
    )
    # tkinter (~12 Mo) etait elague cote client, qui ne l'importe pas : son
    # interface est en Qt. Il est desormais conserve dans les deux runtimes,
    # parce que le client embarque aussi la console d'administration
    # (circusvoip_admin.py), et celle-la est en tkinter.

    foreach ($rel in $targets) {
        $full = Join-Path $RuntimeDir $rel
        if ($rel.Contains('*')) {
            Get-ChildItem -Path $full -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } elseif (Test-Path -LiteralPath $full) {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Get-ChildItem -LiteralPath $RuntimeDir -Directory -Recurse -Filter '__pycache__' -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    $after = Get-DirSizeMb $RuntimeDir
    Write-Note ("Pruning : {0:N0} Mo -> {1:N0} Mo" -f $before, $after)
}

function Get-DirSizeMb {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return 0 }
    return $sum / 1MB
}

# ----------------------------------------------------------------------
# 4. Payload app\
# ----------------------------------------------------------------------

function New-AppPayload {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$AppDir,
        [Parameter(Mandatory = $true)][string[]]$Modules,
        [Parameter(Mandatory = $true)]$VersionInfo,
        # Modules venant d'un autre dossier du depot : @{ From = 'server'; File = '...' }
        [array]$ExtraModules = @(),
        [switch]$IsClient
    )
    if (Test-Path -LiteralPath $AppDir) { Remove-Item -LiteralPath $AppDir -Recurse -Force }
    New-Dir $AppDir

    foreach ($m in $Modules) {
        Copy-Item -LiteralPath (Join-Path $SourceDir $m) -Destination $AppDir -Force
    }
    $count = $Modules.Count
    foreach ($x in $ExtraModules) {
        $src = Join-Path (Join-Path $RepoRoot $x.From) $x.File
        # Deja valide par Test-SourceTree cote appelant ; on reverifie parce
        # qu'un chemin inter-dossiers est le genre de chose qui casse en
        # silence quand l'arbre bouge.
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Module attendu depuis $($x.From)\ introuvable : $src"
        }
        Copy-Item -LiteralPath $src -Destination $AppDir -Force
        Write-Note "$($x.File) repris depuis $($x.From)\"
        $count++
    }
    Write-Note "$count module(s) .py stage(s)."

    # circusvoip_version.json regenere depuis les valeurs resolues : c'est ce
    # fichier que le client lit pour le titre de fenetre et la comparaison de
    # version avec le serveur d'update.
    $verJson = [ordered]@{
        version = $VersionInfo.version
        channel = $VersionInfo.channel
        build   = $VersionInfo.build
    } | ConvertTo-Json
    # Pas de BOM : le lecteur cote client tolere utf-8-sig, mais autant rester
    # sur de l'UTF-8 nu.
    [System.IO.File]::WriteAllText(
        (Join-Path $AppDir 'circusvoip_version.json'),
        $verJson,
        (New-Object System.Text.UTF8Encoding($false))
    )

    if (-not $IsClient) { return }

    $soundsSrc = Join-Path $SourceDir 'sounds'
    $soundsDst = Join-Path $AppDir 'sounds'
    New-Dir $soundsDst
    foreach ($s in $ClientSounds) {
        $src = Join-Path $soundsSrc $s
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $soundsDst -Force
        }
    }
    # ptt_press.wav / ptt_release.wav sont fournis par l'utilisateur depuis
    # l'onglet Audio : jamais embarques, sinon l'installeur ecraserait les
    # bips personnalises a chaque mise a jour.
}

function Get-PlaceholderScript {
    $gen = Join-Path $ScriptDir 'make-placeholder-assets.py'
    if (-not (Test-Path -LiteralPath $gen)) {
        Write-Warn 'make-placeholder-assets.py absent : assets manquants non generes.'
        return $null
    }
    return $gen
}

function Add-PayloadIcons {
    <#
        Depose dans app\ les icones declarees pour le composant.

        Chaque entree est resolue depuis sa liste de candidats (chemins
        relatifs a la racine du depot, essayes dans l'ordre) ; ce qui reste
        introuvable est remplace par un placeholder genere sous le nom attendu,
        pour que les .iss trouvent toujours le fichier qu'ils referencent.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppDir,
        [Parameter(Mandatory = $true)][string]$RuntimeDir,
        [Parameter(Mandatory = $true)][array]$Icons
    )
    $missing = @()
    foreach ($icon in $Icons) {
        $resolved = $null
        foreach ($cand in $icon.Candidates) {
            $src = Join-Path $RepoRoot $cand
            if (Test-Path -LiteralPath $src) { $resolved = @{ Path = $src; Rel = $cand }; break }
        }
        if ($resolved) {
            Copy-Item -LiteralPath $resolved.Path -Destination (Join-Path $AppDir $icon.Name) -Force
            Write-Note "Icone $($icon.Name) <- $($resolved.Rel)"
        } else {
            $missing += $icon.Name
        }
    }

    if ($missing.Count -eq 0) { return }
    if ($NoPlaceholders) {
        Write-Warn "Icones absentes et placeholders desactives : $($missing -join ', ')"
        Write-Warn 'Les raccourcis retomberont sur l''icone de python.exe.'
        return
    }
    $gen = Get-PlaceholderScript
    if (-not $gen) { return }
    $py = Join-Path $RuntimeDir 'python.exe'
    foreach ($name in $missing) {
        Invoke-Native -FilePath $py -What 'make-placeholder-assets.py' `
            -Arguments @($gen, $AppDir, '--icon-only', '--icon-name', $name)
    }
}

function Add-PlaceholderSounds {
    param(
        [Parameter(Mandatory = $true)][string]$AppDir,
        [Parameter(Mandatory = $true)][string]$RuntimeDir
    )
    if ($NoPlaceholders) {
        Write-Note 'Placeholders desactives (-NoPlaceholders).'
        return
    }
    $gen = Get-PlaceholderScript
    if (-not $gen) { return }
    $py = Join-Path $RuntimeDir 'python.exe'
    Invoke-Native -FilePath $py -What 'make-placeholder-assets.py' `
        -Arguments @($gen, $AppDir, '--sounds-only')
}

# ----------------------------------------------------------------------
# 4bis. Lanceurs .exe
# ----------------------------------------------------------------------

function Resolve-Csc {
    <#
        Localise csc.exe, le compilateur C# du .NET Framework.

        Il fait partie de Windows depuis la 8 (composant .NET Framework 4.x
        installe d'office), y compris sur les runners windows-latest : compiler
        les lanceurs n'ajoute donc aucune dependance de build. On ne cherche
        PAS le csc.exe de Roslyn (SDK .NET moderne) : celui-ci produirait des
        binaires exigeant un runtime .NET a part, la ou le Framework est deja
        present sur toutes les machines cibles.
    #>
    $candidates = @(
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    throw @"
csc.exe introuvable (compilateur C# du .NET Framework 4.x).

Cherche dans :
$(($candidates | ForEach-Object { "  - $_" }) -join "`n")

Il est normalement livre avec Windows. Si le .NET Framework 4.x a ete retire,
le reactiver depuis "Fonctionnalites de Windows".
"@
}

function New-Launchers {
    <#
        Compile un .exe par entree de $ServerLaunchers dans <workDir>\bin\.

        Chaque binaire est le meme code source (installer\launcher\
        launcher-template.cs) avec la liste de scripts et le titre substitues.
        Le chemin du runtime, lui, n'est PAS substitue : le lanceur le resout
        a l'execution par rapport a sa propre position, donc l'installation
        reste deplacable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BinDir,
        [Parameter(Mandatory = $true)][array]$Launchers,
        [string]$IconPath
    )
    $template = Join-Path $ScriptDir 'launcher\launcher-template.cs'
    if (-not (Test-Path -LiteralPath $template)) {
        throw "Modele de lanceur introuvable : $template"
    }
    $csc  = Resolve-Csc
    Write-Note "csc : $csc"

    if (Test-Path -LiteralPath $BinDir) { Remove-Item -LiteralPath $BinDir -Recurse -Force }
    New-Dir $BinDir
    $tmpDir = Join-Path $BinDir '_cs'
    New-Dir $tmpDir

    $source = Get-Content -LiteralPath $template -Raw

    foreach ($l in $Launchers) {
        # Litteraux C# : les noms de scripts sont des identifiants de fichiers
        # du depot (pas d'entree utilisateur), mais on echappe quand meme les
        # antislashs et les guillemets plutot que de le supposer.
        $scriptsLiteral = (
            $l.Scripts | ForEach-Object {
                '"' + ($_ -replace '\\', '\\\\' -replace '"', '\"') + '"'
            }
        ) -join ', '
        $code = $source.Replace('__SCRIPTS__', $scriptsLiteral).Replace('__TITLE__', $l.Title)

        $cs = Join-Path $tmpDir "$($l.Name).cs"
        [System.IO.File]::WriteAllText($cs, $code, (New-Object System.Text.UTF8Encoding($false)))

        $exe = Join-Path $BinDir "$($l.Name).exe"
        # winexe : sous-systeme GUI, donc aucune fenetre de console ne
        # clignote au demarrage -- c'est tout l'interet par rapport a un .bat.
        $cscArgs = @(
            '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
            '/reference:System.dll', '/reference:System.Windows.Forms.dll',
            "/out:$exe"
        )
        if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
            $cscArgs += "/win32icon:$IconPath"
        }
        $cscArgs += $cs
        Invoke-Native -FilePath $csc -What "csc ($($l.Name))" -Arguments $cscArgs
        if (-not (Test-Path -LiteralPath $exe)) {
            throw "Lanceur attendu absent apres compilation : $exe"
        }
        Write-Note "$($l.Name).exe -> $($l.Scripts -join ' + ')"
    }

    Remove-Item -LiteralPath $tmpDir -Recurse -Force
}

# ----------------------------------------------------------------------
# 5. Inno Setup
# ----------------------------------------------------------------------

function Resolve-Iscc {
    if ($IsccPath) {
        if (-not (Test-Path -LiteralPath $IsccPath)) { throw "ISCC.exe introuvable : $IsccPath" }
        return $IsccPath
    }

    # Serie 6 en premier (celle que ciblent les .iss), mais un Inno Setup 7
    # deja installe fait aussi l'affaire.
    $candidates = @()
    foreach ($dir in @('Inno Setup 6', 'Inno Setup 7')) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "$dir\ISCC.exe")
        $candidates += (Join-Path $env:ProgramFiles "$dir\ISCC.exe")
    }
    foreach ($app in @('Inno Setup 6_is1', 'Inno Setup 7_is1')) {
        $regKeys = @(
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$app",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$app",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$app"
        )
        foreach ($k in $regKeys) {
            try {
                $loc = (Get-ItemProperty -Path $k -Name InstallLocation -ErrorAction Stop).InstallLocation
                if ($loc) { $candidates += (Join-Path $loc 'ISCC.exe') }
            } catch { }
        }
    }
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }

    if ($InstallInnoSetup) {
        return Install-InnoSetup
    }

    throw @"
Inno Setup 6 introuvable (ISCC.exe).

Options :
  - relancer avec -InstallInnoSetup (telecharge et installe en silencieux) ;
  - winget install -e --id JRSoftware.InnoSetup ;
  - installer manuellement depuis https://jrsoftware.org/isdl.php ;
  - passer le chemin avec -IsccPath "C:\chemin\ISCC.exe".
"@
}

function Resolve-InnoSetupUrl {
    # Derniere release de la serie 6 (tags 'is-6_x_y', asset 'innosetup-6.x.y.exe').
    try {
        $releases = Invoke-RestMethod -Uri $InnoSetupApi `
            -Headers @{ 'User-Agent' = 'CircusVOIP-build' } -TimeoutSec 30
        foreach ($rel in $releases) {
            if ($rel.tag_name -notlike 'is-6_*') { continue }
            foreach ($asset in $rel.assets) {
                if ($asset.name -match '^innosetup-6\.[\d\.]+\.exe$') {
                    Write-Note "Inno Setup : $($asset.name)"
                    return $asset.browser_download_url
                }
            }
        }
        Write-Warn 'Aucun asset innosetup-6.*.exe trouve dans les releases jrsoftware/issrc.'
    } catch {
        Write-Warn "API GitHub injoignable ($($_.Exception.Message))."
    }
    Write-Warn 'Utilisation de l''URL Inno Setup de fallback codee en dur.'
    return $InnoSetupFallbackUrl
}

function Install-InnoSetup {
    Write-Step 'Installation d''Inno Setup 6 (silencieuse)'
    New-Dir $CacheDir
    $url = Resolve-InnoSetupUrl
    $exe = Join-Path $CacheDir ([System.IO.Path]::GetFileName(($url -split '\?')[0]))
    if (Test-Path -LiteralPath $exe) {
        Write-Note "Installeur en cache : $(Split-Path -Leaf $exe)"
    } else {
        Save-Url -Url $url -Destination $exe -Expect exe
    }
    $proc = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-'
    )
    if ($proc.ExitCode -ne 0) {
        throw "L'installation d'Inno Setup a echoue (code $($proc.ExitCode))."
    }

    # Un setup Inno se re-lance depuis %TEMP% : le process parent rend la main
    # avant la fin reelle de l'installation. On attend donc l'apparition de
    # ISCC.exe plutot que la fin du process.
    Write-Note 'Attente de la fin de l''installation...'
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        foreach ($dir in @('Inno Setup 6', 'Inno Setup 7')) {
            foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
                $c = Join-Path $pf "$dir\ISCC.exe"
                if (Test-Path -LiteralPath $c) {
                    Write-Note "ISCC : $c"
                    return $c
                }
            }
        }
        Start-Sleep -Seconds 2
    }
    throw 'Inno Setup installe mais ISCC.exe introuvable apres 3 minutes.'
}

function Invoke-Iscc {
    param(
        [Parameter(Mandatory = $true)][string]$Iscc,
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string]$PayloadDir,
        [Parameter(Mandatory = $true)]$VersionInfo,
        [Parameter(Mandatory = $true)][string]$OutputBaseFilename,
        [Parameter(Mandatory = $true)][string]$DepsTier,
        [string[]]$ExtraDefines = @()
    )
    New-Dir $OutDir
    $isccArgs = @(
        "/DPayloadDir=$PayloadDir",
        "/DAppVersion=$($VersionInfo.version)",
        "/DVersionQuad=$(Get-VersionInfoQuad $VersionInfo)",
        "/DVersionChannel=$($VersionInfo.channel)",
        "/DVersionBuild=$($VersionInfo.build)",
        "/DDepsTier=$DepsTier",
        "/DOutDir=$OutDir",
        "/DOutName=$OutputBaseFilename"
    ) + $ExtraDefines + @($Script)
    Invoke-Native -FilePath $Iscc -What 'ISCC' -Arguments $isccArgs
}

# ----------------------------------------------------------------------
# Build d'un composant
# ----------------------------------------------------------------------

function Build-Component {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('client', 'server')][string]$Name,
        [Parameter(Mandatory = $true)][string]$Iscc
    )

    $isClient  = ($Name -eq 'client')
    $sourceDir = Join-Path $RepoRoot $Name
    $workDir   = Join-Path $WorkRoot $Name
    $appDir    = Join-Path $workDir 'app'
    $binDir    = Join-Path $workDir 'bin'
    $runtime   = Join-Path $workDir 'runtime'

    if ($isClient) {
        $modules = $ClientModules
        $extras  = $ClientExtraModules
    } else {
        $modules = $ServerModules
        $extras  = @()
    }

    Write-Step "Build $Name : validation des sources"
    if (-not (Test-Path -LiteralPath $sourceDir)) { throw "Dossier source absent : $sourceDir" }
    Test-SourceTree -SourceDir $sourceDir -Modules $modules -Label $Name
    # Les modules repris dans l'autre dossier sont valides la aussi : mieux
    # vaut echouer ici, avec le message qui dit ou regarder, qu'a la copie.
    foreach ($x in $extras) {
        Test-SourceTree -SourceDir (Join-Path $RepoRoot $x.From) `
            -Modules @($x.File) -Label $x.From
    }

    $verInfo = Resolve-VersionInfo -SourceDir $sourceDir
    Write-Note "Version : $($verInfo.version) $($verInfo.channel) $('{0:d3}' -f $verInfo.build)"

    New-Dir $workDir

    Write-Step "Build $Name : runtime Python embarque"
    Initialize-Runtime -RuntimeDir $runtime -WorkDir $workDir

    Write-Step "Build $Name : dependances"
    if ($isClient) {
        # Avant tout pip : la variante torch doit etre fixee pour que
        # l'eventuel easyocr du tier 'full' resolve la bonne.
        Set-RuntimePipConfig -RuntimeDir $runtime -Backend $OcrBackend
        $tier       = $Deps
        $markerVal  = "$tier+$OcrBackend"
        if ($tier -eq 'none') {
            Install-RuntimeDeps -RuntimeDir $runtime -Tier 'none' -MarkerValue $markerVal
        } else {
            $required = $ClientDepsRequired
            if ($tier -eq 'full') { $required = $required + $ClientDepsFull }
            $marker = Join-Path $runtime '.circusvoip-deps'
            $alreadyDone = $false
            if (Test-Path -LiteralPath $marker) {
                $alreadyDone = ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $markerVal)
            }
            if (-not $alreadyDone) { Install-QtDep -RuntimeDir $runtime }
            Install-RuntimeDeps -RuntimeDir $runtime -Required $required `
                -Optional $ClientDepsOptional -Tier $tier -MarkerValue $markerVal
        }
    } else {
        Install-RuntimeDeps -RuntimeDir $runtime -Required $ServerDepsRequired -Tier 'server'
    }

    Write-Step "Build $Name : payload app\"
    New-AppPayload -SourceDir $sourceDir -AppDir $appDir -Modules $modules `
        -ExtraModules $extras -VersionInfo $verInfo -IsClient:$isClient
    if ($isClient) { $icons = $ClientIcons } else { $icons = $ServerIcons }
    Add-PayloadIcons -AppDir $appDir -RuntimeDir $runtime -Icons $icons
    if ($isClient) {
        Add-PlaceholderSounds -AppDir $appDir -RuntimeDir $runtime
    }

    if (-not $isClient) {
        Write-Step "Build $Name : lanceurs .exe"
        # Icone principale du composant = premiere entree de $ServerIcons.
        $icon = Join-Path $appDir $ServerIcons[0].Name
        New-Launchers -BinDir $binDir -Launchers $ServerLaunchers -IconPath $icon
    }

    Write-Step "Build $Name : nettoyage du runtime"
    Optimize-Runtime -RuntimeDir $runtime

    Write-Step "Build $Name : compilation Inno Setup"
    $extraDefines = @()
    if ($isClient) {
        $iss  = Join-Path $ScriptDir 'client.iss'
        $base = "CircusVOIP_Client_Setup_v$($verInfo.version)"
        $tierLabel = $Deps
        $extraDefines += "/DOcrBackend=$OcrBackend"
        # Moteur OCR embarque -> l'installeur ne propose pas le choix.
        if ($Deps -eq 'full') { $extraDefines += '/DOcrBundled=1' }
    } else {
        $iss  = Join-Path $ScriptDir 'server.iss'
        $base = "CircusVOIP_Server_Setup_v$($verInfo.version)"
        $tierLabel = 'server'
    }
    if ($verInfo.channel -ne 'stable') {
        $base = "$base-$($verInfo.channel)$('{0:d3}' -f $verInfo.build)"
    }

    Invoke-Iscc -Iscc $Iscc -Script $iss -PayloadDir $workDir -VersionInfo $verInfo `
        -OutputBaseFilename $base -DepsTier $tierLabel -ExtraDefines $extraDefines

    $out = Join-Path $OutDir "$base.exe"
    if (-not (Test-Path -LiteralPath $out)) { throw "Installeur attendu absent : $out" }
    $mb = (Get-Item -LiteralPath $out).Length / 1MB
    Write-Host ("    OK : {0} ({1:N1} Mo)" -f $out, $mb) -ForegroundColor Green
    return $out
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

Write-Host ''
Write-Host 'CircusVOIP - build des installeurs Windows' -ForegroundColor White
Write-Note "Depot        : $RepoRoot"
Write-Note "Composant(s) : $Component"
Write-Note "Dependances  : $Deps"
Write-Note "Variante OCR : $OcrBackend"
Write-Note "Runtime      : CPython $PythonVersion (python-build-standalone, x86_64)"

if ($Clean -and (Test-Path -LiteralPath $WorkRoot)) {
    Write-Step 'Nettoyage de installer\work'
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force
}
New-Dir $WorkRoot
New-Dir $OutDir

Write-Step 'Recherche du compilateur Inno Setup'
$iscc = Resolve-Iscc
Write-Note "ISCC : $iscc"

$built = @()
if ($Component -eq 'client' -or $Component -eq 'both') {
    $built += Build-Component -Name 'client' -Iscc $iscc
}
if ($Component -eq 'server' -or $Component -eq 'both') {
    $built += Build-Component -Name 'server' -Iscc $iscc
}

Write-Host ''
Write-Host 'Termine.' -ForegroundColor Green
foreach ($b in $built) { Write-Host "  $b" }
Write-Host ''
