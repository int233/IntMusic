param(
    [Parameter(Mandatory = $true)]
    [string]$Bundle
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Format-NativeExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $unsigned = [BitConverter]::ToUInt32(
        [BitConverter]::GetBytes([int32]$ExitCode),
        0
    )
    return "$ExitCode (0x$($unsigned.ToString('X8')))"
}

function Assert-NativeVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw "$DisplayName was not found: $Executable"
    }

    try {
        $output = @(& $Executable -hide_banner -version 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        throw "$DisplayName could not be started from a plain Windows process: $($_.Exception.Message)"
    }

    if ($exitCode -ne 0) {
        $formattedExitCode = Format-NativeExitCode -ExitCode $exitCode
        $details = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
        $dependencyHint = ""
        if ($formattedExitCode -match "0xC0000135") {
            $dependencyHint = @"

Windows reported STATUS_DLL_NOT_FOUND. Rebuild the bundle with a static MinGW
runtime or include every required runtime DLL.
"@
        }
        throw @"
$DisplayName failed its standalone version check with exit code $formattedExitCode.
$details$dependencyHint
"@
    }

    if ($output.Count -eq 0) {
        throw "$DisplayName returned no version information."
    }
    Write-Host $output[0]
}

$resolvedBundle = (Resolve-Path -LiteralPath $Bundle).Path
Assert-NativeVersion `
    -Executable (Join-Path $resolvedBundle "bin\ffmpeg.exe") `
    -DisplayName "Bundled FFmpeg"
Assert-NativeVersion `
    -Executable (Join-Path $resolvedBundle "bin\ffprobe.exe") `
    -DisplayName "Bundled ffprobe"

Write-Host "Standalone Windows FFmpeg bundle validation passed:"
Write-Host "  $resolvedBundle"
