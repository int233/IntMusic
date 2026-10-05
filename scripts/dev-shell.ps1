$ErrorActionPreference = "Stop"

$CargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
$FlutterBin = Join-Path $env:USERPROFILE "development\flutter\bin"
$AndroidSdk = Join-Path $env:LOCALAPPDATA "Android\Sdk"
$AndroidTools = Join-Path $AndroidSdk "cmdline-tools\latest\bin"
$AndroidPlatformTools = Join-Path $AndroidSdk "platform-tools"
$DevEcoBin = Join-Path $env:LOCALAPPDATA "Huawei\DevEco Studio\bin"
$Jdk = Get-ChildItem -Directory "C:\Program Files\Microsoft" -Filter "jdk-17*" -ErrorAction SilentlyContinue |
  Sort-Object Name -Descending |
  Select-Object -First 1

if ($Jdk) {
  $env:JAVA_HOME = $Jdk.FullName
}

$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk
$env:Path = @(
  $CargoBin,
  $FlutterBin,
  $AndroidTools,
  $AndroidPlatformTools,
  $DevEcoBin,
  $(if ($Jdk) { Join-Path $Jdk.FullName "bin" }),
  $env:Path
) -join ";"

Write-Host "Rust:" (rustc --version)
Write-Host "Cargo:" (cargo --version)
# Drain the native command before selecting a line. Closing its stdout early
# interrupts Flutter's first-run bootstrap on a clean Windows runner.
$flutterVersion = @(flutter --version)
if ($LASTEXITCODE -ne 0) {
  throw "Flutter initialization failed with exit code $LASTEXITCODE."
}
Write-Host "Flutter:" $flutterVersion[0]
if (Test-Path (Join-Path $DevEcoBin "devecostudio64.exe")) {
  Write-Host "DevEco Studio:" (Join-Path $DevEcoBin "devecostudio64.exe")
}
