param([string]$RepositoryRoot = (Split-Path $PSScriptRoot))

$ErrorActionPreference = "Stop"
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("intmusic-startup-test-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $temporary | Out-Null
$endpointFile = Join-Path $temporary "core-endpoint.json"
$launcherLog = Join-Path $temporary "launcher.log"
@{ base_url = "http://127.0.0.1:49338" } | ConvertTo-Json | Set-Content $endpointFile
$script:lastProbeFailure = ""
$script:requestedUri = ""
$script:probeFailure = $false
$script:probeResponse = @{ ready = $true; name = "IntMusic Local Music Core"; api_version = "v1" }

function Invoke-RestMethod {
    param($Uri, $Method, $TimeoutSec)
    $script:requestedUri = $Uri
    if ($script:probeFailure) { throw "simulated connection timeout" }
    return $script:probeResponse
}

try {
    foreach ($name in @("Start-IntMusic.ps1", "Install-IntMusicCoreService.ps1")) {
        $path = Join-Path $RepositoryRoot "packaging\windows-installer\$name"
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
        foreach ($definition in $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $false)) {
            # Import functions only; never register, stop, or start a service.
            Invoke-Expression $definition.Extent.Text
        }
        $script:probeResponse.ready = $true
        $script:probeFailure = $false
        if (-not (Test-IntMusicCoreReady)) { throw "$name rejected a ready Core" }
        if ($script:requestedUri -ne "http://127.0.0.1:49338/api/v1/health") {
            throw "$name still depends on the statistics endpoint"
        }
        $script:probeResponse.ready = $false
        if (Test-IntMusicCoreReady) { throw "$name accepted a Core that is not ready" }
        $script:probeFailure = $true
        if (Test-IntMusicCoreReady) { throw "$name accepted a failed health check" }
    }
    if (-not (Test-Path $launcherLog)) { throw "Launcher did not create its diagnostic log" }
    if ((Get-Content $launcherLog -Raw) -notmatch "simulated connection timeout") {
        throw "Launcher log did not include the probe failure"
    }
    Write-Output "Windows startup checks passed."
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
