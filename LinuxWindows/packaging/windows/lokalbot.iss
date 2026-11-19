; Per-user (or enterprise /ALLUSERS) installer for LokalBot on Windows (Inno Setup 6).
; scripts/package-windows-installer.ps1 compiles it from the folder that
; scripts/package.sh staged in dist/:
;   ISCC /DAppVersion=0.13.2 /DSourceDir=<staged folder> /DOutputDir=<dist> /DIconFile=<.ico> lokalbot.iss
;
; By default it installs for the current user without administrator rights, into
; %LOCALAPPDATA%\Programs\LokalBot, so LokalBot can still replace its own
; files when an update is installed. Passing /ALLUSERS installs machine-wide into
; %ProgramFiles%\LokalBot for IT / Intune / GPO deployments. It adds a Start menu
; shortcut carrying the app id Windows notifications use (com.lokalbot.LokalBot),
; an Installed apps entry, and (optionally, on by default) puts {app}\bin on PATH
; so lokalbot-cli works immediately in terminals and coding agents. Uninstalling
; keeps the library in %LOCALAPPDATA%\LokalBot.

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
DefaultDirName={autopf}\LokalBot
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
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
ChangesEnvironment=yes

[Tasks]
Name: "addtopath"; Description: "Add lokalbot-cli to PATH (for terminal, Claude Code, and Codex)"; GroupDescription: "Command-line & AI agents:"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\lokalbot.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\lokalbot-cli.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\lokalbot-cli.exe"; DestDir: "{app}\bin"; Flags: ignoreversion; Tasks: addtopath
Source: "{#SourceDir}\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSES\*"; DestDir: "{app}\LICENSES"; Flags: ignoreversion recursesubdirs
; The Visual C++ runtime LokalBot copies beside llama-server.exe, which needs it.
Source: "{#SourceDir}\vc-runtime\*"; DestDir: "{app}\vc-runtime"; Flags: ignoreversion

[Icons]
; LokalBot looks for this exact shortcut to show notifications under its own name.
Name: "{autoprograms}\LokalBot"; Filename: "{app}\lokalbot.exe"; AppUserModelID: "{#AppId}"
Name: "{autodesktop}\LokalBot"; Filename: "{app}\lokalbot.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\lokalbot.exe"; Description: "{cm:LaunchProgram,LokalBot}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Removes the coding-agent skill and the CLI copy that Settings -> AI agents ->
; Agent CLI installed, and nothing else.
Filename: "{app}\lokalbot-cli.exe"; Parameters: "install-skill --uninstall"; Flags: runhidden; RunOnceId: "RemoveAgentSkill"

[Registry]
; Values LokalBot writes itself (Launch at login, its notification app id) go with it.
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "LokalBot"; Flags: dontcreatekey uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\AppUserModelId\{#AppId}"; Flags: dontcreatekey uninsdeletekey

[UninstallDelete]
; Old executables an in-place update renamed aside.
Type: files; Name: "{app}\*.old"
Type: files; Name: "{app}\bin\*.old"
Type: dirifempty; Name: "{app}\bin"
; License texts and the Visual C++ runtime an in-place update added.
Type: filesandordirs; Name: "{app}\LICENSES"
Type: filesandordirs; Name: "{app}\vc-runtime"

[Code]
function GetEnvRootKey: Integer;
begin
  if IsAdminInstallMode then
    Result := HKEY_LOCAL_MACHINE
  else
    Result := HKEY_CURRENT_USER;
end;

function GetEnvSubKey: string;
begin
  if IsAdminInstallMode then
    Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  else
    Result := 'Environment';
end;

function NormalizePathEntry(const S: string): string;
begin
  Result := Lowercase(RemoveBackslashUnlessRoot(Trim(S)));
end;

function PathContainsEntry(const Paths, Target: string): Boolean;
var
  Remaining, Entry, NormalizedTarget: string;
  SepPos: Integer;
begin
  Result := False;
  NormalizedTarget := NormalizePathEntry(Target);
  Remaining := Paths;
  while Remaining <> '' do
  begin
    SepPos := Pos(';', Remaining);
    if SepPos > 0 then
    begin
      Entry := Copy(Remaining, 1, SepPos - 1);
      Remaining := Copy(Remaining, SepPos + 1, Length(Remaining) - SepPos);
    end
    else
    begin
      Entry := Remaining;
      Remaining := '';
    end;
    if (Entry <> '') and (NormalizePathEntry(Entry) = NormalizedTarget) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure AddDirToPath(const Dir: string);
var
  Paths, NewPaths: string;
  RootKey: Integer;
  SubKey: string;
begin
  RootKey := GetEnvRootKey;
  SubKey := GetEnvSubKey;
  Paths := '';
  RegQueryStringValue(RootKey, SubKey, 'Path', Paths);
  if PathContainsEntry(Paths, Dir) then
    Exit;
  if Paths = '' then
    NewPaths := Dir
  else if Paths[Length(Paths)] = ';' then
    NewPaths := Paths + Dir
  else
    NewPaths := Paths + ';' + Dir;
  RegWriteExpandStringValue(RootKey, SubKey, 'Path', NewPaths);
end;

procedure RemoveDirFromPath(const Dir: string);
var
  Paths, Remaining, Entry, NewPaths, NormalizedTarget: string;
  RootKey, SepPos: Integer;
  SubKey: string;
  Removed: Boolean;
begin
  RootKey := GetEnvRootKey;
  SubKey := GetEnvSubKey;
  if not RegQueryStringValue(RootKey, SubKey, 'Path', Paths) then
    Exit;
  NormalizedTarget := NormalizePathEntry(Dir);
  Remaining := Paths;
  NewPaths := '';
  Removed := False;
  while Remaining <> '' do
  begin
    SepPos := Pos(';', Remaining);
    if SepPos > 0 then
    begin
      Entry := Copy(Remaining, 1, SepPos - 1);
      Remaining := Copy(Remaining, SepPos + 1, Length(Remaining) - SepPos);
    end
    else
    begin
      Entry := Remaining;
      Remaining := '';
    end;
    if (Entry <> '') and (NormalizePathEntry(Entry) = NormalizedTarget) then
    begin
      Removed := True;
    end
    else if Entry <> '' then
    begin
      if NewPaths = '' then
        NewPaths := Entry
      else
        NewPaths := NewPaths + ';' + Entry;
    end;
  end;
  if Removed then
    RegWriteExpandStringValue(RootKey, SubKey, 'Path', NewPaths);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('addtopath') then
    AddDirToPath(ExpandConstant('{app}\bin'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemoveDirFromPath(ExpandConstant('{app}\bin'));
end;
