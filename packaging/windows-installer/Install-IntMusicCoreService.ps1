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
$endpointFile = Join-Path $dataDir "core-endpoint.json"
$serviceLog = Join-Path $dataRoot "service.log"
$installLog = Join-Path $dataRoot "install.log"
$httpRuleName = "IntMusic Core HTTP"
$discoveryRuleName = "IntMusic Core Discovery"

function Write-IntMusicInstallLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $installLog -Value "[$timestamp] $Message" -Encoding UTF8
}

function Invoke-ServiceControl {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & sc.exe @Arguments | ForEach-Object {
        Write-IntMusicInstallLog $_
    }
    if ($LASTEXITCODE -ne 0) {
        throw "sc.exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

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

function Test-IntMusicCoreReady {
    if (-not (Test-Path -LiteralPath $endpointFile)) {
        return $false
    }

    try {
        $endpoint = Get-Content -LiteralPath $endpointFile -Raw | ConvertFrom-Json
        $baseUrl = [string]$endpoint.base_url
        if ([string]::IsNullOrWhiteSpace($baseUrl)) {
            return $false
        }
        $status = Invoke-RestMethod `
            -Uri "$($baseUrl.TrimEnd('/'))/api/v1/status" `
            -Method Get `
            -TimeoutSec 2
        return $status.name -eq "IntMusic Local Music Core" -and
            $status.api_version -eq "v1"
    } catch {
        return $false
    }
}

try {
    New-Item -ItemType Directory -Force -Path $dataRoot, $dataDir | Out-Null
    Write-IntMusicInstallLog "Installing Core service from $daemonExe"

    if (-not (Test-Path -LiteralPath $daemonExe)) {
        throw "Core daemon was not found at $daemonExe"
    }

    $binaryPath = "`"$daemonExe`" --service --config `"$configFile`" --data-dir `"$dataDir`""
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

    if ($existingService) {
        if ($existingService.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            Stop-Service -Name $serviceName -Force
            $existingService.WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(30)
            )
        }
        Invoke-ServiceControl -Arguments @(
            "config",
            $serviceName,
            "binPath=",
            $binaryPath,
            "start=",
            "auto",
            "DisplayName=",
            $displayName
        )
    } else {
        New-Service `
            -Name $serviceName `
            -BinaryPathName $binaryPath `
            -DisplayName $displayName `
            -StartupType Automatic | Out-Null
    }

    Invoke-ServiceControl -Arguments @("description", $serviceName, $description)
    Invoke-ServiceControl -Arguments @(
        "failure",
        $serviceName,
        "reset=",
        "60",
        "actions=",
        "restart/5000/restart/15000/none/0"
    )
    Invoke-ServiceControl -Arguments @("failureflag", $serviceName, "1")

    Set-IntMusicFirewallRule -DisplayName $httpRuleName -Protocol TCP -LocalPort "49330-49360"
    Set-IntMusicFirewallRule -DisplayName $discoveryRuleName -Protocol UDP -LocalPort "5353"

    Remove-Item -LiteralPath $endpointFile -Force -ErrorAction SilentlyContinue
    Start-Service -Name $serviceName

    $service = Get-Service -Name $serviceName
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        $service.Refresh()
        if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            throw "The IntMusic Core service stopped during startup. See $serviceLog"
        }
        if (Test-IntMusicCoreReady) {
            Write-IntMusicInstallLog "Core service passed its API health check."
            exit 0
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "The IntMusic Core service did not pass its API health check within 45 seconds. See $serviceLog"
} catch {
    Write-IntMusicInstallLog "ERROR: $($_.Exception.Message)"
    throw
}
