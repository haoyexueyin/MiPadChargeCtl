$ErrorActionPreference = "Stop"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

try {
    if (Confirm-SecureBootUEFI) {
        throw "Secure Boot is still enabled. Refusing to install the test driver."
    }
} catch [System.PlatformNotSupportedException] {
    throw "Secure Boot state could not be verified. Refusing to install."
}

$boot = (& bcdedit.exe /enum "{current}" | Out-String)
if ($boot -notmatch "(?im)^testsigning\s+Yes\s*$") {
    throw "TESTSIGNING is not enabled for the current boot entry."
}

$sourceDriver = Join-Path $PSScriptRoot "MiPadChargeCtl.sys"
$sourceCertificate = Join-Path $PSScriptRoot "MiPadChargeCtlTest.cer"
if (-not (Test-Path -LiteralPath $sourceDriver) -or -not (Test-Path -LiteralPath $sourceCertificate)) {
    throw "MiPadChargeCtl.sys or MiPadChargeCtlTest.cer is missing from this folder."
}

& sc.exe query MiPadChargeCtl *> $null
if ($LASTEXITCODE -eq 0) {
    throw "The MiPadChargeCtl service already exists. Run Uninstall.ps1 before reinstalling."
}

$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($sourceCertificate)
$signature = Get-AuthenticodeSignature -LiteralPath $sourceDriver
if (-not $signature.SignerCertificate -or
    $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
    throw "The driver signature does not match MiPadChargeCtlTest.cer."
}

$installDirectory = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot "System32\drivers"))
$expectedDirectory = [IO.Path]::GetFullPath("$env:SystemRoot\System32\drivers")
if ($installDirectory -ne $expectedDirectory) {
    throw "System driver directory validation failed."
}

$installedDriver = Join-Path $installDirectory "MiPadChargeCtl.sys"
Copy-Item -LiteralPath $sourceDriver -Destination $installedDriver -Force

if ((Get-FileHash -LiteralPath $sourceDriver -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath $installedDriver -Algorithm SHA256).Hash) {
    throw "The installed driver hash does not match the signed source file."
}

& sc.exe create MiPadChargeCtl type= kernel start= demand binPath= $installedDriver
if ($LASTEXITCODE -ne 0) {
    throw "Creating the driver service failed with exit code $LASTEXITCODE."
}

$parameters = "HKLM:\SYSTEM\CurrentControlSet\Services\MiPadChargeCtl\Parameters"
New-Item -Path $parameters -Force | Out-Null
New-ItemProperty -Path $parameters -Name AllowWrites -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $parameters -Name CertificateThumbprint -PropertyType String -Value $certificate.Thumbprint -Force | Out-Null

Import-Certificate -FilePath $sourceCertificate -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $sourceCertificate -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null

& sc.exe start MiPadChargeCtl
if ($LASTEXITCODE -ne 0) {
    throw "Starting the driver failed with exit code $LASTEXITCODE."
}

Write-Host "Driver loaded in read-only mode. Running the first status probe..."
& (Join-Path $PSScriptRoot "MiPadChargeCtl.ps1") status
