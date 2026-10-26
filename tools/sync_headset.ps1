# Copies the PC app's scripts (src/*.gd) into headset/shared/ for the headset
# app (slice o5): the world runs there from the same code. Leaves out what only
# the PC runs; the headset has stand-ins for those classes in headset/src/pc/.
# headset/shared/ is generated (not in git): run this before every headset build.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Join-Path $root "src"
$target = Join-Path $root "headset\shared"
$pcOnly = @("link_server.gd", "display_topology.gd", "vdd_control.gd", "input_worker.gd")
New-Item -ItemType Directory -Force $target | Out-Null
# Scripts gone from src/ must go from shared/ too (their .uid files with them).
Get-ChildItem $target -Filter *.gd | Where-Object {
    -not (Test-Path (Join-Path $source $_.Name)) -or $pcOnly -contains $_.Name
} | ForEach-Object {
    Remove-Item $_.FullName
    $uid = $_.FullName + ".uid"
    if (Test-Path $uid) { Remove-Item $uid }
}
$copied = 0
Get-ChildItem $source -Filter *.gd | Where-Object { $pcOnly -notcontains $_.Name } | ForEach-Object {
    $destination = Join-Path $target $_.Name
    if (-not (Test-Path $destination) -or (Get-FileHash $_.FullName).Hash -ne (Get-FileHash $destination).Hash) {
        Copy-Item $_.FullName $destination
        $copied++
    }
}
Write-Output "headset/shared: $copied changed, $((Get-ChildItem $target -Filter *.gd).Count) scripts"
