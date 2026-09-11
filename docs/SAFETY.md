# Safety and security notes

MiPadChargeCtl changes a live charger register from kernel mode. Treat it as experimental
hardware-control software.

## Before installation

- Confirm that the tablet matches [HARDWARE.md](HARDWARE.md).
- Back up important data.
- Make sure the tablet can be powered off and the charger can be physically disconnected.
- Do not begin with a write. Install read-only and inspect `diagnostics` first.
- Do not use the included test certificate for any purpose other than this package.

## Test-signing consequences

The public package is self-signed. Loading it requires Secure Boot to be disabled and
Windows test-signing mode to be enabled. This weakens kernel code-integrity protection and
is unsuitable for a machine whose security is more important than this experiment.

For broader distribution, use Microsoft's production driver-signing process instead of
shipping a shared private key. This repository never contains a private signing key.

## Built-in boundaries

- default write policy is locked;
- explicit administrator action is required to unlock it;
- only REG03 bit 4 can be changed;
- register and device identity checks are fixed in kernel code;
- privileged binaries and logs receive protected ACLs;
- the service executable's Authenticode signature is verified during installation and
  activation;
- stop and failure paths prefer charging enabled and report incomplete recovery.

## Emergency recovery

If the service reports repeated failures, an unresolved request, or cannot verify charging
enabled:

1. disconnect the charger;
2. shut down or restart Windows;
3. leave the driver write-locked;
4. collect `AutoLimiter-Status.ps1` output and the log from
   `%ProgramData%\\MiPadChargeLimiter\\ChargeLimiter.log`;
5. do not retry writes until the cause is understood.

To pause normally:

```powershell
.\Pause-AutoLimiter.ps1
```

This stops the service, restores charging, verifies the result, and locks driver writes.
