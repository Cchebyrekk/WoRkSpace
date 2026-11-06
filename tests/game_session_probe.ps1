# Pure regression: execute only Reverse-Usb with a mocked adb, not the session.
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$scriptPath=Join-Path $PSScriptRoot '..\tools\game_session.ps1'
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Session helper does not parse' }
$function=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Reverse-Usb'},$true) | Select-Object -First 1
if (!$function) { throw 'Reverse-Usb not found' }
Invoke-Expression $function.Extent.Text
$Adb=Join-Path $PSHOME 'powershell.exe'
$script:Calls=New-Object 'System.Collections.Generic.List[string]'
$script:GameActive=$true
function In-Games { return $script:GameActive }
function Adb-Call([string]$arguments) {
    if ($arguments -eq 'devices') {
        return "List of devices attached`r`n3487C10H3W02M1`tdevice`r`n192.168.1.71:5555`tdevice`r`nbad`tunauthorized`r`n"
    }
    $script:Calls.Add($arguments)
    return ''
}
Reverse-Usb
if ($script:Calls.Count -ne 3) { throw ('Expected 3 reverse calls, got '+$script:Calls.Count) }
foreach ($port in @(47902,47903,47920)) {
    if (!$script:Calls.Contains("-s 3487C10H3W02M1 reverse tcp:$port tcp:$port")) { throw ('Missing port '+$port) }
}
$script:GameActive=$false
$script:Calls.Clear()
Reverse-Usb
if ($script:Calls.Count -ne 0) { throw 'Leaving game mode must not run more adb commands' }
Write-Output 'GameSession: 5 checks passed (CRLF USB, all game ports, Wi-Fi/unauthorized excluded, exit cancels USB scan)'
