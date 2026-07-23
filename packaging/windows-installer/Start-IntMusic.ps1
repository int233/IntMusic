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
    if (-not (Test-Path -LiteralPath $clientExe)) {
        throw "The IntMusic client was not found at $clientExe"
    }

    $service = Get-Service -Name $serviceName -ErrorAction Stop
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
            Start-Process -FilePath $clientExe -WorkingDirectory (Split-Path $clientExe)
            exit 0
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "The IntMusic Core service did not become ready within 45 seconds."
} catch {
    $detail = $_.Exception.Message
    $message = "$detail`r`n`r`nDiagnostic logs:`r`n$serviceLog`r`n$installLog"
    Show-IntMusicStartupError -Message $message
    exit 1
}
