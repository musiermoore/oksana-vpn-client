$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runtimeDirectory = Join-Path $repositoryRoot 'build\windows-runtime'
$downloadDirectory = Join-Path $repositoryRoot 'build\windows-runtime-download'
$version = '26.10.31'
$archiveName = 'Xray-windows-64.zip'
$baseUrl = "https://github.com/XTLS/Xray-core/releases/download/v$version"
$archivePath = Join-Path $downloadDirectory $archiveName
$digestPath = "$archivePath.dgst"

New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null

if (-not (Test-Path -LiteralPath $archivePath)) {
    Invoke-WebRequest -Uri "$baseUrl/$archiveName" -OutFile $archivePath
}
if (-not (Test-Path -LiteralPath $digestPath)) {
    Invoke-WebRequest -Uri "$baseUrl/$archiveName.dgst" -OutFile $digestPath
}

$digestText = Get-Content -LiteralPath $digestPath -Raw
$expectedHash = [regex]::Match($digestText, '(?i)sha256\s*[:=]\s*([0-9a-f]{64})').Groups[1].Value
if (-not $expectedHash) {
    $expectedHash = [regex]::Match($digestText, '(?i)\b([0-9a-f]{64})\b').Groups[1].Value
}
if (-not $expectedHash) {
    throw 'The official Xray release checksum file has an unknown format.'
}
$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
if ($actualHash -ne $expectedHash) {
    Remove-Item -LiteralPath $archivePath -Force
    throw 'Xray release archive checksum verification failed.'
}

$extractDirectory = Join-Path $downloadDirectory "extract-$version"
if (Test-Path -LiteralPath $extractDirectory) {
    Remove-Item -LiteralPath $extractDirectory -Recurse -Force
}
Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDirectory -Force

foreach ($fileName in @('xray.exe', 'wintun.dll', 'geoip.dat', 'geosite.dat')) {
    $source = Get-ChildItem -LiteralPath $extractDirectory -Filter $fileName -File -Recurse |
        Select-Object -First 1
    if (-not $source) {
        throw "Official Xray package is missing required file: $fileName"
    }
    Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $runtimeDirectory $fileName) -Force
}

Write-Host "Verified Xray $version Windows x64 runtime prepared in $runtimeDirectory"
