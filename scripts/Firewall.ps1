$ErrorActionPreference = 'Stop'
$installDir = $PSScriptRoot
$exe = Join-Path $installDir 'pc-control.exe'
$statusPath = Join-Path $installDir 'firewall-status.json'
try {
    $config = Get-Content -LiteralPath (Join-Path $installDir 'config.json') -Raw | ConvertFrom-Json
    $rules = @(
        @{ Name = 'PCControl-API'; DisplayName = 'PC Control - encrypted local API'; Protocol = 'TCP'; Port = $config.port },
        @{ Name = 'PCControl-Discovery'; DisplayName = 'PC Control - local Bonjour discovery'; Protocol = 'UDP'; Port = 5353 }
    )
    foreach ($rule in $rules) {
        Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -Name $rule.Name -DisplayName $rule.DisplayName -Direction Inbound -Action Allow -Program $exe -Protocol $rule.Protocol -LocalPort $rule.Port -RemoteAddress LocalSubnet -Profile Any -EdgeTraversalPolicy Block | Out-Null
    }
    @{ ok = $true; updatedAt = (Get-Date).ToUniversalTime().ToString('o'); scope = 'LocalSubnet only'; port = $config.port } | ConvertTo-Json | Set-Content -LiteralPath $statusPath
} catch {
    @{ ok = $false; message = $_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath $statusPath
    exit 1
}
