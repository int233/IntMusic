#define MyAppName "IntMusic"
#define MyAppPublisher "IntMusic"
#define MyAppVersion "1.0.0"
#define MyAppExeName "IntMusic.exe"

[Setup]
AppId={{1B1BDE61-8265-4DA3-91A4-4B8C3F96A4C1}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\IntMusic
DefaultGroupName=IntMusic
DisableProgramGroupPage=yes
OutputDir=..\dist\installer
OutputBaseFilename=IntMusic-Windows-Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\..\apps\client-flutter\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\client\{#MyAppExeName}
ChangesEnvironment=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Types]
Name: "full"; Description: "Core + Client"
Name: "clientonly"; Description: "Client only"
Name: "coreonly"; Description: "Core only"
Name: "custom"; Description: "Custom"; Flags: iscustom

[Components]
Name: "client"; Description: "IntMusic desktop client"; Types: full clientonly custom
Name: "core"; Description: "IntMusic headless Core server"; Types: full coreonly custom

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Components: client
Name: "addcoretopath"; Description: "Add IntMusic Core to the current user's PATH"; GroupDescription: "Core environment:"; Components: core

[Files]
Source: "..\dist\windows\client\*"; DestDir: "{app}\client"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: client
Source: "..\dist\windows\core\local-music-core.exe"; DestDir: "{app}\core"; Flags: ignoreversion; Components: core
Source: "..\dist\windows\core\local-music-core-daemon.exe"; DestDir: "{app}\core"; Flags: ignoreversion; Components: core
Source: "Start-IntMusic.cmd"; DestDir: "{app}"; Flags: ignoreversion; Components: client and core
Source: "Start-IntMusic.ps1"; DestDir: "{app}"; Flags: ignoreversion; Components: client and core
Source: "Install-IntMusicCoreService.ps1"; DestDir: "{app}"; Flags: ignoreversion; Components: core
Source: "Uninstall-IntMusicCoreService.ps1"; DestDir: "{app}"; Flags: ignoreversion; Components: core

[Icons]
Name: "{group}\IntMusic"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\Start-IntMusic.ps1"" -InstallDir ""{app}"""; WorkingDir: "{app}"; IconFilename: "{app}\client\{#MyAppExeName}"; Components: client and core
Name: "{group}\IntMusic"; Filename: "{app}\client\{#MyAppExeName}"; Components: client; Check: IsClientOnlyInstall
Name: "{group}\IntMusic Core CLI"; Filename: "{app}\core\local-music-core.exe"; WorkingDir: "{app}\core"; Components: core
Name: "{commondesktop}\IntMusic"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\Start-IntMusic.ps1"" -InstallDir ""{app}"""; WorkingDir: "{app}"; IconFilename: "{app}\client\{#MyAppExeName}"; Tasks: desktopicon; Components: client and core
Name: "{commondesktop}\IntMusic"; Filename: "{app}\client\{#MyAppExeName}"; Tasks: desktopicon; Components: client; Check: IsClientOnlyInstall

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Install-IntMusicCoreService.ps1"" -InstallDir ""{app}"""; Flags: runhidden waituntilterminated; Components: core
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\Start-IntMusic.ps1"" -InstallDir ""{app}"""; Description: "Launch IntMusic Core + Client"; Flags: nowait postinstall skipifsilent runhidden; Components: client and core
Filename: "{app}\client\{#MyAppExeName}"; Description: "Launch IntMusic"; Flags: nowait postinstall skipifsilent; Components: client; Check: IsClientOnlyInstall

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-IntMusicCoreService.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveIntMusicCoreService"

[Registry]
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "INTMUSIC_HOME"; ValueData: "{app}"; Flags: uninsdeletevalue; Components: core
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "INTMUSIC_CORE_EXE"; ValueData: "{app}\core\local-music-core.exe"; Flags: uninsdeletevalue; Components: core
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "INTMUSIC_CORE_SERVICE_EXE"; ValueData: "{app}\core\local-music-core-daemon.exe"; Flags: uninsdeletevalue; Components: core

[Code]
const
  IntMusicHwndBroadcast = $FFFF;
  IntMusicSettingChangeMessage = $001A;
  IntMusicAbortIfHung = $0002;

function SendMessageTimeout(hWnd: Integer; Msg: Integer; wParam: Integer;
  lParam: String; fuFlags: Integer; uTimeout: Integer;
  var lpdwResult: Integer): Integer;
  external 'SendMessageTimeoutW@user32.dll stdcall';

function NormalizedPathItem(Value: String): String;
begin
  Result := ';' + Uppercase(Trim(Value)) + ';';
end;

function UserPathContains(PathValue: String; Item: String): Boolean;
begin
  Result := Pos(NormalizedPathItem(Item), NormalizedPathItem(PathValue)) > 0;
end;

function IsClientOnlyInstall: Boolean;
begin
  Result := WizardIsComponentSelected('client') and not WizardIsComponentSelected('core');
end;

procedure BroadcastEnvironmentChanged;
var
  ResultCode: Integer;
begin
  SendMessageTimeout(IntMusicHwndBroadcast, IntMusicSettingChangeMessage, 0, 'Environment',
    IntMusicAbortIfHung, 5000, ResultCode);
end;

procedure AddToUserPath(Item: String);
var
  OldPath: String;
  NewPath: String;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', OldPath) then
    OldPath := '';

  if UserPathContains(OldPath, Item) then
    exit;

  if Trim(OldPath) = '' then
    NewPath := Item
  else
    NewPath := OldPath + ';' + Item;

  RegWriteExpandStringValue(HKCU, 'Environment', 'Path', NewPath);
end;

procedure RemoveFromUserPath(Item: String);
var
  OldPath: String;
  NewPath: String;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', OldPath) then
    exit;

  NewPath := OldPath;
  StringChangeEx(NewPath, ';' + Item, '', True);
  StringChangeEx(NewPath, Item + ';', '', True);
  if CompareText(Trim(NewPath), Item) = 0 then
    NewPath := '';

  if NewPath <> OldPath then
    RegWriteExpandStringValue(HKCU, 'Environment', 'Path', NewPath);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if (CurStep = ssInstall) and WizardIsComponentSelected('core') then
  begin
    Exec(ExpandConstant('{sys}\sc.exe'), 'stop IntMusicCore', '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
    Sleep(1500);
  end;

  if (CurStep = ssPostInstall) and WizardIsComponentSelected('core') and
     WizardIsTaskSelected('addcoretopath') then
  begin
    AddToUserPath(ExpandConstant('{app}\core'));
    BroadcastEnvironmentChanged;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RemoveFromUserPath(ExpandConstant('{app}\core'));
    BroadcastEnvironmentChanged;
  end;
end;
