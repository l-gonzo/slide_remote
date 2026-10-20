; Instalador de Windows para la app de escritorio de Zlide (Inno Setup 6).
; Lo usa tool\package_windows.ps1; a mano:
;   iscc /DAppVersion=2.1.0 /DSourceDir=..\..\build\windows\x64\runner\Release tool\windows\slide_remote.iss

#ifndef AppVersion
  #define AppVersion "2.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6C0E2B1A-4E5B-4C1F-9C3A-5D7E21A0B5A1}
AppName=Zlide
AppVersion={#AppVersion}
AppPublisher=Luis Gonzalo Méndez
AppPublisherURL=https://github.com/l-gonzo/slide_remote
DefaultDirName={autopf}\Zlide
DefaultGroupName=Zlide
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=Zlide-Setup-{#AppVersion}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\slide_remote.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
WizardStyle=modern

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Zlide"; Filename: "{app}\slide_remote.exe"
Name: "{autodesktop}\Zlide"; Filename: "{app}\slide_remote.exe"; Tasks: desktopicon

[Run]
; Regla de versiones anteriores (cuando la app se llamaba "Slide Remote")
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Slide Remote"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Slidy"""; Flags: runhidden
; Permitir en el firewall los puertos que usa el teléfono (UDP 50505: comandos; TCP 50506: notas)
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Zlide"" dir=in action=allow program=""{app}\slide_remote.exe"" enable=yes profile=private,domain"; Flags: runhidden
Filename: "{app}\slide_remote.exe"; Description: "Abrir Zlide"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Zlide"""; Flags: runhidden; RunOnceId: "fw"
