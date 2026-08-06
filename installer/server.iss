; ======================================================================
;  CircusVOIP - installeur serveur (Inno Setup 6)
; ======================================================================
;  Compile par installer\build-installer.ps1 -Component server (ou both).
;
;  Meme principe que le client : runtime Python embarque dans runtime\,
;  sources dans app\. Le serveur genere au premier lancement, A COTE de ses
;  sources : circusvoip_server_config.json (mot de passe), cert.pem/key.pem
;  (TLS auto-signe), circusvoip_channels.json, circusvoip_profiles.json,
;  circusvoip_admin_token.json. D'ou l'installation dans {localappdata}.
;
;  Ports a ouvrir dans le pare-feu : 8888 (positions), 8889 (audio) et
;  eventuellement 8080 (serveur de mise a jour).
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
#ifndef OutDir
  #define OutDir "out"
#endif
#ifndef OutName
  #define OutName "CircusVOIP_Server_Setup"
#endif

#define AppName      "CircusVOIP Server"
#define AppPublisher "Kainan"
#define AppUrl       "https://github.com/kainann/CircusVOIP"
#define IconRelative "app\StarCircus.ico"
#define HasIcon      FileExists(AddBackslash(PayloadDir) + IconRelative)

#if HasIcon
  #define ShortcutIcon "{app}\" + IconRelative
#else
  #define ShortcutIcon "{app}\runtime\python.exe"
#endif

[Setup]
; Ne jamais changer cet AppId : il porte la detection de mise a jour.
AppId={{4D9E62B1-8C74-4A3E-B5F0-27C6D1A9E834}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
VersionInfoVersion={#VersionQuad}
VersionInfoProductVersion={#VersionQuad}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} Setup
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases

DefaultDirName={localappdata}\CircusVOIP-Server
DefaultGroupName=CircusVOIP Server
DisableProgramGroupPage=yes
AllowNoIcons=yes
PrivilegesRequired=lowest

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

[Files]
Source: "{#PayloadDir}\app\*"; DestDir: "{app}\app"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#PayloadDir}\runtime\*"; DestDir: "{app}\runtime"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
; Les deux services tournent dans deux process distincts : un raccourci chacun.
Name: "{group}\Serveur positions (8888)"; Filename: "{app}\runtime\python.exe"; Parameters: """{app}\app\circusvoip_server.py"""; WorkingDir: "{app}\app"; IconFilename: "{#ShortcutIcon}"
Name: "{group}\Serveur audio (8889)"; Filename: "{app}\runtime\python.exe"; Parameters: """{app}\app\circusvoip_audio_server.py"""; WorkingDir: "{app}\app"; IconFilename: "{#ShortcutIcon}"
Name: "{group}\Console admin"; Filename: "{app}\runtime\python.exe"; Parameters: """{app}\app\circusvoip_admin.py"""; WorkingDir: "{app}\app"; IconFilename: "{#ShortcutIcon}"
Name: "{group}\Serveur de mise a jour (8080)"; Filename: "{app}\runtime\python.exe"; Parameters: """{app}\app\circusvoip_update_server.py"""; WorkingDir: "{app}\app"; IconFilename: "{#ShortcutIcon}"
Name: "{group}\Dossier d'installation"; Filename: "{app}\app"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\CircusVOIP Serveur"; Filename: "{app}\runtime\python.exe"; Parameters: """{app}\app\circusvoip_server.py"""; WorkingDir: "{app}\app"; IconFilename: "{#ShortcutIcon}"; Tasks: desktopicon

[Run]
; Pas de regle pare-feu posee ici : l'installeur tourne sans elevation
; (PrivilegesRequired=lowest) et netsh advfirewall exige des droits admin.
; Au premier demarrage, Windows affiche lui-meme sa demande d'autorisation
; pour python.exe ; sinon voir installer\README.md pour les commandes netsh.
Filename: "{app}\runtime\python.exe"; Parameters: """{app}\app\circusvoip_server.py"""; WorkingDir: "{app}\app"; Description: "Demarrer le serveur de positions (genere le mot de passe)"; Flags: postinstall skipifsilent nowait
Filename: "{app}\runtime\python.exe"; Parameters: """{app}\app\circusvoip_audio_server.py"""; WorkingDir: "{app}\app"; Description: "Demarrer le serveur audio"; Flags: postinstall skipifsilent nowait unchecked

[UninstallDelete]
; Runtime supprime en entier (rien d'utilisateur dedans, et il accumule des
; caches .pyc qu'Inno ne connait pas).
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\app\__pycache__"
; Secrets et etat conserves volontairement (mot de passe, token admin, cert
; TLS, canaux, profils) : une reinstallation ne casse pas les clients deja
; configures. A supprimer a la main pour repartir de zero.

[Messages]
french.WelcomeLabel2=Ceci va installer [name/ver] sur votre ordinateur.%n%nL'installeur embarque son propre Python : rien d'autre n'est requis.%n%nLe mot de passe d'acces est genere au premier demarrage dans circusvoip_server_config.json.
