param(
    [string]$InstallDir = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

$serviceName = "IntMusicCore"
$displayName = "IntMusic Core"
$description = "IntMusic headless music library and playback core"
$daemonExe = Join-Path $InstallDir "core\local-music-core-daemon.exe"
$dataRoot = Join-Path $env:ProgramData "IntMusic\Core"
$configFile = Join-Path $dataRoot "config.toml"
$dataDir = Join-Path $dataRoot "data"
$httpRuleName = "IntMusic Core HTTP"
$discoveryRuleName = "IntMusic Core Discovery"

function Set-IntMusicFirewallRule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $true)]
        [string]$Protocol,
        [Parameter(Mandatory = $true)]
        [string]$LocalPort
    )

    Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    New-NetFirewallRule `
        -DisplayName $DisplayName `
        -Direction Inbound `
        -Action Allow `
        -Program $daemonExe `
        -Protocol $Protocol `
        -LocalPort $LocalPort `
        -Profile Private,Domain | Out-Null
}

New-Item -ItemType Directory -Force -Path $dataRoot, $dataDir | Out-Null

if (-not (Test-Path -LiteralPath $daemonExe)) {
    throw "Core daemon was not found at $daemonExe"
}

$binaryPath = "`"$daemonExe`" --service --config `"$configFile`" --data-dir `"$dataDir`""
$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($existingService) {
    & sc.exe config $serviceName binPath= $binaryPath start= auto DisplayName= $displayName | Out-Null
} else {
    New-Service `
        -Name $serviceName `
        -BinaryPathName $binaryPath `
        -DisplayName $displayName `
        -StartupType Automatic | Out-Null
}

& sc.exe description $serviceName $description | Out-Null
& sc.exe failure $serviceName reset= 60 actions= restart/5000/restart/15000/none/0 | Out-Null

Set-IntMusicFirewallRule -DisplayName $httpRuleName -Protocol TCP -LocalPort "49330-49360"
Set-IntMusicFirewallRule -DisplayName $discoveryRuleName -Protocol UDP -LocalPort "5353"

Start-Service -Name $serviceName -ErrorAction SilentlyContinue
