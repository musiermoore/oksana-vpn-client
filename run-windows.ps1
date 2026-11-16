$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repositoryRoot

$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
$flutterExecutable = if ($flutterCommand) { $flutterCommand.Source } else { $null }

if (-not $flutterExecutable) {
    $flutterCandidates = @()

    if ($env:FLUTTER_ROOT) {
        $flutterCandidates += Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'
    }

    $flutterCandidates += @(
        (Join-Path $repositoryRoot '..\flutter\bin\flutter.bat'),
        (Join-Path $repositoryRoot '..\flutter\flutter\bin\flutter.bat')
    )

    foreach ($candidate in $flutterCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            $flutterExecutable = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    }
}

if (-not $flutterExecutable) {
    throw 'Flutter was not found on PATH or in ../flutter. Add the Flutter SDK bin folder to PATH or set FLUTTER_ROOT.'
}

& (Join-Path $repositoryRoot 'scripts\prepare-windows-runtime.ps1')

& $flutterExecutable pub get
if ($LASTEXITCODE -ne 0) {
    throw 'flutter pub get failed.'
}

& $flutterExecutable run -d windows
if ($LASTEXITCODE -ne 0) {
    throw 'Flutter Windows debug run failed.'
}
