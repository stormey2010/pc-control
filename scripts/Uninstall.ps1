param([switch]$RemovePairing)
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'PCControl'
$exe = Join-Path $installDir 'pc-control.exe'
Stop-ScheduledTask -TaskName 'PC Control' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'PC Control' -Confirm:$false -ErrorAction SilentlyContinue
$processes = @(Get-CimInstance Win32_Process -Filter "Name='pc-control.exe'" | Where-Object { $_.ExecutablePath -eq $exe })
$processes | Where-Object { $_.CommandLine -like '*--supervise*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$processes | Where-Object { $_.CommandLine -notlike '*--supervise*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# Firewall removal requires an elevated terminal. Retained rules are tied to this exact executable path.
if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Get-NetFirewallRule -Name 'PCControl-API','PCControl-Discovery' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}
if (Test-Path -LiteralPath $exe) {
    for ($attempt = 0; $attempt -lt 25; $attempt++) {
        try { Remove-Item -LiteralPath $exe -Force; break }
        catch { if ($attempt -eq 24) { throw }; Start-Sleep -Milliseconds 200 }
    }
}
if ($RemovePairing) {
    foreach ($name in @('config.json','connection.json','server.key','server.pem')) { Remove-Item -LiteralPath (Join-Path $installDir $name) -Force -ErrorAction SilentlyContinue }
}
Write-Output 'PC Control stopped and startup removed. Pairing is preserved unless -RemovePairing was specified.'
