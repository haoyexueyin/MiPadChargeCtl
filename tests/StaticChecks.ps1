$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$failures = [Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $failures.Add($Message) }
}

$scripts = Get-ChildItem -LiteralPath $root -File -Filter "*.ps1"
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    Assert-True ($errors.Count -eq 0) "$($script.Name) has PowerShell parser errors."
}

try {
    [xml](Get-Content -LiteralPath (Join-Path $root "MiPadChargeCtl.vcxproj") -Raw) | Out-Null
} catch {
    $failures.Add("MiPadChargeCtl.vcxproj is not valid XML: $($_.Exception.Message)")
}

$driver = Get-Content -LiteralPath (Join-Path $root "MiPadChargeCtl.c") -Raw
$client = Get-Content -LiteralPath (Join-Path $root "MiPadChargeCtl.ps1") -Raw

Assert-True ($driver -notmatch "MajorFunction\[i\]\s*=\s*NULL") "Unsupported IRPs must not use a NULL dispatch pointer."
Assert-True ($driver -notmatch "ExAcquireFastMutex") "ACPI discovery must not run while a fast mutex has raised IRQL."
Assert-True ($driver -match "KeInitializeMutex") "ACPI operations must use a PASSIVE_LEVEL-compatible mutex."
Assert-True ($driver -notmatch "CTL_CODE\([^\r\n]+FILE_ANY_ACCESS") "Public IOCTLs must not use FILE_ANY_ACCESS."
Assert-True ($driver -match "IoCreateDeviceSecure\s*\(") "The control device must be created with IoCreateDeviceSecure."
Assert-True ($driver -match "&SDDL_DEVOBJ_SYS_ALL_ADM_ALL") "The device ACL must be passed by address and restricted to SYSTEM and administrators."
Assert-True ($driver -match "AllowWrites") "The driver must default-gate hardware writes through policy."
Assert-True ($driver -match 'DevicePropertyHardwareID') "Battery PDO selection must verify the ACPI hardware ID."
Assert-True ($driver -match 'ACPI\\\\PNP0C0A') "Battery PDO selection must require ACPI\\PNP0C0A."
Assert-True ($driver -match "newReg03\s*=\s*oldReg03\s*\|\s*BQ25890_REG03_CHG_CONFIG") "Enable must preserve every REG03 bit except bit 4."
Assert-True ($driver -match "newReg03\s*=\s*oldReg03\s*&\s*~BQ25890_REG03_CHG_CONFIG") "Disable must preserve every REG03 bit except bit 4."
Assert-True ($driver -match "AcpiGetRegister\(pdo, BQ25890_REG03, &verifyReg03\)") "SET must verify REG03 by reading it back."
Assert-True ($client -match "IOCTL_GET_STATE\s*=\s*0x00226004") "Client GET IOCTL does not match the driver access bits."
Assert-True ($client -match "IOCTL_SET_CHARGE\s*=\s*0x0022E008") "Client SET IOCTL does not match the driver access bits."
Assert-True ($client -match "IOCTL_GET_DIAGNOSTICS\s*=\s*0x0022600C") "Client diagnostics IOCTL does not match the driver access bits."
Assert-True ($client -match "ConfirmWrite") "Client writes must require explicit confirmation."
Assert-True ($client -match 'ValidateSet\("status","diagnostics","enable","disable"\)') "Client must expose a diagnostics action."
Assert-True ($client -match '\$Action\s+-in\s+@\("enable",\s*"disable"\)\s+-and\s+-not\s+\$ConfirmWrite') "Only enable and disable may require ConfirmWrite."
Assert-True ($driver -match 'MIPAD_DIAGNOSTICS') "Driver must define a fixed diagnostics response contract."
foreach ($register in @('BQ25890_REG0B', 'BQ25890_REG11', 'BQ25890_REG12', 'BQ25890_REG13', 'BQ25890_REG14')) {
    Assert-True ($driver -match "AcpiGetRegister\(pdo, $register,") "Diagnostics must read fixed register $register."
}
Assert-True ($driver -notmatch 'BQ25890_REG0C') "Default diagnostics must not consume the read-to-clear REG0C fault latch."
$diagnosticContract = [regex]::Match(
    $driver,
    'typedef struct _MIPAD_DIAGNOSTICS\s*\{[\s\S]*?\}'
).Value
Assert-True ($diagnosticContract -notmatch '\bRegister\b') "Diagnostics contract must not expose a caller-selected register."

$installer = Get-Content -LiteralPath (Join-Path $root "Install-ReadOnly.ps1") -Raw
Assert-True ($installer -match 'System32\\drivers') "The driver must be installed into the protected system driver directory."
Assert-True ($installer -notmatch 'ProgramData.*MiPadChargeCtl') "The kernel image must not be installed into a user-creatable ProgramData directory."

$uninstaller = Get-Content -LiteralPath (Join-Path $root "Uninstall.ps1") -Raw
Assert-True ($uninstaller -match 'State -ne "Stopped"') "Uninstall must only remove the image after confirming the Stopped state."

