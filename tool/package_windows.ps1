# Crea los instaladores de la app de escritorio para Windows:
#   dist\Zlide-Setup-<versión>.exe   (instalador; necesita Inno Setup 6)
#   dist\Zlide-<versión>-windows-x64.zip (portátil)
#
#   powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1
#   powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1 -NoBuild
param([switch]$NoBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
$release = Join-Path $root 'build\windows\x64\runner\Release'
$dist = Join-Path $root 'dist'

if (-not $NoBuild) {
  Write-Host '==> Compilando (flutter build windows --release)'
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw 'La compilación falló' }
}
if (-not (Test-Path "$release\slide_remote.exe")) { throw "No existe $release\slide_remote.exe" }

# Bibliotecas de Visual C++: se copian junto al .exe para que funcione en PCs sin el
# "Visual C++ Redistributable" instalado.
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  $src = Join-Path $env:WINDIR "System32\$dll"
  if (Test-Path $src) { Copy-Item $src $release -Force }
  else { Write-Warning "No encontré $dll; instala el Visual C++ Redistributable x64." }
}

New-Item -ItemType Directory -Force $dist | Out-Null

Write-Host '==> .zip portátil'
$zip = Join-Path $dist "Zlide-$version-windows-x64.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$release\*" -DestinationPath $zip

Write-Host '==> Instalador (Inno Setup)'
$iscc = @(
  (Get-Command iscc -ErrorAction SilentlyContinue).Source,
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($iscc) {
  & $iscc "/DAppVersion=$version" "/DSourceDir=$release" 'tool\windows\slide_remote.iss'
  if ($LASTEXITCODE -ne 0) { throw 'Inno Setup falló' }
} else {
  Write-Warning 'No encontré Inno Setup (winget install JRSoftware.InnoSetup). Solo se creó el .zip.'
}

Write-Host ''
Write-Host 'Listo:'
Get-ChildItem $dist | Where-Object { $_.Name -like "Zlide*$version*" } | ForEach-Object { "  {0:N1} MB  {1}" -f ($_.Length / 1MB), $_.FullName }
