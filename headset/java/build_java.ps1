# Builds headset/java into headset/addons/workplace_video/bin/workplace_video.jar
# (slice o3). Needs JAVA_HOME (JDK 17) and ANDROID_HOME (platform android-35).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$android = Join-Path $env:ANDROID_HOME "platforms\android-35\android.jar"
$classes = Join-Path $env:TEMP "workplace_video_classes"
$out = Join-Path $root "..\addons\workplace_video\bin"
if (Test-Path $classes) { Remove-Item -Recurse -Force $classes }
New-Item -ItemType Directory -Force $classes, $out | Out-Null
$sources = Get-ChildItem -Recurse -Filter *.java $root | ForEach-Object { $_.FullName }
& (Join-Path $env:JAVA_HOME "bin\javac.exe") --release 11 -encoding UTF-8 -classpath $android -d $classes $sources
if ($LASTEXITCODE -ne 0) { throw "javac failed" }
& (Join-Path $env:JAVA_HOME "bin\jar.exe") cf (Join-Path $out "workplace_video.jar") -C $classes .
if ($LASTEXITCODE -ne 0) { throw "jar failed" }
Write-Output "built $(Join-Path $out 'workplace_video.jar')"
