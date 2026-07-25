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
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service -and
            $service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            Write-IntMusicStopLog "Stopping the $serviceName service."
            if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::StopPending) {
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
            }
            $service.WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(45)
            )
        }
        Stop-IntMusicProcesses -Names @(
            "local-music-core-daemon.exe",
            "local-music-core.exe"
        )
        Write-IntMusicStopLog "IntMusic Core is stopped."
    }

    exit 0
} catch {
    try {
        Write-IntMusicStopLog "ERROR: $($_.Exception.Message)"
    } catch {
        # Preserve the original error when logging is unavailable.
    }
    throw
}
