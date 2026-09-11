param(
    [ValidateRange(5, 95)]
    [int]$LowerThreshold = 50,

    [ValidateRange(10, 100)]
    [int]$UpperThreshold = 80,

    [ValidateRange(10, 600)]
    [int]$PollSeconds = 30,

    [ValidateRange(2, 15)]
    [int]$EnforcementSeconds = 5
)

$ErrorActionPreference = "Stop"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}
if ($LowerThreshold -ge $UpperThreshold -or ($UpperThreshold - $LowerThreshold) -lt 5) {
    throw "LowerThreshold must be at least 5 percentage points below UpperThreshold."
}
if ($EnforcementSeconds -ge $PollSeconds) {
    throw "EnforcementSeconds must be below PollSeconds."
}

function Get-OwnerSidValue([string]$Path) {
    $owner = (Get-Acl -LiteralPath $Path).Owner
    try {
        return ([Security.Principal.SecurityIdentifier]::new($owner)).Value
    } catch {
        return ([Security.Principal.NTAccount]::new($owner)).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    }
}

function Assert-TrustedExistingPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing reparse-point path: $Path"
    }
    $ownerSid = Get-OwnerSidValue $Path
    if ($ownerSid -notin @("S-1-5-18", "S-1-5-32-544")) {
        throw "Existing path is not owned by SYSTEM or Administrators: $Path"
    }
}

$sourceExe = Join-Path $PSScriptRoot "MiPadChargeLimiter.exe"
$sourceCertificate = Join-Path $PSScriptRoot "MiPadChargeCtlTest.cer"
if (-not (Test-Path -LiteralPath $sourceExe)) {
    throw "MiPadChargeLimiter.exe is missing from this package."
}
if (-not (Test-Path -LiteralPath $sourceCertificate)) {
    throw "MiPadChargeCtlTest.cer is missing from this package."
}
$expectedCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($sourceCertificate)
$controllerSignature = Get-AuthenticodeSignature -LiteralPath $sourceExe
if ($controllerSignature.Status -ne "Valid" -or
    -not $controllerSignature.SignerCertificate -or
    $controllerSignature.SignerCertificate.Thumbprint -ne $expectedCertificate.Thumbprint) {
    throw "Controller signature is not valid or does not match the included certificate."
}

& sc.exe query MiPadChargeCtl *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Install and validate the MiPadChargeCtl v4 driver first."
}

& sc.exe query MiPadChargeLimiter *> $null
if ($LASTEXITCODE -eq 0) {
    throw "MiPadChargeLimiter is already installed. Use Uninstall-AutoLimiter.ps1 before reinstalling."
}

& $sourceExe --self-test
if ($LASTEXITCODE -ne 0) { throw "Controller self-tests failed." }

$installDirectory = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles "MiPadChargeLimiter"))
$expectedDirectory = [IO.Path]::GetFullPath("$env:ProgramFiles\MiPadChargeLimiter")
if ($installDirectory -ne $expectedDirectory) { throw "Install path validation failed." }
$installedExe = Join-Path $installDirectory "MiPadChargeLimiter.exe"
$configPath = "HKLM:\SOFTWARE\MiPadChargeLimiter"
$serviceCreated = $false
$fileCopied = $false