$serviceSource = Get-Content -LiteralPath (Join-Path $root "ChargeLimiterService.cs") -Raw
$autoInstaller = Get-Content -LiteralPath (Join-Path $root "Install-AutoLimiter.ps1") -Raw
$builder = Get-Content -LiteralPath (Join-Path $root "Build-And-Sign.ps1") -Raw
$activator = Get-Content -LiteralPath (Join-Path $root "Activate-AutoLimiter.ps1") -Raw
$pauser = Get-Content -LiteralPath (Join-Path $root "Pause-AutoLimiter.ps1") -Raw
Assert-True ($serviceSource -match 'percent\s*>=\s*upperThreshold') "Upper threshold must disable charging."
Assert-True ($serviceSource -match 'percent\s*<=\s*lowerThreshold') "Lower threshold must enable charging."
Assert-True ($serviceSource -match 'ShouldFailOpen\(consecutiveFailures, configuration\.FailureLimit\)') "Repeated evaluation failures must trigger fail-open recovery."
Assert-True ($serviceSource -match 'configuration failure limit reached') "Configuration failures must not silently terminate the worker."
Assert-True ($serviceSource -match 'EnsureChargingEnabled\("controller exit"\)') "Controller exit must restore charging."
Assert-True ($serviceSource -match 'ReadWithTimeout\(8000\)') "Battery WMI collection must run behind a finite timeout."
Assert-True ($serviceSource -match 'DriverProxy') "Automatic policy must isolate driver requests behind a finite-time child process."
Assert-True ($serviceSource -match 'Driver request exceeded its 8 second time limit') "Driver requests must have a bounded parent-side wait."
Assert-True ($serviceSource -match 'unresolvedProcess') "Timed-out driver requests must remain tracked until actual process exit."
Assert-True ($serviceSource -match 'future requests are blocked') "An unresolved driver request must block later requests."
Assert-True ($serviceSource -match '!worker\.Join\(20000\)') "Service stop must reject an unconfirmed worker shutdown."
Assert-True ($serviceSource -match '!ChargeLimiterController\.EnsureChargingEnabled\(reason\)') "Service stop must fail when charging recovery cannot be verified."
Assert-True ($serviceSource -match 'stop suppresses late disable') "Self-tests must cover a sample returning after stop was requested."
Assert-True ($serviceSource -match 'three failures fail open') "Self-tests must cover the fail-open threshold."
Assert-True ($serviceSource -match 'firmware over-100 percentage clamps') "Self-tests must cover firmware percentages above 100."
Assert-True ($serviceSource -match 'disabled state uses fast enforcement interval') "Self-tests must cover fast disabled-state enforcement scheduling."
Assert-True ($serviceSource -match 'Reasserted charging disabled after firmware reset') "Firmware reset recovery must be explicit and observable."
Assert-True ($serviceSource -match 'ApplyVerifiedReg03\(state, enforcementDiagnostics\)') "Firmware-reset recovery must verify the latest REG03 sample."
Assert-True ($serviceSource -match 'ResetPolicyAfterFailOpen\(\)') "All successful fail-open paths must clear the latched policy state."
Assert-True ($autoInstaller -match 'EnforcementSeconds') "Installer must persist the disabled-state enforcement interval."
Assert-True ($serviceSource -notmatch 'SELECT[^\"]*Charging') "Automatic policy must not use the stale Windows Charging flag."
Assert-True ($autoInstaller -match '\$env:ProgramFiles') "SYSTEM service executable must be installed under Program Files."
Assert-True ($autoInstaller -match '\$controllerSignature\.Status\s+-ne\s+"Valid"') "Installer must reject a damaged or untrusted controller signature before creating a SYSTEM service."
Assert-True ($builder -match '800B0109') "Build may accept only WinVerifyTrust's exact untrusted-root result for the fresh test certificate."
Assert-True ($builder -match 'Test-BuildSignature') "Build must cryptographically validate both signed binaries."
Assert-True ($builder -notmatch 'Import-Certificate') "Build signature verification must not mutate a trust store."
Assert-True ($autoInstaller -match 'ReparsePoint') "Installer must reject reparse points in privileged writable paths."
Assert-True ($autoInstaller -match 'Existing path is not owned by SYSTEM or Administrators') "Installer must reject an untrusted existing log owner."
Assert-True ($autoInstaller -match 'Set-Acl -LiteralPath \$installDirectory') "SYSTEM service executable directory must have an explicit protected ACL."
Assert-True ($autoInstaller -match 'Set-Acl -LiteralPath \$installedExe') "SYSTEM service executable must have an explicit protected ACL."
Assert-True ($autoInstaller -match '\$installedSignature\.Status\s+-ne\s+"Valid"') "Installed service image signature must be revalidated."
Assert-True ($autoInstaller -match '& \$installedExe --probe') "The protected installed copy must perform the pre-service probe."
Assert-True ($autoInstaller -notmatch 'Unlock-Writes\.ps1') "Installation must not unlock hardware writes."
Assert-True ($autoInstaller -match 'failure MiPadChargeLimiter') "Service recovery actions must be configured."
Assert-True ($activator -match 'Unlock-Writes\.ps1') "Activation must explicitly unlock driver writes."
Assert-True ($activator -match '\$chargingRestored') "Activation rollback must track whether charging was actually restored."
Assert-True ($activator -match '\$serviceStoppedConfirmed') "Activation rollback must not race a controller whose stop is unconfirmed."
Assert-True ($activator -match 'Rollback was incomplete') "Activation rollback must surface recovery failures."
$enablePosition = $pauser.IndexOf('enable -ConfirmWrite')
$lockPosition = $pauser.IndexOf('Lock-Writes.ps1')
Assert-True ($enablePosition -ge 0 -and $lockPosition -gt $enablePosition) "Pause must restore charging before locking driver writes."

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "$($failures.Count) static check(s) failed."
}

Write-Host "Static checks passed: $($scripts.Count) PowerShell scripts, project XML, IOCTL contract, ACL, write gate, and REG03 bit-mask invariants."
