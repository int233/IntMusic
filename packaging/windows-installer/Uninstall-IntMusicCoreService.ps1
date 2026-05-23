$ErrorActionPreference = "SilentlyContinue"

$serviceName = "IntMusicCore"
$firewallRuleNames = @(
    "IntMusic Core HTTP",
    "IntMusic Core Discovery"
)
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($service) {
    if ($service.Status -ne "Stopped") {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    & sc.exe delete $serviceName | Out-Null
}

foreach ($ruleName in $firewallRuleNames) {
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}
