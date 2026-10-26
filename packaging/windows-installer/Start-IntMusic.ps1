param(
    [string]$InstallDir = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

$serviceName = "IntMusicCore"
$clientExe = Join-Path $InstallDir "client\IntMusic.exe"
$dataRoot = Join-Path $env:ProgramData "IntMusic\Core"
$endpointFile = Join-Path $dataRoot "data\core-endpoint.json"
$serviceLog = Join-Path $dataRoot "service.log"
$installLog = Join-Path $dataRoot "install.log"
$launcherLog = Join-Path $env:LOCALAPPDATA "IntMusic\Logs\launcher.log"
$script:lastProbeFailure = ""

function Write-IntMusicLauncherLog {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $launcherLog) | Out-Null
        if ((Test-Path $launcherLog) -and (Get-Item $launcherLog).Length -gt 1048576) {
            Move-Item -LiteralPath $launcherLog -Destination "$launcherLog.1" -Force
        }
        Add-Content -LiteralPath $launcherLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] $Message" -Encoding UTF8
    } catch { }
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
            -Uri "$($baseUrl.TrimEnd('/'))/api/v1/health" `
            -Method Get `
            -TimeoutSec 2
        return $status.ready -eq $true -and
            $status.name -eq "IntMusic Local Music Core" -and
            $status.api_version -eq "v1"
    } catch {
        $failure = $_.Exception.Message
        if ($failure -ne $script:lastProbeFailure) {
            Write-IntMusicLauncherLog "Core readiness check failed: $failure"
            $script:lastProbeFailure = $failure
        }
        return $false
    }
}

function Show-IntMusicStartupError {
    param([string]$Message)

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "IntMusic could not start",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

try {
    Write-IntMusicLauncherLog "Starting client. InstallDir=$InstallDir EndpointFile=$endpointFile"
    if (-not (Test-Path -LiteralPath $clientExe)) {
        throw "The IntMusic client was not found at $clientExe"
    }

    $service = Get-Service -Name $serviceName -ErrorAction Stop
    Write-IntMusicLauncherLog "Core service state: $($service.Status)"
    if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Start-Service -Name $serviceName
    } elseif ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Paused) {
        Resume-Service -Name $serviceName
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        $service.Refresh()
        if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            throw "The IntMusic Core service stopped during startup."
        }
        if (Test-IntMusicCoreReady) {
            Write-IntMusicLauncherLog "Core is ready. Launching $clientExe"
            Start-Process -FilePath $clientExe -WorkingDirectory (Split-Path $clientExe)
            exit 0
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "The IntMusic Core service did not become ready within 45 seconds."
} catch {
    $detail = $_.Exception.Message
    Write-IntMusicLauncherLog "ERROR: $detail"
    $message = "$detail`r`n`r`nDiagnostic logs:`r`n$launcherLog`r`n$serviceLog`r`n$installLog"
    Show-IntMusicStartupError -Message $message
    exit 1
}
