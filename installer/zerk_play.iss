#define AppName "Zerk Play"
; The CI overrides this with /DAppVersion=<version from pubspec>; the literal
; below is only the fallback for a local build.
#ifndef AppVersion
  #define AppVersion "2.10.14"
#endif
#define AppExe "zerk_play.exe"
#ifndef BuildDir
  #define BuildDir "..\build\windows\x64\runner\Release"
#endif
#if DirExists(GetEnv("SystemRoot") + "\Sysnative")
  #define VcRuntimeDir GetEnv("SystemRoot") + "\Sysnative"
#else
  #define VcRuntimeDir GetEnv("SystemRoot") + "\System32"
#endif

[Setup]
AppId={{0A38532D-CE9A-41F1-A775-57961FAB535B}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=cloud.zerk
AppPublisherURL=https://github.com/florinp93/Zerk-Play-2.0
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
OutputDir=..\build\installer
OutputBaseFilename=ZerkPlay-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
; The Simplified Chinese translation ships with the Inno Setup sources, not
; with the compiler, so the CI drops a copy next to this script. The guard
; keeps a local build (and a failed download) working.
#if FileExists(AddBackslash(SourcePath) + "ChineseSimplified.isl")
Name: "chinese"; MessagesFile: "ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#VcRuntimeDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRuntimeDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRuntimeDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
Type: filesandordirs; Name: "{app}\data"

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: WizardSilent
