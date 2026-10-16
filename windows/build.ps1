# Builds DropHop for Windows into .\dist\DropHop.exe (one self-contained file — no .NET needed on the target PC).
# Needs the .NET 8 SDK:  winget install Microsoft.DotNet.SDK.8
param([string]$Arch = "win-x64")      # or win-arm64

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

dotnet publish .\DropHop\DropHop.csproj -c Release -r $Arch --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -o .\dist

Write-Host "`nBuilt .\dist\DropHop.exe"

# Optional installer (the Windows equivalent of make-dmg.sh): needs Inno Setup 6  (winget install JRSoftware.InnoSetup)
$iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
if (Test-Path $iscc) { & $iscc .\installer.iss; Write-Host "Built .\dist\DropHop-Setup.exe" }
