$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

$parameters = "HKLM:\SYSTEM\CurrentControlSet\Services\MiPadChargeCtl\Parameters"
if (-not (Test-Path -LiteralPath $parameters)) {
    throw "MiPadChargeCtl is not installed."
}

New-ItemProperty -Path $parameters -Name AllowWrites -PropertyType DWord -Value 1 -Force | Out-Null
& sc.exe stop MiPadChargeCtl
if ($LASTEXITCODE -ne 0) { throw "Stopping the driver failed." }
& sc.exe start MiPadChargeCtl
if ($LASTEXITCODE -ne 0) { throw "Starting the driver failed." }

Write-Host "Write path unlocked. No charger register has been changed yet."
& (Join-Path $PSScriptRoot "MiPadChargeCtl.ps1") status
