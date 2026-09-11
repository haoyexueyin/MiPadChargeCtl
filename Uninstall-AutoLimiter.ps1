$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

$service = Get-Service -Name MiPadChargeLimiter -ErrorAction SilentlyContinue
if ($service) {
    & (Join-Path $PSScriptRoot "Pause-AutoLimiter.ps1")
    & sc.exe delete MiPadChargeLimiter
    if ($LASTEXITCODE -ne 0) { throw "Deleting MiPadChargeLimiter failed." }
}

$configPath = "HKLM:\SOFTWARE\MiPadChargeLimiter"
if (Test-Path -LiteralPath $configPath) {
    Remove-Item -LiteralPath $configPath -Recurse -Force
}

$installDirectory = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles "MiPadChargeLimiter"))
$expectedDirectory = [IO.Path]::GetFullPath("$env:ProgramFiles\MiPadChargeLimiter")
if ($installDirectory -ne $expectedDirectory) { throw "Install path validation failed." }
$installedExe = Join-Path $installDirectory "MiPadChargeLimiter.exe"
if (Test-Path -LiteralPath $installedExe) {
    Remove-Item -LiteralPath $installedExe -Force
}
if ((Test-Path -LiteralPath $installDirectory) -and
    -not (Get-ChildItem -LiteralPath $installDirectory -Force)) {
    Remove-Item -LiteralPath $installDirectory -Force
}

Write-Host "Automatic limiter removed. Driver remains installed, charging enabled, and writes locked."
Write-Host "Logs were preserved in $env:ProgramData\MiPadChargeLimiter."
