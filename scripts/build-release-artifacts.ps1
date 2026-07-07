param(
    [string]$Output,
    [string]$ReleaseId,
    [switch]$SkipAndroid,
    [switch]$SkipAndroidAab,
    [switch]$SkipWindows,
    [switch]$SkipInstaller,
    [switch]$InstallInnoSetup
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$clientProject = Join-Path $repoRoot "apps\client-flutter"
$pubspec = Join-Path $clientProject "pubspec.yaml"
$versionLine = Get-Content -LiteralPath $pubspec | Where-Object { $_ -match '^version:\s+' } | Select-Object -First 1
if (-not $versionLine) {
    throw "Could not find version in $pubspec"
}
$version = ($versionLine -replace '^version:\s+', '').Trim()
$versionSafe = $version -replace '\+', '-'
$gitSha = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
if (-not $gitSha) {
    $gitSha = "nogit"
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not $ReleaseId) {
    $ReleaseId = "IntMusic-$versionSafe-$gitSha-$timestamp"
}
if (-not $Output) {
    $Output = Join-Path $repoRoot "packaging\dist\releases\$ReleaseId"
}
elseif (-not [System.IO.Path]::IsPathRooted($Output)) {
    $Output = Join-Path $repoRoot $Output
}

$releaseRoot = [System.IO.Path]::GetFullPath($Output)
$androidOut = Join-Path $releaseRoot "android"
$windowsOut = Join-Path $releaseRoot "windows"
New-Item -ItemType Directory -Force -Path $androidOut, $windowsOut | Out-Null

$script:artifacts = @()

function Add-Artifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Expected artifact was not found: $Path"
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $relative = [System.IO.Path]::GetRelativePath($releaseRoot, $resolved)
    $script:artifacts += [pscustomobject]@{
        path = $relative.Replace('\', '/')
        kind = $Kind
        target = $Target
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolved).Hash.ToLowerInvariant()
    }
}

function Copy-Artifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Expected artifact was not found: $Source"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Add-Artifact -Path $Destination -Kind $Kind -Target $Target
}

function Compress-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        throw "Expected directory was not found: $SourceDirectory"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }
    Compress-Archive -Path (Join-Path $SourceDirectory "*") -DestinationPath $Destination -Force
    Add-Artifact -Path $Destination -Kind $Kind -Target $Target
}

function Write-ReleaseMetadata {
    $manifest = [pscustomobject]@{
        app = "IntMusic"
        version = $version
        git_sha = $gitSha
        built_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        host = "$([System.Environment]::OSVersion.Platform)"
        artifacts = $script:artifacts
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $releaseRoot "manifest.json") -Encoding UTF8

    $checksumPath = Join-Path $releaseRoot "SHA256SUMS.txt"
    $lines = foreach ($artifact in $script:artifacts) {
        "$($artifact.sha256)  $($artifact.path)"
    }
    $lines | Set-Content -LiteralPath $checksumPath -Encoding UTF8
}

Write-Host "Release output:"
Write-Host "  $releaseRoot"

Push-Location $repoRoot
try {
    .\scripts\dev-shell.ps1

    if (-not $SkipWindows) {
        $setupExe = Join-Path $repoRoot "packaging\dist\installer\IntMusic-Windows-Setup.exe"
        if (Test-Path -LiteralPath $setupExe) {
            Remove-Item -LiteralPath $setupExe -Force
        }

        $windowsArgs = @()
        if ($SkipInstaller) {
            $windowsArgs += "-SkipInstaller"
        }
        if ($InstallInnoSetup) {
            $windowsArgs += "-InstallInnoSetup"
        }
        & .\scripts\build-windows-installer.ps1 @windowsArgs

        $windowsDist = Join-Path $repoRoot "packaging\dist\windows"
        Compress-DirectoryContents `
            -SourceDirectory (Join-Path $windowsDist "client") `
            -Destination (Join-Path $windowsOut "IntMusic-Windows-Client-$versionSafe.zip") `
            -Kind "flutter-windows-client-zip" `
            -Target "windows-x64"
        Compress-DirectoryContents `
            -SourceDirectory (Join-Path $windowsDist "core") `
            -Destination (Join-Path $windowsOut "IntMusic-Windows-Core-$versionSafe.zip") `
            -Kind "core-windows-zip" `
            -Target "windows-x64"

        if ((-not $SkipInstaller) -and (Test-Path -LiteralPath $setupExe)) {
            Copy-Artifact `
                -Source $setupExe `
                -Destination (Join-Path $windowsOut "IntMusic-Windows-Setup-$versionSafe.exe") `
                -Kind "windows-installer" `
                -Target "windows-x64"
        }
    }

    if (-not $SkipAndroid) {
        Push-Location $clientProject
        try {
            flutter build apk --release
            if (-not $SkipAndroidAab) {
                flutter build appbundle --release
            }
        }
        finally {
            Pop-Location
        }

        Copy-Artifact `
            -Source (Join-Path $clientProject "build\app\outputs\flutter-apk\app-release.apk") `
            -Destination (Join-Path $androidOut "IntMusic-Android-$versionSafe.apk") `
            -Kind "flutter-apk" `
            -Target "android"

        if (-not $SkipAndroidAab) {
            Copy-Artifact `
                -Source (Join-Path $clientProject "build\app\outputs\bundle\release\app-release.aab") `
                -Destination (Join-Path $androidOut "IntMusic-Android-$versionSafe.aab") `
                -Kind "flutter-aab" `
                -Target "android"
        }
    }

    Write-ReleaseMetadata

    Write-Host "Artifacts:"
    foreach ($artifact in $script:artifacts) {
        Write-Host "  $($artifact.path)"
    }
    Write-Host ""
    Write-Host "Manifest:"
    Write-Host "  $(Join-Path $releaseRoot "manifest.json")"
}
finally {
    Pop-Location
}
