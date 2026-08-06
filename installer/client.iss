; ======================================================================
;  CircusVOIP - installeur client (Inno Setup 6)
; ======================================================================
;  Ne pas compiler directement : les defines viennent de
;  installer\build-installer.ps1, qui prepare d'abord le payload
;  (runtime Python embarque + sources).
;
;      powershell -ExecutionPolicy Bypass -File installer\build-installer.ps1
;
;  Layout installe (impose par le code client, qui resout ses chemins avec
;  Path(__file__).parent et cherche site-packages dans runtime\) :
;
;      <InstallDir>\app\circusvoip_client.py     <- sources + config runtime
;      <InstallDir>\app\sounds\*.wav
;      <InstallDir>\runtime\python.exe           <- CPython embarque (PBS)
;      <InstallDir>\runtime\Lib\site-packages\   <- dependances pip
;
;  L'installation se fait par defaut dans {localappdata} et non dans
;  Program Files : le client ecrit sa configuration, ses conversations
;  CircusPhone et ses mises a jour auto-appliquees DANS app\, ce qui
;  exigerait des droits admin (et se ferait rediriger par l'UAC
;  virtualisation) sous Program Files.
; ======================================================================

#ifndef PayloadDir
  #error PayloadDir non defini : lancer installer\build-installer.ps1
#endif
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef VersionQuad
  #define VersionQuad "0.0.0.0"
#endif
#ifndef VersionChannel
  #define VersionChannel "alpha"
#endif
#ifndef VersionBuild
  #define VersionBuild "0"
#endif
#ifndef DepsTier
  #define DepsTier "bundled"
#endif
#ifndef OcrBackend
  #define OcrBackend "cpu"
#endif

; Index PyTorch. Sous Windows, PyPI ne publie que des wheels torch CPU
; (~116 Mo) : les builds CUDA (~1,8 Go) sont uniquement sur
; download.pytorch.org. Le choix se materialise dans runtime\pip.ini, que pip
; lit comme configuration "site" du prefixe -- donc y compris quand c'est le
; bootstrap du client qui lance pip au premier lancement.
#define TorchCpuIndex  "https://download.pytorch.org/whl/cpu"
#define TorchCudaIndex "https://download.pytorch.org/whl/cu130"

; OcrBundled est defini par build-installer.ps1 quand -Deps full a embarque le
; moteur : dans ce cas il n'y a rien a proposer ni a telecharger.
#ifdef OcrBundled
  #define OcrIsBundled "True"
#else
  #define OcrIsBundled "False"
#endif
#ifndef OutDir
  #define OutDir "out"
#endif
#ifndef OutName
  #define OutName "CircusVOIP_Client_Setup"
#endif

#define AppName        "CircusVOIP"
#define AppPublisher   "Kainan"
#define AppUrl         "https://github.com/kainann/CircusVOIP"
#define ClientScript   "circusvoip_client.py"
#define IconRelative   "app\StarCircus.ico"
#define HasIcon        FileExists(AddBackslash(PayloadDir) + IconRelative)

; Icone des raccourcis : StarCircus.ico si le payload en contient une, sinon on
; retombe sur celle du runtime Python (le client, lui, ignore silencieusement
; une icone absente).
#if HasIcon
  #define ShortcutIcon "{app}\" + IconRelative
#else
  #define ShortcutIcon "{app}\runtime\python.exe"
#endif

