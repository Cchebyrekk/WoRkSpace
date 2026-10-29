# Builds the headset's video receiver (headset/java) into
# headset/addons/workplace_video/bin/workplace_video.aar: the Java classes
# (javac against android.jar) and, since slice o5d, a small native library
# (jni/, NDK clang) for convex screens. Needs JAVA_HOME (JDK 17) and ANDROID_HOME
# (platform android-35, NDK 28.1.13356709).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$android = Join-Path $env:ANDROID_HOME "platforms\android-35\android.jar"
$clang = Join-Path $env:ANDROID_HOME "ndk\28.1.13356709\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android29-clang.cmd"
$work = Join-Path $env:TEMP "workplace_video_build"
$out = Join-Path $root "..\addons\workplace_video\bin"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
$classes = Join-Path $work "classes"
$aar = Join-Path $work "aar"
$jni = Join-Path $aar "jni\arm64-v8a"
New-Item -ItemType Directory -Force $classes, $jni, $out | Out-Null

$sources = Get-ChildItem -Recurse -Filter *.java $root | ForEach-Object { $_.FullName }
& (Join-Path $env:JAVA_HOME "bin\javac.exe") --release 11 -encoding UTF-8 -classpath $android -d $classes $sources
if ($LASTEXITCODE -ne 0) { throw "javac failed" }
& (Join-Path $env:JAVA_HOME "bin\jar.exe") cf (Join-Path $aar "classes.jar") -C $classes .
if ($LASTEXITCODE -ne 0) { throw "jar failed" }

& $clang -shared -fPIC -O2 -Wall -o (Join-Path $jni "libworkplace_hwb.so") (Join-Path $root "jni\hardware_buffers.c") -landroid -lEGL
if ($LASTEXITCODE -ne 0) { throw "clang failed" }

$manifest = '<?xml version="1.0" encoding="utf-8"?>' + "`n" +
    '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.workplace.headset.video">' + "`n" +
    '    <uses-sdk android:minSdkVersion="29" />' + "`n" + '</manifest>' + "`n"
Set-Content -Path (Join-Path $aar "AndroidManifest.xml") -Value $manifest -Encoding Ascii -NoNewline
Set-Content -Path (Join-Path $aar "R.txt") -Value "" -Encoding Ascii -NoNewline

$target = Join-Path $out "workplace_video.aar"
if (Test-Path $target) { Remove-Item $target }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($aar, $target)
$old = Join-Path $out "workplace_video.jar"
if (Test-Path $old) { Remove-Item $old }
Write-Output "built $target"
