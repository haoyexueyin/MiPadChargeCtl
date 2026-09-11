$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

$service = Get-Service -Name MiPadChargeLimiter -ErrorAction Stop
if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
    throw "MiPadChargeLimiter must be stopped before activation."
}

$installedExe = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles "MiPadChargeLimiter\MiPadChargeLimiter.exe"))
$expectedExe = [IO.Path]::GetFullPath("$env:ProgramFiles\MiPadChargeLimiter\MiPadChargeLimiter.exe")
if ($installedExe -ne $expectedExe -or -not (Test-Path -LiteralPath $installedExe)) {
    throw "Installed controller path validation failed."
}
$sourceCertificate = Join-Path $PSScriptRoot "MiPadChargeCtlTest.cer"
if (-not (Test-Path -LiteralPath $sourceCertificate)) {
    throw "MiPadChargeCtlTest.cer is missing from this package."
}
$expectedCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($sourceCertificate)
$installedSignature = Get-AuthenticodeSignature -LiteralPath $installedExe
if ($installedSignature.Status -ne "Valid" -or
    -not $installedSignature.SignerCertificate -or
    $installedSignature.SignerCertificate.Thumbprint -ne $expectedCertificate.Thumbprint) {
    throw "Installed controller signature is invalid or unexpected."
}

Write-Host "Running final read-only probe before activation..."
& $installedExe --probe
if ($LASTEXITCODE -ne 0) { throw "Controller probe failed; activation was not attempted." }

try {
    & (Join-Path $PSScriptRoot "Unlock-Writes.ps1")
    & sc.exe config MiPadChargeLimiter start= delayed-auto | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Configuring automatic startup failed." }
    Start-Service -Name MiPadChargeLimiter
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(15))
}
catch {
    $activationFailure = $_.Exception.Message
    $rollbackProblems = [Collections.Generic.List[string]]::new()
    $chargingRestored = $false
    $serviceStoppedConfirmed = $false

    try {
        $currentService = Get-Service -Name MiPadChargeLimiter -ErrorAction Stop
        if ($currentService.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
            Stop-Service -Name MiPadChargeLimiter -ErrorAction Stop
            $currentService.WaitForStatus(
                [ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(30)
            )
        }
        $currentService.Refresh()
        if ($currentService.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
            throw "Controller service is not stopped."
        }
        $serviceStoppedConfirmed = $true
    } catch {
        $rollbackProblems.Add("Controller service could not be confirmed stopped: $($_.Exception.Message)")
    }

    if ($serviceStoppedConfirmed) {
        try {
            $driverStatus = (& (Join-Path $PSScriptRoot "MiPadChargeCtl.ps1") status | Out-String)
            if ($driverStatus -match "writes=locked") {
                & (Join-Path $PSScriptRoot "Unlock-Writes.ps1")
            }
            & (Join-Path $PSScriptRoot "MiPadChargeCtl.ps1") enable -ConfirmWrite | Out-Host
            $verifiedStatus = (& (Join-Path $PSScriptRoot "MiPadChargeCtl.ps1") status | Out-String)
            if ($verifiedStatus -notmatch "CHG_CONFIG=1") {
                throw "Driver did not verify charging enabled."
            }
            $chargingRestored = $true
        } catch {
            $rollbackProblems.Add("Charging could not be restored: $($_.Exception.Message)")
        }
    }

    if ($chargingRestored) {
        try {
            & (Join-Path $PSScriptRoot "Lock-Writes.ps1")
            $lockedStatus = (& (Join-Path $PSScriptRoot "MiPadChargeCtl.ps1") status | Out-String)
            if ($lockedStatus -notmatch "CHG_CONFIG=1" -or $lockedStatus -notmatch "writes=locked") {
                throw "Final safe state was not verified."
            }
        } catch {
            $rollbackProblems.Add("Driver writes could not be safely locked: $($_.Exception.Message)")
        }
    }

    & sc.exe config MiPadChargeLimiter start= demand *> $null
    if ($LASTEXITCODE -ne 0) {
        $rollbackProblems.Add("Service startup mode could not be reset to manual.")
    }

    if ($rollbackProblems.Count -gt 0) {
        throw "Activation failed: $activationFailure Rollback was incomplete: $($rollbackProblems -join ' | ') If the controller is still running, stop it before changing or locking the driver state."
    }
    throw "Activation failed but charging was restored and writes were locked: $activationFailure"
}

Start-Sleep -Seconds 3
Write-Host "Automatic limiter activated and configured for delayed startup."
& (Join-Path $PSScriptRoot "AutoLimiter-Status.ps1")
