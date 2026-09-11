# Verified Xiaomi Mi Pad 2 hardware profile

This document separates facts observed on the development tablet from general product
specifications. Device instance suffixes can differ on another Windows installation.

## Tested tablet

| Item | Value observed on the device |
| --- | --- |
| Product | Xiaomi Mi Pad 2, Windows edition |
| Operating system | Windows 10 Pro x64, version/build `10.0.19043` |
| Processor | Intel Atom x5-Z8500, reported base clock 1.44 GHz, four processor instances |
| Graphics | Intel HD Graphics, PCI device `VEN_8086&DEV_22B0` |
| Battery name | `SR Real Battery` / `Intel SR 1SR Real Battery` |
| Battery chemistry | WMI chemistry value 6 (lithium-ion) |
| Battery ACPI device | `ACPI\\PNP0C0A\\1` |
| AC adapter | `ACPI\\ACPI0003` |
| Platform I²C controller | Intel Serial IO I²C, charger parent `ACPI\\808622C1\\2` |
| Charger ACPI device | `ACPI\\XMCC0002` |
| Firmware device path | `\\_SB.PCI0.I2C2.CWMD` |
| Xiaomi charger service | `BQMG0890` |
| Xiaomi driver | `BQMG0890.sys`, version `10.35.57.415`, dated 2015-12-15 |
| Driver provider | `XiaoMi A3 Driver` |
| Charger IC | Texas Instruments BQ25890 |
| I²C address selected by firmware | `0x6A` |
| BQ25890 part-number field | `PN=3`, read from REG14 |

The CPU family can be cross-checked on Intel's
[Atom x5-Z8500 product page](https://www.intel.com/content/www/us/en/products/sku/85474/intel-atom-x5z8500-processor-2m-cache-up-to-2-24-ghz/specifications.html).
Register definitions come from the TI
[BQ25890 product documentation](https://www.ti.com/product/BQ25890).

## ACPI control path recovered from this tablet

The tablet's DSDT contains these methods under the battery device:

- `BATC.GETC(register)` reads one BQ25890 register;
- `BATC.SETC(register, value)` writes one BQ25890 register;
- firmware selects the BQ25890 at I²C address `0x6A`.

MiPadChargeCtl uses only REG03 and fixes the register index in kernel code. REG03 bit 4 is
`CHG_CONFIG`:

| REG03 value seen | Bit 4 | Meaning |
| --- | --- | --- |
| `0x19` | 1 | Charging enabled |
| `0x09` | 0 | Charging disabled |

The driver also exposes a fixed read-only diagnostic set:

| Register | Fields used |
| --- | --- |
| REG0B | `CHRG_STAT`, power-good status |
| REG11 | VBUS-good and VBUS ADC |
| REG12 | Charge-current ADC, valid only when ADC conversion is active |
| REG13 | Charger status information |
| REG14 | Device part number |

REG0C is deliberately not read because its fault fields have read-to-clear semantics and
could consume information expected by the original driver.

## Battery capacity behavior observed

The firmware's battery capacity data is not perfectly stable:

- `RemainingCapacity` was observed above `FullChargedCapacity`, producing 100–106%;
- `Win32_Battery.EstimatedChargeRemaining` reported the same over-100 value;
- `FullChargedCapacity` later changed from 21,861 to 23,228 while running.

The controller clamps only over-100 display/policy input to 100. Values at and below 100
are not rescaled, so the 50% and 80% thresholds remain aligned with the firmware's normal
percentage range.

## Firmware re-enables charging

Real-device logs showed REG03 returning from `0x09` to `0x19` after charging had been
disabled. During a five-minute v5.2 test, the guard detected re-enable events separated by
approximately 12–51 seconds. Each event was followed by a verified write back to `0x09`;
the final state remained `CHRG_STAT=0`.

This behavior is why v5.2 separates the 30-second battery sampling loop from a 5-second
REG03 enforcement loop.

## Compatibility boundary

Do not assume compatibility from the product name alone. Before writes are unlocked, the
software verifies:

- a single battery ACPI interface responds to `GETC`;
- its hardware ID contains exactly `ACPI\\PNP0C0A`;
- register values are one byte;
- diagnostic REG14 reports `PN=3`;
- writes remain disabled until an administrator explicitly activates them.

If any of these facts differ, keep the driver in read-only mode and open an issue with the
read-only diagnostic output. Do not modify the source to bypass the checks without first
understanding the device firmware.

