param([switch]$TestSupervisorRecovery)
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'PCControl'
$exe = Join-Path $installDir 'pc-control.exe'
$config = Get-Content (Join-Path $installDir 'config.json') -Raw | ConvertFrom-Json
function Get-AgentProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='pc-control.exe'" | Where-Object { $_.ExecutablePath -eq $exe })
}
function Wait-Healthy([int]$OldWorker, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $worker = Get-AgentProcesses | Where-Object { $_.CommandLine -notlike '*--supervise*' -and $_.ProcessId -ne $OldWorker } | Select-Object -First 1
        if ($worker) {
            try {
                $health = Invoke-RestMethod -Uri "https://127.0.0.1:$($config.port)/health" -SkipCertificateCheck -TimeoutSec 2
                if ($health.ok) { return $worker }
            } catch {}
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Agent did not recover within $Seconds seconds"
}
$processes = Get-AgentProcesses
$worker = $processes | Where-Object { $_.CommandLine -notlike '*--supervise*' } | Select-Object -First 1
if (-not $worker) { throw 'Agent is not running' }
$timer = [Diagnostics.Stopwatch]::StartNew()
Stop-Process -Id $worker.ProcessId -Force
$newWorker = Wait-Healthy $worker.ProcessId 15
Write-Output "PASS worker crash recovery: $([math]::Round($timer.Elapsed.TotalSeconds,2)) seconds; new PID $($newWorker.ProcessId)"
if ($TestSupervisorRecovery) {
    $supervisor = Get-AgentProcesses | Where-Object { $_.CommandLine -like '*--supervise*' } | Select-Object -First 1
    $timer.Restart()
    Stop-Process -Id $supervisor.ProcessId -Force
    $newWorker = Wait-Healthy $newWorker.ProcessId 85
    Write-Output "PASS supervisor crash recovery through Task Scheduler: $([math]::Round($timer.Elapsed.TotalSeconds,2)) seconds; new PID $($newWorker.ProcessId)"
}
$task = Get-ScheduledTask -TaskName 'PC Control'
if ($task.State -ne 'Running') { throw "Unexpected task state: $($task.State)" }
if ($task.Settings.ExecutionTimeLimit -ne 'PT0S') { throw 'Task has an execution time limit' }
$before = @{}
Get-AgentProcesses | ForEach-Object { $proc = Get-Process -Id $_.ProcessId; $before[$proc.Id] = $proc.TotalProcessorTime.TotalMilliseconds }
$idleTimer = [Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds 15
$cpuMs = 0.0
$workingSet = 0
foreach ($proc in @(Get-AgentProcesses | ForEach-Object { Get-Process -Id $_.ProcessId })) {
    if ($before.ContainsKey($proc.Id)) { $cpuMs += $proc.TotalProcessorTime.TotalMilliseconds - $before[$proc.Id] }
    $workingSet += $proc.WorkingSet64
}
Write-Output "Idle sample: $([math]::Round($cpuMs,2)) CPU milliseconds over $([math]::Round($idleTimer.Elapsed.TotalSeconds,1)) seconds; $([math]::Round($workingSet / 1MB,1)) MiB combined working set (worker + supervisor)."
Write-Output 'PASS scheduled task is running with no execution time limit.'
