# MiPadChargeCtl

Experimental Windows 10 charge limiting for the **Xiaomi Mi Pad 2 (Windows edition)**.

MiPadChargeCtl stops battery charging at 80% and resumes it at 50%, while keeping the
external power path available to the tablet. It uses the tablet firmware's ACPI methods
to change only the `CHG_CONFIG` bit of the TI BQ25890 charger.

> [!WARNING]
> This is a device-specific, test-signed kernel driver validated on one Xiaomi Mi Pad 2.
> It is not a universal Windows battery tool. Read [SAFETY.md](docs/SAFETY.md) before use.

[简体中文说明](README.zh-CN.md) · [Verified hardware](docs/HARDWARE.md) ·
[Architecture](docs/ARCHITECTURE.md) · [Testing](docs/TESTING.md)

## Current status

Version 5.2 has been tested on real hardware with Windows 10 Pro x64 build 19043.

| Capability | Result |
| --- | --- |
| Read BQ25890 registers through `BATC.GETC` | Verified |
| Change only REG03 bit 4 through `BATC.SETC` | Verified |
| Stop charging | `REG03=0x09`, `CHRG_STAT=0` |
| Resume charging | `REG03=0x19`, `CHG_CONFIG=1` |
| 80% stop / 50% resume policy | Implemented; policy tests pass |
| Firmware reset guard | Verified for five minutes on hardware |
| Windows startup service | Installed and running; reboot validation is still recommended |

The Xiaomi firmware periodically restores REG03 from `0x09` to `0x19`. Version 5.2
checks REG03 every five seconds while charging is meant to remain disabled and reasserts
the disabled state. Hardware logs confirmed repeated recovery with final state
`REG03=0x09`, `CHRG_STAT=0` and no controller failures.

## Why a kernel driver is required

A normal application can open the Windows battery interface, but the Battery class stack
rejects user-mode `IOCTL_ACPI_EVAL_METHOD` requests with `ERROR_NOT_SUPPORTED`.

The small WDM helper driver obtains the battery ACPI physical device object and calls the
firmware's existing methods:

```text
MiPadChargeLimiter service
        │ restricted IOCTLs
        ▼
MiPadChargeCtl.sys
        │ IOCTL_ACPI_EVAL_METHOD
        ▼
BATC.GETC / BATC.SETC
        │ I²C address 0x6A
        ▼
TI BQ25890 REG03 bit 4 (CHG_CONFIG)
```

The public interface does not permit arbitrary register selection or arbitrary I²C writes.

## Quick start using a release package

Requirements:

- Xiaomi Mi Pad 2 Windows edition matching the hardware profile
- 64-bit Windows 10
- Administrator PowerShell
- Secure Boot disabled
- Windows test-signing mode enabled

First perform a read-only installation:

```powershell
.\Check-DriverPrereqs.ps1
.\Install-ReadOnly.ps1
.\MiPadChargeCtl.ps1 diagnostics
```

The expected charger identity is `PN=3`. Before enabling automation, manually prove that
disable and enable work:

```powershell
.\Unlock-Writes.ps1
.\MiPadChargeCtl.ps1 disable -ConfirmWrite
.\MiPadChargeCtl.ps1 diagnostics
.\MiPadChargeCtl.ps1 enable -ConfirmWrite
.\Lock-Writes.ps1
```

Only continue if disable produces `REG03=0x09` and `CHRG_STAT=0`, and enable restores
`REG03=0x19`.

Install and activate the automatic limiter in two separate stages:

```powershell
.\Install-AutoLimiter.ps1
.\Activate-AutoLimiter.ps1
.\AutoLimiter-Status.ps1
```

Default policy:

- battery at or above 80%: disable charging;
- battery at or below 50%: enable charging;
- between 50% and 80%: retain the current policy state;
- battery capacity sample every 30 seconds;
- REG03 enforcement every 5 seconds while disabled.

Pause safely, restoring charging and locking writes:

```powershell
.\Pause-AutoLimiter.ps1
```

## Building from source

Install Visual Studio 2022 with C++ desktop tools, a Windows 10/11 SDK, and the WDK. Run
from an elevated x64 PowerShell prompt:

```powershell
.\tests\StaticChecks.ps1
.\Build-And-Sign.ps1
```

The build uses `/W4`, warnings as errors, PREfast, ApiValidator, controller self-tests,
and SHA-256 Authenticode signatures. It creates a local self-signed test certificate and
a `deploy` directory. Private signing keys are never part of this repository.

## Important limitations

- Test-signing mode weakens the normal Windows kernel trust boundary.
- The driver is intentionally tied to `ACPI\\PNP0C0A` and the tested ACPI methods.
- `GETC` and `SETC` are separate firmware calls; they cannot be atomic against Xiaomi's
  original charger driver.
- If an underlying kernel/ACPI request never completes, software cannot guarantee charging
  recovery. The service blocks later requests and reports an unsafe stop instead.
- The Windows taskbar and WMI `Charging` flag may be stale. Use REG03 and `CHRG_STAT`.
- Long-duration operation, sleep/resume, battery replacement, and additional firmware
  versions still need community testing.

## Development disclosure

The initial implementation and documentation were developed with **OpenAI Codex**, under
human direction. Hardware discovery, safety decisions, and real-device validation were
performed interactively on the project owner's Xiaomi Mi Pad 2. See [AUTHORS.md](AUTHORS.md).

## License

[MIT](LICENSE)
