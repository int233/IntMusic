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
Write-Host "Flutter:" (flutter --version | Select-Object -First 1)
if (Test-Path (Join-Path $DevEcoBin "devecostudio64.exe")) {
  Write-Host "DevEco Studio:" (Join-Path $DevEcoBin "devecostudio64.exe")
}
