param(
    [switch]$SkipInstaller,
    [switch]$InstallInnoSetup,
    [string]$FfmpegBundle
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$clientProject = Join-Path $repoRoot "apps\client-flutter"
$clientRelease = Join-Path $clientProject "build\windows\x64\runner\Release"
$coreCliRelease = Join-Path $repoRoot "target\release\local-music-core.exe"
$coreDaemonRelease = Join-Path $repoRoot "target\release\local-music-core-daemon.exe"
$distRoot = Join-Path $repoRoot "packaging\dist\windows"
$clientDist = Join-Path $distRoot "client"
$coreDist = Join-Path $distRoot "core"
$installerOut = Join-Path $repoRoot "packaging\dist\installer"
$issFile = Join-Path $repoRoot "packaging\windows-installer\IntMusic.iss"

function Remove-DirectorySafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedParent
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $resolvedParent = (Resolve-Path -LiteralPath $ExpectedParent).Path
    if (-not $resolvedPath.StartsWith($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove '$resolvedPath' because it is outside '$resolvedParent'."
    }

    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function Assert-NativeCommandSucceeded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    if ($ExitCode -ne 0) {
        throw "$Command failed with exit code $ExitCode."
    }
}

function Assert-RequiredFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }
}

Push-Location $repoRoot
try {
    .\scripts\dev-shell.ps1

    cargo build -p core-cli -p core-daemon --release
    Assert-NativeCommandSucceeded `
        -Command "Cargo Windows release build" `
        -ExitCode $LASTEXITCODE

    Push-Location $clientProject
    try {
        flutter build windows --release
        Assert-NativeCommandSucceeded `
            -Command "Flutter Windows release build" `
            -ExitCode $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    Assert-RequiredFile `
        -Path (Join-Path $clientRelease "IntMusic.exe") `
        -Description "Flutter Windows client executable"
    Assert-RequiredFile `
        -Path $coreCliRelease `
        -Description "Core CLI executable"
    Assert-RequiredFile `
        -Path $coreDaemonRelease `
        -Description "Core daemon executable"
    $clientEntries = @(Get-ChildItem -LiteralPath $clientRelease -Force)
    if ($clientEntries.Count -eq 0) {
        throw "Flutter Windows release directory is empty: $clientRelease"
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot "packaging\dist") | Out-Null
    Remove-DirectorySafe -Path $distRoot -ExpectedParent (Join-Path $repoRoot "packaging\dist")
    New-Item -ItemType Directory -Force -Path $clientDist, $coreDist, $installerOut | Out-Null

    foreach ($entry in $clientEntries) {
        Copy-Item `
            -LiteralPath $entry.FullName `
            -Destination $clientDist `
            -Recurse `
            -Force
    }
    Copy-Item -LiteralPath $coreCliRelease -Destination $coreDist -Force
    Copy-Item -LiteralPath $coreDaemonRelease -Destination $coreDist -Force

    if (-not $FfmpegBundle) {
        $FfmpegBundle = $env:INTMUSIC_FFMPEG_DIR
    }
    if (-not $FfmpegBundle) {
        $FfmpegBundle = Join-Path $repoRoot "packaging\ffmpeg\windows-x64"
    }
    if (Test-Path -LiteralPath $FfmpegBundle -PathType Container) {
        $ffmpegExe = Join-Path $FfmpegBundle "bin\ffmpeg.exe"
        $ffprobeExe = Join-Path $FfmpegBundle "bin\ffprobe.exe"
        if (-not (Test-Path -LiteralPath $ffmpegExe) -or
            -not (Test-Path -LiteralPath $ffprobeExe)) {
            throw "The FFmpeg bundle is missing bin\ffmpeg.exe or bin\ffprobe.exe: $FfmpegBundle"
        }
        $ffmpegDestination = Join-Path $coreDist "tools\ffmpeg"
        New-Item -ItemType Directory -Force -Path $ffmpegDestination | Out-Null
        Copy-Item -Path (Join-Path $FfmpegBundle "*") `
            -Destination $ffmpegDestination `
            -Recurse `
            -Force
        & (Join-Path $PSScriptRoot "test-windows-ffmpeg-bundle.ps1") `
            -Bundle $ffmpegDestination
    }
    else {
        throw @"
The bundled FFmpeg directory was not found: $FfmpegBundle
Build the pinned LGPL bundle from an MSYS2 UCRT64 shell with:
  ./scripts/build-bundled-ffmpeg.sh --output packaging/ffmpeg/windows-x64
or pass -FfmpegBundle with an already validated bundle.
"@
    }

    Write-Host "Windows staging directory:"
    Write-Host "  $distRoot"

    if ($SkipInstaller) {
        Write-Host "Skipped installer generation."
        return
    }

    $isccCommand = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    $isccPath = if ($null -ne $isccCommand) { $isccCommand.Source } else { $null }
    if ($null -eq $isccPath) {
        $candidatePaths = @(@(
            "$env:ProgramFiles\Inno Setup 7\ISCC.exe",
            "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        if ($candidatePaths.Count -gt 0) {
            $isccPath = $candidatePaths[0]
        }
    }

    if (($null -eq $isccPath) -and $InstallInnoSetup) {
        $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
        if ($null -eq $winget) {
            throw "Inno Setup is not installed and winget.exe was not found."
        }
        & $winget.Source install --id JRSoftware.InnoSetup --exact --silent --accept-package-agreements --accept-source-agreements
        Assert-NativeCommandSucceeded `
            -Command "Inno Setup installation" `
            -ExitCode $LASTEXITCODE
        $candidatePaths = @(@(
            "$env:ProgramFiles\Inno Setup 7\ISCC.exe",
            "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        if ($candidatePaths.Count -gt 0) {
            $isccPath = $candidatePaths[0]
        }
    }

    if ($null -eq $isccPath) {
        Write-Warning "Inno Setup was not found. Install Inno Setup 6 or 7 and rerun this script to create the setup EXE."
        Write-Host "You can also rerun with -InstallInnoSetup to install it through winget."
        Write-Host "Prepared files are still available at:"
        Write-Host "  $distRoot"
        return
    }

    Assert-RequiredFile `
        -Path (Join-Path $clientDist "IntMusic.exe") `
        -Description "Staged Flutter Windows client executable"
    Assert-RequiredFile `
        -Path (Join-Path $coreDist "local-music-core.exe") `
        -Description "Staged Core CLI executable"
    Assert-RequiredFile `
        -Path (Join-Path $coreDist "local-music-core-daemon.exe") `
        -Description "Staged Core daemon executable"
    Assert-RequiredFile `
        -Path (Join-Path $coreDist "tools\ffmpeg\bin\ffmpeg.exe") `
        -Description "Staged FFmpeg executable"
    Assert-RequiredFile `
        -Path (Join-Path $coreDist "tools\ffmpeg\bin\ffprobe.exe") `
        -Description "Staged ffprobe executable"

    & $isccPath $issFile
    Assert-NativeCommandSucceeded `
        -Command "Inno Setup compilation" `
        -ExitCode $LASTEXITCODE

    $setupExe = Join-Path $installerOut "IntMusic-Windows-Setup.exe"
    if (-not (Test-Path -LiteralPath $setupExe)) {
        throw "Inno Setup finished but '$setupExe' was not created."
    }

    Write-Host "Installer output:"
    Write-Host "  $installerOut"
}
finally {
    Pop-Location
}
