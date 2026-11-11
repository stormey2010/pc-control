param([switch]$SkipBuild, [switch]$SkipFirewall)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$installDir = Join-Path $env:LOCALAPPDATA 'PCControl'
$exe = Join-Path $installDir 'pc-control.exe'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$sid = $identity.User.Value
if (-not $SkipBuild) {
    Push-Location $root
    try {
        & go build -trimpath -ldflags '-H=windowsgui -s -w' -o (Join-Path $root 'dist\pc-control.exe') .
        if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
    } finally { Pop-Location }
}
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
# Pairing credentials and the TLS key are accessible only to this user and administrators.
& icacls.exe $installDir /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict installation permissions' }
$existingTask = Get-ScheduledTask -TaskName 'PC Control' -ErrorAction SilentlyContinue
if ($existingTask) { Stop-ScheduledTask -TaskName 'PC Control' }
$processes = @(Get-CimInstance Win32_Process -Filter "Name='pc-control.exe'" | Where-Object { $_.ExecutablePath -eq $exe })
# Stop supervisor first to avoid a race with its automatic worker restart.
$processes | Where-Object { $_.CommandLine -like '*--supervise*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$processes | Where-Object { $_.CommandLine -notlike '*--supervise*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
for ($attempt = 0; $attempt -lt 25; $attempt++) {
    try { Copy-Item -LiteralPath (Join-Path $root 'dist\pc-control.exe') -Destination $exe -Force; break }
    catch { if ($attempt -eq 24) { throw }; Start-Sleep -Milliseconds 200 }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Firewall.ps1') -Destination (Join-Path $installDir 'Firewall.ps1') -Force
$setup = Start-Process -FilePath $exe -ArgumentList @('--setup','--data-dir',('"' + $installDir + '"')) -WindowStyle Hidden -PassThru -Wait
if ($setup.ExitCode -ne 0) { throw 'Credential/certificate setup failed; check agent.log' }
$action = New-ScheduledTaskAction -Execute $exe -Argument ('--supervise --data-dir "' + $installDir + '"') -WorkingDirectory $installDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'PC Control' -Description 'Invisible local PC controls. Worker restarts automatically; runs in the signed-in desktop session. A one-minute watchdog recovers the supervisor.' -Action $action -Trigger @($trigger,$watchdog) -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'PC Control'
if (-not $SkipFirewall) {
    $admin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $firewallScript = Join-Path $installDir 'Firewall.ps1'
    if ($admin) { & $firewallScript } else {
        $fw = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $firewallScript + '"')) -WindowStyle Hidden -PassThru -Wait
        if ($fw.ExitCode -ne 0) { throw 'Firewall setup failed; check firewall-status.json' }
    }
}
Write-Output "Installed and started: $exe"
Write-Output 'Startup: PC Control scheduled task (at sign-in), with automatic crash recovery.'
Write-Output "Private pairing details: $(Join-Path $installDir 'connection.json')"
