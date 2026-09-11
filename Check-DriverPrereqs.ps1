$ErrorActionPreference = "Continue"

Write-Host "=== OS ==="
Get-CimInstance Win32_OperatingSystem |
    Select-Object Caption, Version, BuildNumber, OSArchitecture |
    Format-List

Write-Host "=== Platform ==="
[pscustomobject]@{
    Is64BitOS      = [Environment]::Is64BitOperatingSystem
    Is64BitProcess = [Environment]::Is64BitProcess
} | Format-List

Write-Host "=== Secure Boot ==="
try {
    $sb = Confirm-SecureBootUEFI
    "SecureBoot = $sb"
} catch {
    "SecureBoot query failed/not supported: $($_.Exception.Message)"
}

Write-Host "=== Boot configuration ==="
cmd /c 'bcdedit /enum {current}' |
    Select-String -Pattern 'testsigning','nointegritychecks','hypervisorlaunchtype'

Write-Host "=== Device Guard / HVCI ==="
try {
    Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
        Select-Object VirtualizationBasedSecurityStatus,
                      SecurityServicesConfigured,
                      SecurityServicesRunning |
        Format-List
} catch {
    "Device Guard query failed: $($_.Exception.Message)"
}

Write-Host "=== Battery target ==="
Get-PnpDevice -Class Battery |
    Format-Table Status, FriendlyName, InstanceId -AutoSize

Write-Host "=== Existing Xiaomi charger driver ==="
Get-CimInstance Win32_SystemDriver |
    Where-Object { $_.Name -eq 'BQMG0890' } |
    Select-Object Name, State, StartMode, PathName |
    Format-List

Write-Host "=== Build tools (optional, only needed if compiling on this PC) ==="
$msbuild = Get-Command msbuild.exe -ErrorAction SilentlyContinue
if ($msbuild) {
    "MSBuild = $($msbuild.Source)"
} else {
    "MSBuild = NOT FOUND"
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    & $vswhere -latest -products * -property installationPath
} else {
    "vswhere = NOT FOUND"
}

Write-Host "=== Finished ==="
