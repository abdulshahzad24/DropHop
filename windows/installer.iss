; Inno Setup script — builds dist\DropHop-Setup.exe (per-user install, no admin rights needed)
[Setup]
AppName=DropHop
AppVersion=1.0.0
AppPublisher=DropHop
DefaultDirName={autopf}\DropHop
DefaultGroupName=DropHop
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=DropHop-Setup
SetupIconFile=DropHop\Assets\AppIcon.ico
UninstallDisplayIcon={app}\DropHop.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
Source: "dist\DropHop.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\DropHop"; Filename: "{app}\DropHop.exe"
Name: "{userstartup}\DropHop"; Filename: "{app}\DropHop.exe"; Tasks: autostart

[Tasks]
Name: "autostart"; Description: "Start DropHop when I sign in"; Flags: checkedonce

[Run]
Filename: "{app}\DropHop.exe"; Description: "Launch DropHop"; Flags: nowait postinstall skipifsilent
