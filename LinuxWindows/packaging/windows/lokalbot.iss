; Per-user installer for LokalBot on Windows (Inno Setup 6).
; scripts/package-windows-installer.ps1 compiles it from the folder that
; scripts/package.sh staged in dist/:
;   ISCC /DAppVersion=0.11.0 /DSourceDir=<staged folder> /DOutputDir=<dist> /DIconFile=<.ico> lokalbot.iss
;
; It installs for the current user without administrator rights, into
; %LOCALAPPDATA%\Programs\LokalBot, so LokalBot can still replace its own
; files when an update is installed. It adds a Start menu shortcut carrying
; the app id Windows notifications use (com.lokalbot.LokalBot) and an entry
; in Installed apps. Uninstalling keeps the library in %LOCALAPPDATA%\LokalBot.

#ifndef AppVersion
  #error Pass /DAppVersion=<version>
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<staged LokalBot-<version>-windows-x86_64 folder>
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef IconFile
  #error Pass /DIconFile=<path to lokalbot.ico>
#endif

#define AppId "com.lokalbot.LokalBot"

[Setup]
AppId={{CFF062EB-30DC-4ED9-8586-AB0B54B52A85}
AppName=LokalBot
AppVersion={#AppVersion}
AppVerName=LokalBot {#AppVersion}
AppPublisher=LokalBot project
AppPublisherURL=https://www.lokalbot.com
AppSupportURL=https://www.lokalbot.com/support
AppUpdatesURL=https://github.com/stevyhacker/lokalbot/releases
DefaultDirName={localappdata}\Programs\LokalBot
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=LokalBot-{#AppVersion}-windows-x86_64-setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\lokalbot.exe
UninstallDisplayName=LokalBot
VersionInfoVersion={#AppVersion}
VersionInfoProductName=LokalBot
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\lokalbot.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\lokalbot-cli.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSES\*"; DestDir: "{app}\LICENSES"; Flags: ignoreversion recursesubdirs
; The Visual C++ runtime LokalBot copies beside llama-server.exe, which needs it.
Source: "{#SourceDir}\vc-runtime\*"; DestDir: "{app}\vc-runtime"; Flags: ignoreversion

[Icons]
; LokalBot looks for this exact shortcut to show notifications under its own name.
Name: "{userprograms}\LokalBot"; Filename: "{app}\lokalbot.exe"; AppUserModelID: "{#AppId}"
Name: "{userdesktop}\LokalBot"; Filename: "{app}\lokalbot.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\lokalbot.exe"; Description: "{cm:LaunchProgram,LokalBot}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Removes the coding-agent skill and the CLI copy that Settings → Advanced →
; Agent CLI installed, and nothing else.
Filename: "{app}\lokalbot-cli.exe"; Parameters: "install-skill --uninstall"; Flags: runhidden; RunOnceId: "RemoveAgentSkill"

[Registry]
; Values LokalBot writes itself (Launch at login, its notification app id) go with it.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "LokalBot"; Flags: dontcreatekey uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\{#AppId}"; Flags: dontcreatekey uninsdeletekey

[UninstallDelete]
; Old executables an in-place update renamed aside.
Type: files; Name: "{app}\*.old"
; License texts and the Visual C++ runtime an in-place update added.
Type: filesandordirs; Name: "{app}\LICENSES"
Type: filesandordirs; Name: "{app}\vc-runtime"
