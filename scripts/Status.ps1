$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'PCControl'
Get-ScheduledTask -TaskName 'PC Control' | Format-List TaskName,State
Get-ScheduledTaskInfo -TaskName 'PC Control' | Format-List LastRunTime,NextRunTime,LastTaskResult,NumberOfMissedRuns
Get-CimInstance Win32_Process -Filter "Name='pc-control.exe'" | Where-Object { $_.ExecutablePath -eq (Join-Path $installDir 'pc-control.exe') } | Format-List ProcessId,ParentProcessId,CommandLine
Get-Content -LiteralPath (Join-Path $installDir 'firewall-status.json')
# Deliberately omit the bearer token from normal status output.
$connection = Get-Content -LiteralPath (Join-Path $installDir 'connection.json') -Raw | ConvertFrom-Json
$connection | Format-List name,urls,certificateSha256,discovery
