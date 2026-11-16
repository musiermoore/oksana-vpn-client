param(
    [ValidateSet('x64')]
    [string] $Architecture = 'x64'
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Windows releases must be built on Windows with the Visual C++ toolchain.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repositoryRoot

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    if ($env:FLUTTER_ROOT -and (Test-Path (Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'))) {
        $env:PATH = "$(Join-Path $env:FLUTTER_ROOT 'bin');$env:PATH"
    } else {
        throw 'Flutter is not on PATH. Install Flutter and restart PowerShell.'
    }
}

& (Join-Path $repositoryRoot 'scripts\prepare-windows-runtime.ps1')

$bundleDirectory = Join-Path $repositoryRoot "build\windows\$Architecture\runner\Release"
$executablePath = Join-Path $bundleDirectory 'oksana_vpn_desktop.exe'
$releaseDirectory = Join-Path $repositoryRoot 'build\release'
$archivePath = Join-Path $releaseDirectory "oksana-vpn-windows-$Architecture.zip"

flutter pub get
if ($LASTEXITCODE -ne 0) {
    throw 'flutter pub get failed.'
}

flutter build windows --release
if ($LASTEXITCODE -ne 0) {
    throw 'Flutter Windows release build failed.'
}

if (-not (Test-Path $executablePath)) {
    throw "Build succeeded but the expected executable was not found: $executablePath"
}

New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
if (Test-Path $archivePath) {
    Remove-Item $archivePath -Force
}
Compress-Archive -Path (Join-Path $bundleDirectory '*') -DestinationPath $archivePath

Write-Host "Windows release bundle created: $archivePath"
