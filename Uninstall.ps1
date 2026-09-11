$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

$installedDriver = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot "System32\drivers\MiPadChargeCtl.sys"))
$expectedDriver = [IO.Path]::GetFullPath("$env:SystemRoot\System32\drivers\MiPadChargeCtl.sys")
if ($installedDriver -ne $expectedDriver) { throw "Driver path validation failed." }

$parameters = "HKLM:\SYSTEM\CurrentControlSet\Services\MiPadChargeCtl\Parameters"
$thumbprint = $null
if (Test-Path -LiteralPath $parameters) {
    $thumbprint = (Get-ItemProperty -LiteralPath $parameters -Name CertificateThumbprint -ErrorAction SilentlyContinue).CertificateThumbprint
}

& sc.exe query MiPadChargeCtl *> $null
if ($LASTEXITCODE -eq 0) {
    & sc.exe stop MiPadChargeCtl *> $null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1062) {
        throw "Stopping MiPadChargeCtl failed with exit code $LASTEXITCODE."
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $driverState = Get-CimInstance Win32_SystemDriver -Filter "Name='MiPadChargeCtl'" -ErrorAction SilentlyContinue
        if ($driverState -and $driverState.State -eq "Stopped") { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    if (-not $driverState -or $driverState.State -ne "Stopped") {
        throw "MiPadChargeCtl stop state could not be confirmed as Stopped; installed files were not removed."
    }

    & sc.exe delete MiPadChargeCtl
    if ($LASTEXITCODE -ne 0) {
        throw "Deleting MiPadChargeCtl failed with exit code $LASTEXITCODE."
    }
}

if ($thumbprint -and $thumbprint -match '^[0-9A-Fa-f]{40,64}$') {
    foreach ($storeName in @("Root", "TrustedPublisher")) {
        $store = [Security.Cryptography.X509Certificates.X509Store]::new($storeName, "LocalMachine")
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        try {
            $matches = $store.Certificates.Find(
                [Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                $thumbprint,
                $false
            )
            foreach ($match in $matches) { $store.Remove($match) }
        } finally {
            $store.Close()
        }
    }
}

if (Test-Path -LiteralPath $installedDriver) {
    Remove-Item -LiteralPath $installedDriver -Force
}

Write-Host "MiPadChargeCtl service and installed driver file were removed."
if ($thumbprint) {
    Write-Host "The recorded test certificate was removed when present."
}
