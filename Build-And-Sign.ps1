param(
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$project = Join-Path $projectRoot "MiPadChargeCtl.vcxproj"
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"

if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "Visual Studio Installer (vswhere.exe) was not found. Install VS 2022 C++ and WDK first."
}

$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" |
    Select-Object -First 1
if (-not $msbuild) {
    throw "MSBuild was not found."
}

& $msbuild $project /m /t:Rebuild "/p:Configuration=$Configuration" /p:Platform=x64
if ($LASTEXITCODE -ne 0) {
    throw "Driver build failed with exit code $LASTEXITCODE."
}

$driver = Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Filter "MiPadChargeCtl.sys" |
    Where-Object { $_.FullName -notlike "*\deploy\*" } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if (-not $driver) {
    throw "Build completed but MiPadChargeCtl.sys was not found."
}

& (Join-Path $projectRoot "Build-AutoLimiter.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Automatic limiter build failed with exit code $LASTEXITCODE."
}
$controller = Join-Path $projectRoot "x64\Release\MiPadChargeLimiter.exe"
if (-not (Test-Path -LiteralPath $controller)) {
    throw "Build completed but MiPadChargeLimiter.exe was not found."
}

$signTool = Get-ChildItem -LiteralPath "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -File -Filter "signtool.exe" |
    Where-Object { $_.FullName -like "*\x64\signtool.exe" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
if (-not $signTool) {
    throw "The x64 WDK/SDK SignTool was not found."
}

$subject = "CN=MiPadChargeCtl Test Certificate"
$certificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $certificate) {
    $certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $subject `
        -CertStoreLocation Cert:\CurrentUser\My `
        -HashAlgorithm SHA256 `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddYears(5)
}

& $signTool.FullName sign /v /fd SHA256 /sha1 $certificate.Thumbprint /s My $driver.FullName
if ($LASTEXITCODE -ne 0) {
    throw "Driver signing failed with exit code $LASTEXITCODE."
}
& $signTool.FullName sign /v /fd SHA256 /sha1 $certificate.Thumbprint /s My $controller
if ($LASTEXITCODE -ne 0) {
    throw "Controller signing failed with exit code $LASTEXITCODE."
}

function Test-BuildSignature {
    param(
        [Parameter(Mandatory = $true)]$Signature,
        [Parameter(Mandatory = $true)][string]$ExpectedThumbprint,
        [Parameter(Mandatory = $true)][string]$UntrustedRootMessage
    )

    if (-not $Signature.SignerCertificate -or
        $Signature.SignerCertificate.Thumbprint -ne $ExpectedThumbprint) {
        return $false
    }

    if ($Signature.Status -eq "Valid") {
        return $true
    }

    # A freshly created self-signed test certificate is intentionally not trusted on
    # the build machine. Accept only WinVerifyTrust's exact CERT_E_UNTRUSTEDROOT result;
    # hash mismatch and every other signature failure remain fatal.
    return ($Signature.Status -eq "UnknownError" -and
        $Signature.StatusMessage -eq $UntrustedRootMessage)
}

$untrustedRootUnsigned = [Convert]::ToUInt32("800B0109", 16)
$untrustedRootCode = [BitConverter]::ToInt32([BitConverter]::GetBytes($untrustedRootUnsigned), 0)
$untrustedRootMessage = [ComponentModel.Win32Exception]::new($untrustedRootCode).Message

$signature = Get-AuthenticodeSignature -LiteralPath $driver.FullName
if (-not (Test-BuildSignature -Signature $signature -ExpectedThumbprint $certificate.Thumbprint -UntrustedRootMessage $untrustedRootMessage)) {
    throw "The driver signature is missing, damaged, or signed by an unexpected certificate. Status=$($signature.Status); $($signature.StatusMessage)"
}
$controllerSignature = Get-AuthenticodeSignature -LiteralPath $controller
if (-not (Test-BuildSignature -Signature $controllerSignature -ExpectedThumbprint $certificate.Thumbprint -UntrustedRootMessage $untrustedRootMessage)) {
    throw "The controller signature is missing, damaged, or signed by an unexpected certificate. Status=$($controllerSignature.Status); $($controllerSignature.StatusMessage)"
}

$deploy = Join-Path $projectRoot "deploy"
New-Item -ItemType Directory -Path $deploy -Force | Out-Null
Copy-Item -LiteralPath $driver.FullName -Destination (Join-Path $deploy "MiPadChargeCtl.sys") -Force
Copy-Item -LiteralPath $controller -Destination (Join-Path $deploy "MiPadChargeLimiter.exe") -Force
Export-Certificate -Cert $certificate -FilePath (Join-Path $deploy "MiPadChargeCtlTest.cer") -Force | Out-Null

@(
    "MiPadChargeCtl.ps1",
    "Install-ReadOnly.ps1",
    "Unlock-Writes.ps1",
    "Lock-Writes.ps1",
    "Uninstall.ps1",
    "Check-DriverPrereqs.ps1",
    "Install-AutoLimiter.ps1",
    "Activate-AutoLimiter.ps1",
    "Pause-AutoLimiter.ps1",
    "AutoLimiter-Status.ps1",
    "Uninstall-AutoLimiter.ps1",
    "README.zh-CN.md"
) | ForEach-Object {
    Copy-Item -LiteralPath (Join-Path $projectRoot $_) -Destination (Join-Path $deploy $_) -Force
}

$driverHash = (Get-FileHash -LiteralPath $driver.FullName -Algorithm SHA256).Hash
$controllerHash = (Get-FileHash -LiteralPath $controller -Algorithm SHA256).Hash
$vsVersion = & $vswhere -latest -products * -property catalog_productDisplayVersion
$wdkVersion = Split-Path (Split-Path $signTool.DirectoryName -Parent) -Leaf
$buildInfo = @"
MiPadChargeCtl v5.2 automatic limiter x64 test-signed build
Build date: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
Build configuration: $Configuration | x64 | Windows Driver
Build environment: Visual Studio 2022 $vsVersion, WDK $wdkVersion
Compiler checks: /W4, warnings as errors, PREfast enabled
Build result: WDK build and ApiValidator passed

MiPadChargeCtl.sys SHA256:
$driverHash

MiPadChargeLimiter.exe SHA256:
$controllerHash

Embedded signer:
$($certificate.Subject)
Certificate thumbprint:
$($certificate.Thumbprint)
Certificate expiry: $($certificate.NotAfter.ToString('yyyy-MM-dd HH:mm:ss'))

The included certificate is self-signed. Install-ReadOnly.ps1 verifies that
the embedded signer matches the included certificate before importing it on
the target tablet and starting the driver in read-only mode.

This package must be tested first on the target Xiaomi Mi Pad 2 with the
read-only installation flow described in README.zh-CN.md.
"@
Set-Content -LiteralPath (Join-Path $deploy 'BUILD_INFO.txt') -Value $buildInfo -Encoding UTF8

Write-Host "Build and test signing succeeded."
Write-Host "Deploy folder: $deploy"
Write-Host "Certificate thumbprint: $($certificate.Thumbprint)"