[Setup]
; AppId fixe : c'est lui qui permet a l'installeur de detecter une version
; precedente et de mettre a jour en place. Ne JAMAIS le changer entre deux
; releases, sinon les utilisateurs se retrouvent avec deux entrees
; "Ajout/Suppression de programmes" et deux dossiers.
AppId={{B6C1D7E4-3A52-4F18-9C6D-1E7A5B0F2C93}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
VersionInfoVersion={#VersionQuad}
VersionInfoProductVersion={#VersionQuad}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} Client Setup
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases

DefaultDirName={localappdata}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
AllowNoIcons=yes
; Installation par utilisateur : aucun prompt UAC, et le dossier reste
; inscriptible (indispensable pour la mise a jour auto du client).
PrivilegesRequired=lowest

; Windows 10 minimum (cf. README : client Windows 10/11 uniquement).
MinVersion=10.0
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

OutputDir={#OutDir}
OutputBaseFilename={#OutName}
Compression=lzma2/max
SolidCompression=yes
LZMANumBlockThreads=4
WizardStyle=modern
ShowLanguageDialog=no

; Le client tourne comme runtime\python.exe : Inno doit pouvoir demander la
; fermeture de l'instance en cours avant d'ecraser les .py et les DLL Qt.
CloseApplications=yes
CloseApplicationsFilter=*.py,*.dll,*.pyd,*.exe
RestartApplications=no

#if HasIcon
SetupIconFile={#PayloadDir}\{#IconRelative}
UninstallDisplayIcon={app}\{#IconRelative}
#endif

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "consoleicon"; Description: "Ajouter un raccourci de diagnostic (console visible)"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Sources + assets. 'ignoreversion' : ce sont des .py/.wav, pas de version de
; fichier a comparer. La config utilisateur (circusvoip_client_config.json,
; circusphone_*.json, photos de profil, bips ptt_*.wav) n'est PAS dans le
; payload : elle survit donc telle quelle a une mise a jour.
Source: "{#PayloadDir}\app\*"; DestDir: "{app}\app"; Flags: recursesubdirs createallsubdirs ignoreversion

; Runtime Python embarque.
Source: "{#PayloadDir}\runtime\*"; DestDir: "{app}\runtime"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
; Raccourci principal : pythonw.exe = pas de fenetre console.
Name: "{group}\{#AppName}"; Filename: "{app}\runtime\pythonw.exe"; Parameters: """{app}\app\{#ClientScript}"""; WorkingDir: "{app}\app"; IconFilename: "{#ShortcutIcon}"; Comment: "{#AppName} {#AppVersion}"

Name: "{autodesktop}\{#AppName}"; Filename: "{app}\runtime\pythonw.exe"; Parameters: """{app}\app\{#ClientScript}"""; WorkingDir: "{app}\app"; IconFilename: "{#ShortcutIcon}"; Tasks: desktopicon

; Variante console : affiche les logs [BOOT]/[OCR]/[UPDATE] et la progression
; du bootstrap pip. Indispensable pour diagnostiquer un demarrage qui echoue.
Name: "{group}\{#AppName} (console de diagnostic)"; Filename: "{app}\runtime\python.exe"; Parameters: """{app}\app\{#ClientScript}"""; WorkingDir: "{app}\app"; IconFilename: "{#ShortcutIcon}"; Tasks: consoleicon

Name: "{group}\Dossier d'installation"; Filename: "{app}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"

[INI]
; Fixe la variante de torch AVANT que le moindre pip ne tourne (les entrees
; [INI] sont traitees pendant l'installation, les [Run] apres). Vaut aussi pour
; le bootstrap du client au premier lancement si l'utilisateur ne telecharge
; pas le moteur maintenant.
; Pas de flag createkeyifdoesntexist ici : le payload embarque deja un pip.ini
; (ecrit au build avec la variante par defaut), et c'est justement cette cle
; qu'il faut ecraser avec le choix de l'utilisateur.
Filename: "{app}\runtime\pip.ini"; Section: "global"; Key: "extra-index-url"; String: "{#TorchCpuIndex}"; Check: OcrWantsCpu
Filename: "{app}\runtime\pip.ini"; Section: "global"; Key: "extra-index-url"; String: "{#TorchCudaIndex}"; Check: OcrWantsCuda

[Run]
; Le moteur OCR (easyocr + torch) n'est pas embarque : sans ca, le client le
; telecharge tout seul au premier lancement via son bootstrap pip. Le proposer
; ici permet de le faire tout de suite, dans une console visible, plutot que de
; laisser l'utilisateur devant une fenetre qui semble figee plusieurs minutes.
; Les deux entrees lancent la meme commande : c'est pip.ini, ecrit juste avant,
; qui decide de la variante telechargee.
Filename: "{app}\runtime\python.exe"; \
    Parameters: "-m pip install --upgrade easyocr"; \
    WorkingDir: "{app}\app"; \
    Description: "Telecharger le moteur OCR maintenant (variante CPU, 243 Mo)"; \
    Flags: postinstall skipifsilent; Check: InstallOcrCpuNow

Filename: "{app}\runtime\python.exe"; \
    Parameters: "-m pip install --upgrade easyocr"; \
    WorkingDir: "{app}\app"; \
    Description: "Telecharger le moteur OCR maintenant (variante NVIDIA CUDA, ~2 Go)"; \
    Flags: postinstall skipifsilent; Check: InstallOcrCudaNow

; Lancement final : pythonw.exe, donc sans fenetre de console. Le client
; n'ecrit rien d'indispensable sur stdout (print() est un no-op quand
; sys.stdout est None, et le journal de session part dans un fichier).
;
; Exception : si l'utilisateur a refuse le telechargement du moteur OCR, le
; bootstrap pip du client va tourner plusieurs minutes avant que la fenetre
; n'apparaisse. Sans console il n'aurait aucun retour visuel et croirait a un
; plantage : on lance alors python.exe pour qu'il voie la progression.
Filename: "{app}\runtime\pythonw.exe"; \
    Parameters: """{app}\app\{#ClientScript}"""; \
    WorkingDir: "{app}\app"; \
    Description: "Lancer {#AppName} maintenant"; \
    Flags: postinstall skipifsilent nowait; Check: LaunchWithoutConsole

Filename: "{app}\runtime\python.exe"; \
    Parameters: """{app}\app\{#ClientScript}"""; \
    WorkingDir: "{app}\app"; \
    Description: "Lancer {#AppName} maintenant (le moteur OCR sera telecharge, suivez la console)"; \
    Flags: postinstall skipifsilent nowait; Check: LaunchWithConsole

[UninstallDelete]
; Le runtime est supprime en entier : il ne contient rien qui appartienne a
; l'utilisateur, et il accumule des fichiers qu'Inno ne connait pas et ne
; supprimerait donc pas -- les paquets installes apres-coup par le bootstrap
; pip du client (easyocr, torch : plusieurs Go) et les caches .pyc generes a
; chaque execution.
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\app\__pycache__"
Type: filesandordirs; Name: "{app}\app\circusvoip_debug"
Type: filesandordirs; Name: "{app}\app\circusvoip_profile_photo_cache"
; La configuration et l'historique CircusPhone sont volontairement conserves
; (une reinstallation retrouve les reglages du joueur).

[Messages]
french.WelcomeLabel2=Ceci va installer [name/ver] sur votre ordinateur.%n%nL'installeur embarque son propre Python : rien d'autre n'est requis.

[Code]

{ ------------------------------------------------------------------
  Choix du moteur OCR
  ------------------------------------------------------------------
  CircusVOIP lit la position du joueur par OCR (EasyOCR, qui tourne sur
  PyTorch). Le moteur ne peut pas etre embarque par defaut : il pese 243 Mo
  en CPU et pres de 2 Go en CUDA.

  Contrairement a ce qu'on pourrait croire, la variante CPU n'est pas un
  repli au rabais pour cartes AMD : sous Windows, PyPI ne publie QUE des
  wheels torch CPU, donc c'est deja ce que tout le monde recoit aujourd'hui.
  La variante CUDA doit etre demandee explicitement (index PyTorch dedie) et
  n'a de sens qu'avec une carte NVIDIA.

  Installation silencieuse : /OCR=cpu | cuda | skip. }

const
  OCR_CPU  = 0;
  OCR_CUDA = 1;
  OCR_SKIP = 2;

var
  OcrPage: TInputOptionWizardPage;

function OcrEngineBundled: Boolean;
begin
  Result := {#OcrIsBundled};
end;

{ nvcuda.dll dans System32 : pose par le pilote NVIDIA. Simple presomption
  pour pre-selectionner le bon choix, l'utilisateur reste libre. }
function HasNvidiaDriver: Boolean;
begin
  Result := FileExists(ExpandConstant('{sys}\nvcuda.dll'));
end;

procedure InitializeWizard;
var
  Param: String;
  Default: Integer;
begin
  if OcrEngineBundled then
    Exit;

  OcrPage := CreateInputOptionPage(wpSelectTasks,
    'Moteur de reconnaissance de texte',
    'Quelle variante installer ?',
    'CircusVOIP lit votre position dans Star Citizen par OCR. Le moteur ' +
    '(EasyOCR + PyTorch) n''est pas inclus dans l''installeur : il se ' +
    'telecharge une seule fois.',
    True, False);
  OcrPage.Add('Processeur (CPU) - 243 Mo.' + #13#10 +
              'Fonctionne avec toutes les cartes graphiques : AMD, Intel, NVIDIA.');
  OcrPage.Add('NVIDIA CUDA - environ 2 Go.' + #13#10 +
              'OCR nettement plus rapide, mais carte NVIDIA obligatoire.');
  OcrPage.Add('Ne rien telecharger maintenant.' + #13#10 +
              'Le client s''en chargera au premier lancement (variante choisie ci-dessus).');

  if HasNvidiaDriver then
    Default := OCR_CUDA
  else
    Default := OCR_CPU;

  Param := Lowercase(Trim(ExpandConstant('{param:OCR|}')));
  if Param = 'cpu' then
    Default := OCR_CPU
  else if Param = 'cuda' then
    Default := OCR_CUDA
  else if (Param = 'skip') or (Param = 'none') then
    Default := OCR_SKIP;

  OcrPage.SelectedValueIndex := Default;
end;

function OcrSelection: Integer;
begin
  if OcrEngineBundled then
  begin
    { Rien a choisir : on reflete la variante deja embarquee pour que pip.ini
      reste coherent avec le contenu du runtime. }
    if '{#OcrBackend}' = 'cuda' then
      Result := OCR_CUDA
    else
      Result := OCR_CPU;
  end
  else if OcrPage = nil then
    Result := OCR_CPU
  else
    Result := OcrPage.SelectedValueIndex;
end;

function OcrWantsCuda: Boolean;
begin
  Result := OcrSelection = OCR_CUDA;
end;

{ CPU pour le choix explicite ET pour "plus tard" : dans les deux cas la
  variante a resoudre plus tard est la CPU. }
function OcrWantsCpu: Boolean;
begin
  Result := not OcrWantsCuda;
end;

function InstallOcrCpuNow: Boolean;
begin
  Result := (not OcrEngineBundled) and (OcrSelection = OCR_CPU);
end;

function InstallOcrCudaNow: Boolean;
begin
  Result := (not OcrEngineBundled) and (OcrSelection = OCR_CUDA);
end;

{ Le premier lancement n'a besoin d'une console que s'il reste un moteur OCR a
  telecharger, c'est-a-dire quand l'utilisateur a choisi "ne rien telecharger
  maintenant". }
function LaunchWithConsole: Boolean;
begin
  Result := (not OcrEngineBundled) and (OcrSelection = OCR_SKIP);
end;

function LaunchWithoutConsole: Boolean;
begin
  Result := not LaunchWithConsole;
end;


{ ------------------------------------------------------------------
  Emplacement d'installation
  ------------------------------------------------------------------
  Le client ecrit sa configuration, ses messages CircusPhone et ses mises a
  jour auto dans son propre dossier app\. Sous Program Files, ces ecritures
  echouent (ou sont redirigees par l'UAC) : on previent l'utilisateur s'il
  choisit un emplacement non inscriptible. }
function IsUnderProgramFiles(Path: string): Boolean;
var
  Pf, Pf32: string;
begin
  Pf   := ExpandConstant('{commonpf}');
  Pf32 := ExpandConstant('{commonpf32}');
  Path := Lowercase(Path);
  Result := (Pos(Lowercase(Pf), Path) = 1) or (Pos(Lowercase(Pf32), Path) = 1);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    if IsUnderProgramFiles(WizardDirValue) then
    begin
      Result := MsgBox(
        'Emplacement deconseille.' + #13#10 + #13#10 +
        'CircusVOIP enregistre sa configuration, ses conversations et ses ' +
        'mises a jour automatiques dans son dossier d''installation. Sous ' +
        '"Program Files", ces ecritures necessitent des droits ' +
        'administrateur et la mise a jour automatique echouera.' + #13#10 + #13#10 +
        'Emplacement recommande : ' + ExpandConstant('{localappdata}\{#AppName}') + #13#10 + #13#10 +
        'Continuer quand meme ?',
        mbConfirmation, MB_YESNO) = IDYES;
    end;
  end;
end;
