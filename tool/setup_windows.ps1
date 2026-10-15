# Prepara una PC con Windows 10/11 desde cero para compilar Slide Remote
# (app de Windows y, opcional, Android). Usa winget.
#
#   powershell -ExecutionPolicy Bypass -File tool\setup_windows.ps1
#   powershell -ExecutionPolicy Bypass -File tool\setup_windows.ps1 -Android
#
# Ejecútalo en una PowerShell normal; pedirá permiso de administrador cuando haga falta.
# Se puede volver a correr: salta lo que ya está instalado.
param([switch]$Android, [string]$FlutterDir = 'C:\src\flutter')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Log($m) { Write-Host "`n==> $m" -ForegroundColor Green }
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Add-UserPath($dir) {
  $p = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $p) { $p = '' }
  if (($p -split ';') -notcontains $dir) {
    [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(';') + ';' + $dir).TrimStart(';'), 'User')
  }
  Refresh-Path
}
function WinGet($id, $extra = @()) {
  $installed = winget list --id $id -e --accept-source-agreements 2>$null | Select-String $id
  if ($installed) { Write-Host "   $id ya está instalado"; return }
  winget install -e --id $id --accept-package-agreements --accept-source-agreements @extra
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw 'Falta winget. Instala "Instalador de aplicación" desde Microsoft Store y vuelve a intentar.'
}

Log 'Git, Python e Inno Setup'
WinGet 'Git.Git'
WinGet 'Python.Python.3.12'
WinGet 'JRSoftware.InnoSetup'

Log 'Visual Studio 2022 con "Desarrollo para el escritorio con C++" (tarda; descarga varios GB)'
WinGet 'Microsoft.VisualStudio.2022.Community' @('--override', '--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --passive --wait')
Refresh-Path

Log "Flutter (stable) en $FlutterDir"
if (Get-Command flutter -ErrorAction SilentlyContinue) {
  Write-Host "   Flutter ya está instalado: $((Get-Command flutter).Source)"
} elseif (Test-Path "$FlutterDir\bin\flutter.bat") {
  Write-Host '   Ya existe'
} else {
  New-Item -ItemType Directory -Force (Split-Path $FlutterDir) | Out-Null
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git $FlutterDir
}
Add-UserPath "$FlutterDir\bin"
flutter config --no-analytics | Out-Null
flutter --version

Log 'Modo de desarrollador (Flutter lo necesita para los plugins)'
$key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$dev = (Get-ItemProperty -Path $key -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
if ($dev -ne 1) {
  try {
    Start-Process reg -Verb RunAs -Wait -ArgumentList 'add', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock', '/t', 'REG_DWORD', '/f', '/v', 'AllowDevelopmentWithoutDevLicense', '/d', '1'
  } catch {
    Write-Warning 'No se pudo activar solo. Actívalo a mano en la ventana que se abre.'
    Start-Process 'ms-settings:developers'
  }
} else { Write-Host '   Ya está activado' }

if ($Android) {
  Log 'Java 17 y SDK de Android'
  WinGet 'EclipseAdoptium.Temurin.17.JDK'
  Refresh-Path
  $sdk = "$env:LOCALAPPDATA\Android\Sdk"
  $sdkmanager = "$sdk\cmdline-tools\latest\bin\sdkmanager.bat"
  if (-not (Test-Path $sdkmanager)) {
    $ver = '13114758'
    try {
      $xml = (Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/android/repository/repository2-3.xml').Content
      $found = [regex]::Matches($xml, 'commandlinetools-win-(\d+)_latest\.zip') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object | Select-Object -Last 1
      if ($found) { $ver = "$found" }
    } catch { }
    $tmp = Join-Path $env:TEMP 'sr-cmdline'
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $tmp | Out-Null
    Invoke-WebRequest -UseBasicParsing "https://dl.google.com/android/repository/commandlinetools-win-${ver}_latest.zip" -OutFile "$tmp\tools.zip"
    Expand-Archive "$tmp\tools.zip" -DestinationPath $tmp
    New-Item -ItemType Directory -Force "$sdk\cmdline-tools" | Out-Null
    Remove-Item -Recurse -Force "$sdk\cmdline-tools\latest" -ErrorAction SilentlyContinue
    Move-Item "$tmp\cmdline-tools" "$sdk\cmdline-tools\latest"
  }
  [Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdk, 'User')
  $env:ANDROID_HOME = $sdk
  Add-UserPath "$sdk\platform-tools"
  Add-UserPath "$sdk\cmdline-tools\latest\bin"
  $yes = ('y' + [Environment]::NewLine) * 30
  $yes | & $sdkmanager --licenses | Out-Null
  & $sdkmanager 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0'
  flutter config --android-sdk $sdk
  $yes | flutter doctor --android-licenses | Out-Null
}

Log 'Preparando el proyecto'
Set-Location $root
py tool\configure.py

Log 'Revisión'
py tool\build.py doctor

Write-Host ''
Write-Host 'Listo. Abre una PowerShell nueva y compila con:'
Write-Host '    py tool\build.py windows    # dist\SlideRemote-Setup-<versión>.exe y .zip'
if ($Android) { Write-Host '    py tool\build.py android    # APK' }
