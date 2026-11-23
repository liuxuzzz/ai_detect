; Flutter's full Release directory is required, not only the executable.
[Setup]
AppId={{0A72DCB8-9E01-4871-9262-DDE79A12E340}
AppName=AI质量检测
AppVersion={#AppVersion}
AppPublisher=ai_detect contributors
AppPublisherURL=https://github.com/liuxuzzz/ai_detect
DefaultDirName={autopf}\AI质量检测
DefaultGroupName=AI质量检测
OutputDir={#OutputDir}
OutputBaseFilename=ai-detect-{#AppVersion}-windows-x64-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\aijiance.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
WizardStyle=modern

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\AI质量检测"; Filename: "{app}\aijiance.exe"
Name: "{autodesktop}\AI质量检测"; Filename: "{app}\aijiance.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; Flags: unchecked

[Run]
Filename: "{app}\aijiance.exe"; Description: "启动 AI质量检测"; Flags: nowait postinstall skipifsilent
