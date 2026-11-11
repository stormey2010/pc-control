param([switch]$NoOpen)
$ErrorActionPreference = 'Stop'
$qrDeps = Join-Path $env:LOCALAPPDATA 'PCControlRelease\python'
$qrModule = Join-Path $qrDeps 'qrcode\__init__.py'
if (-not (Test-Path -LiteralPath $qrModule)) {
    & python -m pip install --disable-pip-version-check --no-input --target $qrDeps qrcode==8.2
    if ($LASTEXITCODE -ne 0) { throw 'Could not install QR code support' }
}
& python (Join-Path $PSScriptRoot 'pairing_code.py')
if ($LASTEXITCODE -ne 0) { throw 'Could not create the pairing code' }
if (-not $NoOpen) { Start-Process (Join-Path $env:LOCALAPPDATA 'PCControl\pairing.html') }
