# Validation record and test guide

## Automated checks

Run:

```powershell
.\tests\StaticChecks.ps1
.\Build-AutoLimiter.ps1
```

The v5.2 controller currently executes 21 policy, scheduling, input, and recovery tests.
The driver build uses `/W4`, warnings as errors, PREfast, and WDK ApiValidator.

## Completed real-device validation

- read-only REG03 probe;
- manual disable and enable round trip;
- 30-second disabled-state retention test;
- diagnostic proof that `CHRG_STAT` changes from fast charging to not charging;
- confirmation that Windows taskbar/WMI charging flags can remain stale;
- over-100 battery percentage handling;
- service stop restoring charging;
- v5.2 five-minute firmware-reset guard test.

Representative verified states:

```text
Enabled:  REG03=0x19, CHG_CONFIG=1
Disabled: REG03=0x09, CHG_CONFIG=0, CHRG_STAT=0, VBUS_GD=1
```

## Still requested from community testing

- reboot/delayed-auto startup;
- sleep and resume;
- multi-hour and multi-day operation;
- natural crossing of both the 80% and 50% thresholds;
- other BIOS and Xiaomi driver versions;
- behavior after substantial battery aging or replacement.

Reports should include Windows build, BIOS version if known, BQMG0890 driver version,
read-only diagnostics, service status, and relevant log timestamps. Remove computer names
and user paths before posting logs publicly.

