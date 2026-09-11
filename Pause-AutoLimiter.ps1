$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

$service = Get-Service -Name MiPadChargeLimiter -ErrorAction Stop
if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
    Stop-Service -Name MiPadChargeLimiter
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
}

& sc.exe config MiPadChargeLimiter start= demand | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Changing service startup mode failed." }

$driverStatus = (& (Join-Path $PSScriptRoot "MiPadChargeCtl.ps1") status | Out-String)
if ($driverStatus -match "writes=locked") {
    & (Join-Path $PSScriptRoot "Unlock-Writes.ps1")
}
& (Join-Path $PSScriptRoot "MiPadChargeCtl.ps1") enable -ConfirmWrite
& (Join-Path $PSScriptRoot "Lock-Writes.ps1")

Write-Host "Automatic limiter paused. Charging is enabled and driver writes are locked."

