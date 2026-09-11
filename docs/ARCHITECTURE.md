# Architecture and safety model

## Components

### `MiPadChargeCtl.sys`

A narrow WDM helper driver. It locates the ACPI battery PDO, serializes firmware calls,
and exposes three versioned IOCTLs:

- `GET_STATE`: reads REG03 and returns charge/write state;
- `SET_CHARGE`: read-modify-writes REG03 bit 4 only, then verifies it;
- `GET_DIAGNOSTICS`: reads a fixed, non-destructive register set.

The control device ACL grants access only to SYSTEM and Administrators. Read and write
IOCTLs also require the corresponding handle permissions.

### `MiPadChargeLimiter.exe`

A .NET Framework Windows service running as LocalSystem. It reads battery capacity,
implements 50/80 hysteresis, and calls only the restricted driver IOCTLs.

Battery WMI and driver operations execute in child processes with bounded parent waits.
If a terminated driver child does not actually exit, the service retains that process and
blocks later driver requests until it has ended. It cannot falsely claim a safe stop while an
older kernel request remains unresolved.

### PowerShell management scripts

Installation is deliberately staged:

1. install the driver read-only;
2. verify status and diagnostics;
3. explicitly unlock writes for a manual round trip;
4. install the automatic service without activating it;
5. explicitly activate automatic writes.

## Hysteresis state machine

```text
             battery >= 80%
 charging  ----------------->  hold disabled
 enabled                         |
    ^                            | battery > 50%
    |                            | keep enforcing REG03=0
    +----------------------------+
             battery <= 50%
```

On first startup in the middle band, the controller adopts the currently observed REG03
state. A successful fail-open recovery clears the cached policy and requires a fresh
battery sample before charging can be disabled again.

## Scheduling

- Enabled or unknown state: sample capacity at the configured polling interval (30 s).
- Disabled state: inspect REG03 every configured enforcement interval (5 s).
- Capacity is still sampled only every 30 s while disabled.
- A firmware re-enable is corrected before the next capacity sample.

Every disable write is verified after 1.1 seconds using a new diagnostics read. Both the
latest REG03 bit and `CHRG_STAT=0` must agree before success is logged.

## Failure behavior

- Three consecutive evaluation failures trigger a best-effort enable operation.
- Service stop and system shutdown request enable and verify the latest REG03 value.
- If the worker has not exited within 20 seconds, stop is rejected rather than racing it.
- If charging recovery cannot be verified, the service reports failure instead of a clean
  stop.
- A truly stuck kernel/ACPI request cannot be repaired from user mode; disconnect external
  power and reboot.
