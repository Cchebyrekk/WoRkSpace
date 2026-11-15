# q4: collect a bounded live measurement; does not launch or stop applications.
param([ValidateRange(10,300)][int]$Seconds=60, [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Label='baseline')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$dir=Join-Path $env:LOCALAPPDATA 'WoRkPlace'
$out=Join-Path $root ('build\q4\'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+$Label)
New-Item -ItemType Directory -Force $out | Out-Null
$hostLog=Join-Path $dir 'game_host.log'
$driverLog=Join-Path $dir 'steamvr_driver.log'
function Read-Lines([string]$path) {
    if (Test-Path -LiteralPath $path) { return @(Get-Content -LiteralPath $path -Encoding UTF8) }
    return @()
}
$hostSnapshot=@(Read-Lines $hostLog)
$hostBefore=$hostSnapshot.Count
$endpoint=''
foreach ($line in $hostSnapshot) {
    if ($line -match '^\[games\].* ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$') { $endpoint=$Matches[1] }
}
$transport='unknown'
if ($endpoint -eq '127.0.0.1') { $transport='usb' } elseif ($endpoint) { $transport='wifi' }
$driverBefore=@(Read-Lines $driverLog).Count
$started=Get-Date
Write-Output ('Measuring '+$Seconds+' seconds; move your head and controllers in the running VR application.')
$deadline=$started.AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
$hostLines=@(Read-Lines $hostLog)
$driverLines=@(Read-Lines $driverLog)
# A session restart replaces game_host.log. Preserve the new log in that case.
if ($hostLines.Count -lt $hostBefore) { $hostBefore=0 }
if ($driverLines.Count -lt $driverBefore) { $driverBefore=0 }
$hostDelta=@($hostLines | Select-Object -Skip $hostBefore)
$driverDelta=@($driverLines | Select-Object -Skip $driverBefore)
$hostDelta | Set-Content (Join-Path $out 'headset_and_host.log') -Encoding UTF8
$driverDelta | Set-Content (Join-Path $out 'driver.log') -Encoding UTF8
$metrics=@()
foreach ($line in $hostDelta) {
    if ($line -notmatch '^\[q4-') { continue }
    foreach ($match in [regex]::Matches($line,'([a-z_]+) n=(\d+) ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)')) {
        $metrics += @{ stage=$match.Groups[1].Value; samples=[int]$match.Groups[2].Value;
            p50=[double]::Parse($match.Groups[3].Value,[Globalization.CultureInfo]::InvariantCulture);
            p95=[double]::Parse($match.Groups[4].Value,[Globalization.CultureInfo]::InvariantCulture);
            p99=[double]::Parse($match.Groups[5].Value,[Globalization.CultureInfo]::InvariantCulture);
            max=[double]::Parse($match.Groups[6].Value,[Globalization.CultureInfo]::InvariantCulture) }
    }
}
@{label=$Label; transport=$transport; endpoint=$endpoint; started=$started.ToString('o'); ended=(Get-Date).ToString('o'); intervals=$metrics;
    note='Each interval has its own percentiles. Do not average percentiles or call layer submission physical display latency.'} |
    ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'summary.json') -Encoding UTF8
if (!$metrics.Count) { Write-Warning 'No q4 telemetry received. This is not a successful headset latency measurement.' }
if (($Label -like '*wifi*' -and $transport -ne 'wifi') -or ($Label -like '*cable*' -and $transport -ne 'usb')) { Write-Warning ('Label/transport mismatch: actual '+$transport+' '+$endpoint) }
$hostDelta | Where-Object { $_ -match '^\[q4-' } | Select-Object -Last 6
Write-Output ('Saved '+$out)
