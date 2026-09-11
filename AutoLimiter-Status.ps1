$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

$service = Get-Service -Name MiPadChargeLimiter -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Host "Automatic limiter is not installed."
    return
}

$configuration = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\MiPadChargeLimiter" -ErrorAction Stop
$enforcementSeconds = if ($null -ne $configuration.EnforcementSeconds) { $configuration.EnforcementSeconds } else { 5 }
Write-Host "Service: $($service.Status); thresholds: $($configuration.LowerThreshold)%-$($configuration.UpperThreshold)%; battery poll: $($configuration.PollSeconds)s; enforcement: ${enforcementSeconds}s"

$installedExe = Join-Path $env:ProgramFiles "MiPadChargeLimiter\MiPadChargeLimiter.exe"
if (Test-Path -LiteralPath $installedExe) {
    & $installedExe --probe
}

$log = Join-Path $env:ProgramData "MiPadChargeLimiter\ChargeLimiter.log"
if (Test-Path -LiteralPath $log) {
    Write-Host "Recent log:"
    Get-Content -LiteralPath $log -Tail 12
}
