param(
    [string]$InstallDir = $PSScriptRoot,
    [switch]$StopClient,
    [switch]$StopCore
)

$ErrorActionPreference = "Stop"

$serviceName = "IntMusicCore"
$normalizedInstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd("\") + "\"
$logRoot = Join-Path $env:ProgramData "IntMusic\Installer"
$logFile = Join-Path $logRoot "install.log"

function Write-IntMusicStopLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content `
        -LiteralPath $logFile `
        -Value "[$timestamp] $Message" `
        -Encoding UTF8
}

function Get-IntMusicInstallProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    $processes = foreach ($name in $Names) {
        Get-CimInstance `
            -ClassName Win32_Process `
            -Filter "Name='$name'" `
            -ErrorAction SilentlyContinue
    }
    return @(
        $processes |
            Where-Object {
                $path = [string]$_.ExecutablePath
                -not [string]::IsNullOrWhiteSpace($path) -and
                    [System.IO.Path]::GetFullPath($path).StartsWith(
                        $normalizedInstallDir,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
            }
    )
}

function Wait-IntMusicProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names,
        [int]$TimeoutSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $remaining = @(Get-IntMusicInstallProcesses -Names $Names)
        if ($remaining.Count -eq 0) {
            return @()
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return @(Get-IntMusicInstallProcesses -Names $Names)
}

function Stop-IntMusicProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    $remaining = @(Get-IntMusicInstallProcesses -Names $Names)
    foreach ($process in $remaining) {
        Write-IntMusicStopLog "Force stopping $($process.Name) (PID $($process.ProcessId)) from $($process.ExecutablePath)"
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }
    $remaining = @(Wait-IntMusicProcesses -Names $Names -TimeoutSeconds 15)
    if ($remaining.Count -gt 0) {
        $descriptions = $remaining |
            ForEach-Object { "$($_.Name) (PID $($_.ProcessId))" }
        throw "The following IntMusic processes did not stop: $($descriptions -join ', ')"
    }
}

function Invoke-IntMusicServiceControl {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & sc.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        Write-IntMusicStopLog "[SC] $line"
    }
    if ($exitCode -ne 0) {
        throw "sc.exe $($Arguments -join ' ') failed with exit code $exitCode"
    }
}

function Format-IntMusicException {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $description = $exception.Message
        if ($exception.PSObject.Properties.Name -contains "NativeErrorCode") {
            $description += " (Win32 $($exception.NativeErrorCode))"
        }
        $parts.Add($description)
        $exception = $exception.InnerException
    }
    return $parts -join " -> "
}

function Wait-IntMusicServiceStopped {
    param([int]$TimeoutSeconds = 20)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -eq $service -or
            $service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "The $serviceName service did not reach the Stopped state within $TimeoutSeconds seconds."
}

function Stop-IntMusicCoreService {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $service -or
        $service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        return
    }

    Write-IntMusicStopLog "Stopping the $serviceName service."
    try {
        if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::StopPending) {
            Stop-Service -Name $serviceName -Force -ErrorAction Stop
        }
        Wait-IntMusicServiceStopped -TimeoutSeconds 20
        Write-IntMusicStopLog "The $serviceName service stopped gracefully."
        return
    } catch {
        Write-IntMusicStopLog "Graceful service stop failed: $(Format-IntMusicException -ErrorRecord $_)"
    }

    # Older Core builds could accept the first STOP request and then wait
    # forever for open WebSocket/audio connections. Their control handler was
    # already released, so all subsequent controls fail with Win32 1061 even
    # though SCM still reports Running/STOPPABLE. Disable automatic recovery
    # before terminating only the verified process under InstallDir; otherwise
    # SCM could restart the old executable while Setup is replacing it.
    Write-IntMusicStopLog "Disabling Core recovery temporarily for legacy-service termination."
    Invoke-IntMusicServiceControl -Arguments @(
        "config",
        $serviceName,
        "start=",
        "disabled"
    )
    Invoke-IntMusicServiceControl -Arguments @(
        "failure",
        $serviceName,
        "reset=",
        "0",
        "actions=",
        "none/0"
    )
    Stop-IntMusicProcesses -Names @("local-music-core-daemon.exe")
    Wait-IntMusicServiceStopped -TimeoutSeconds 20
    Write-IntMusicStopLog "The legacy Core service process was terminated safely."
}

function Request-IntMusicClientShutdown {
    if (-not ("IntMusicInstallerNativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class IntMusicInstallerNativeMethods
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint RegisterWindowMessage(string message);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(
        IntPtr window,
        uint message,
        UIntPtr wParam,
        IntPtr lParam);
}
"@
    }

    $message = [IntMusicInstallerNativeMethods]::RegisterWindowMessage(
        "IntMusic.ShutdownForUpdate"
    )
    if ($message -ne 0) {
        $broadcast = [IntPtr]0xffff
        [void][IntMusicInstallerNativeMethods]::PostMessage(
            $broadcast,
            $message,
            [UIntPtr]::Zero,
            [IntPtr]::Zero
        )
        Write-IntMusicStopLog "Requested a graceful IntMusic Client shutdown."
    }
}

try {
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
    Write-IntMusicStopLog "Preparing IntMusic update in $normalizedInstallDir"

    if ($StopClient) {
        $clientNames = @("IntMusic.exe")
        Request-IntMusicClientShutdown
        $remainingClients = @(
            Wait-IntMusicProcesses -Names $clientNames -TimeoutSeconds 8
        )
        if ($remainingClients.Count -gt 0) {
            Stop-IntMusicProcesses -Names $clientNames
        }
        Write-IntMusicStopLog "IntMusic Client is stopped."
    }

    if ($StopCore) {
        Stop-IntMusicCoreService
        Stop-IntMusicProcesses -Names @(
            "local-music-core-daemon.exe",
            "local-music-core.exe"
        )
        Write-IntMusicStopLog "IntMusic Core is stopped."
    }
} catch {
    try {
        Write-IntMusicStopLog "ERROR: $($_.Exception.Message)"
    } catch {
        # Preserve the original error when logging is unavailable.
    }
    throw
}
