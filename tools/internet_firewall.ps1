# One TLS entry point; never expose the unauthenticated LAN services.
# ASCII-only for Windows PowerShell 5.1.
param([switch]$Remove, [switch]$LocalOnly)
$ErrorActionPreference = 'Stop'
$name = 'WoRkPlaceInternetGateway'
if ($LocalOnly) { $name += 'Lan' }
if ($Remove) {
    Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Output 'InternetFirewallRuleRemoved=True'
    exit
}
$python = (& py -3.12 -c 'import sys; print(sys.executable)').Trim()
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $python)) { throw 'Python312Required' }
$existing = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
if ($existing) { throw 'InternetFirewallRuleAlreadyExists' }
$scope = 'Any'
if ($LocalOnly) { $scope = 'LocalSubnet' }
New-NetFirewallRule -Name $name -DisplayName 'WoRkPlace Internet Gateway TLS' `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 47930 `
    -Program $python -Profile Private,Public -RemoteAddress $scope | Out-Null
Write-Output 'InternetFirewallRuleInstalled=True'
