# v5.2 — firmware-reset guard

## Highlights

- automatic charging disable at 80% and enable at 50%;
- clamps firmware percentages above 100 without rescaling normal thresholds;
- samples battery capacity every 30 seconds;
- guards disabled REG03 state every 5 seconds;
- reasserts disable after Xiaomi firmware resets CHG_CONFIG;
- verifies writes using a delayed, fresh REG03/CHRG_STAT read;
- bounded child-process calls and unresolved-request tracking;
- fail-open recovery and protected SYSTEM-service installation.

## Test-signed package

File: `MiPadChargeCtl_v5.2_watchdog_50-80_x64_testsigned_20260911.zip`

SHA-256:

```text
0A930A5F7BDE3E1C2B67DD45FB39212C04FF40D03F3D1A7839F987B0D11E0114
```

The release is intended only for the verified Xiaomi Mi Pad 2 hardware profile. It needs
Secure Boot disabled and Windows test-signing mode enabled.