try {
    if (Test-Path -LiteralPath $installDirectory) {
        Assert-TrustedExistingPath $installDirectory
        foreach ($existingItem in Get-ChildItem -LiteralPath $installDirectory -Force) {
            if ($existingItem.Name -ne "MiPadChargeLimiter.exe") {
                throw "Unexpected item in the existing controller directory: $($existingItem.Name)"
            }
            Assert-TrustedExistingPath $existingItem.FullName
        }
    }
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    $installItem = Get-Item -LiteralPath $installDirectory -Force
    if (($installItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Controller install directory must not be a reparse point."
    }

    $administratorsSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $installAcl = [Security.AccessControl.DirectorySecurity]::new()
    $installAcl.SetAccessRuleProtection($true, $false)
    $installAcl.SetOwner($administratorsSid)
    foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $installAcl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $installDirectory -AclObject $installAcl

    Copy-Item -LiteralPath $sourceExe -Destination $installedExe -Force
    $fileCopied = $true

    $exeAcl = [Security.AccessControl.FileSecurity]::new()
    $exeAcl.SetAccessRuleProtection($true, $false)
    $exeAcl.SetOwner($administratorsSid)
    foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $exeAcl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $installedExe -AclObject $exeAcl

    if ((Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash) {
        throw "Installed controller hash verification failed."
    }
    $installedSignature = Get-AuthenticodeSignature -LiteralPath $installedExe
    if ($installedSignature.Status -ne "Valid" -or
        -not $installedSignature.SignerCertificate -or
        $installedSignature.SignerCertificate.Thumbprint -ne $expectedCertificate.Thumbprint) {
        throw "Installed controller signature verification failed."
    }

    Write-Host "Running the installed controller's read-only battery and driver probe..."
    & $installedExe --probe
    if ($LASTEXITCODE -ne 0) { throw "Installed controller probe failed." }

    New-Item -Path $configPath -Force | Out-Null
    New-ItemProperty -Path $configPath -Name LowerThreshold -PropertyType DWord -Value $LowerThreshold -Force | Out-Null
    New-ItemProperty -Path $configPath -Name UpperThreshold -PropertyType DWord -Value $UpperThreshold -Force | Out-Null
    New-ItemProperty -Path $configPath -Name PollSeconds -PropertyType DWord -Value $PollSeconds -Force | Out-Null
    New-ItemProperty -Path $configPath -Name EnforcementSeconds -PropertyType DWord -Value $EnforcementSeconds -Force | Out-Null
    New-ItemProperty -Path $configPath -Name FailureLimit -PropertyType DWord -Value 3 -Force | Out-Null

    $logDirectory = [IO.Path]::GetFullPath((Join-Path $env:ProgramData "MiPadChargeLimiter"))
    $expectedLogDirectory = [IO.Path]::GetFullPath("$env:ProgramData\MiPadChargeLimiter")
    if ($logDirectory -ne $expectedLogDirectory) { throw "Log path validation failed." }
    if (Test-Path -LiteralPath $logDirectory) {
        Assert-TrustedExistingPath $logDirectory
        foreach ($existingLog in Get-ChildItem -LiteralPath $logDirectory -Force) {
            if ($existingLog.Name -notin @("ChargeLimiter.log", "ChargeLimiter.log.previous")) {
                throw "Unexpected file in the existing log directory: $($existingLog.Name)"
            }
            Assert-TrustedExistingPath $existingLog.FullName
        }
    } else {
        New-Item -ItemType Directory -Path $logDirectory | Out-Null
    }

    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administratorsSid)
    foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $logDirectory -AclObject $acl
    foreach ($existingLog in Get-ChildItem -LiteralPath $logDirectory -File -Force) {
        $fileAcl = [Security.AccessControl.FileSecurity]::new()
        $fileAcl.SetAccessRuleProtection($true, $false)
        $fileAcl.SetOwner($administratorsSid)
        foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
            $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow
            )
            $fileAcl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $existingLog.FullName -AclObject $fileAcl
    }

    New-Service `
        -Name "MiPadChargeLimiter" `
        -BinaryPathName ('"{0}"' -f $installedExe) `
        -DisplayName "Mi Pad Charge Limiter (50-80)" `
        -Description "Controls Mi Pad 2 charging between configured battery thresholds." `
        -StartupType Manual `
        -DependsOn "MiPadChargeCtl" | Out-Null
    $serviceCreated = $true

    & sc.exe failure MiPadChargeLimiter reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Configuring service recovery failed." }
    & sc.exe failureflag MiPadChargeLimiter 1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Configuring non-crash recovery failed." }
}
catch {
    if ($serviceCreated) { & sc.exe delete MiPadChargeLimiter *> $null }
    if (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Recurse -Force }
    if ($fileCopied -and (Test-Path -LiteralPath $installedExe)) { Remove-Item -LiteralPath $installedExe -Force }
    throw
}

Write-Host "Automatic limiter installed but NOT activated."
Write-Host "Thresholds: enable at or below $LowerThreshold%, disable at or above $UpperThreshold%."
Write-Host "Battery polling: ${PollSeconds}s; disabled-state enforcement: ${EnforcementSeconds}s."
Write-Host "The driver remains write-locked. Run Activate-AutoLimiter.ps1 when ready."
