$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "dev-shell.ps1")

cargo run -p core-cli -- serve
