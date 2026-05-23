$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "dev-shell.ps1")

cargo --version
rustc --version
flutter doctor -v
