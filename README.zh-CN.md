# MiPadChargeCtl v5.2 automatic limiter - 小米平板 2 Windows 10 充电控制

[English](README.md) · [已验证硬件信息](docs/HARDWARE.md) ·
[架构与安全边界](docs/ARCHITECTURE.md) · [测试记录](docs/TESTING.md)

> [!WARNING]
> 这是针对单台小米平板 2 Windows 版验证的测试签名内核驱动，不是通用 Windows
> 电池工具。安装前请完整阅读 [安全说明](docs/SAFETY.md)。

Target device:
- Xiaomi Mi Pad 2
- Windows 10 x64
- Battery ACPI device: ACPI\PNP0C0A\1
- Xiaomi charger driver: BQMG0890
- DSDT methods confirmed on the test machine: BATC.GETC / BATC.SETC
- Charger: BQ25890, I2C address 0x6A
- Charge switch: REG03 bit 4 (CHG_CONFIG)

## Why a kernel driver is needed

A user-mode handle to the Battery interface can be opened, but direct
IOCTL_ACPI_EVAL_METHOD is rejected by the Battery class stack with
Win32 error 50 (ERROR_NOT_SUPPORTED).

This helper therefore runs in kernel mode and gets the base PDO belonging
to the Windows Battery device. It sends IOCTL_ACPI_EVAL_METHOD directly to
that ACPI PDO.

It does NOT replace the Microsoft battery driver, does NOT attach an
upper/lower filter, and does NOT expose arbitrary I2C writes.

## 已实现的安全边界

The public IOCTL interface exposes only:

1. GET_STATE
   - BATC.GETC(0x03)
   - returns REG03 and CHG_CONFIG state

2. SET_CHARGE
   - reads REG03 first
   - changes bit 4 only
   - calls BATC.SETC(0x03, modifiedValue)
   - reads REG03 again and verifies the bit

3. GET_DIAGNOSTICS（v4 新增，只读）
   - 固定读取 REG0B、REG11、REG12、REG13、REG14
   - 报告芯片充电阶段、VBUS、充电电流 ADC 和芯片型号
   - 调用者不能选择寄存器，不扩大任意寄存器访问能力
   - 不读取具有“读取即清除”语义的 REG0C，避免消费原厂驱动的故障锁存

用户态不能指定其他寄存器。此外，驱动还增加了：

- 控制设备只允许 SYSTEM 和管理员访问；
- 读取、写入 IOCTL 分别要求句柄具备对应权限；
- 所有未支持的 IRP 都安全返回错误，不保留空分派函数；
- 多个电池接口逐一只读探测，只选择真正实现 GETC 的 BATC PDO；
- 候选 PDO 的 Hardware ID 必须精确包含 `ACPI\PNP0C0A`；
- ACPI 调用串行化，避免同时读写 REG03；
- 如果不止一个电池接口能响应 GETC，驱动会因目标不唯一而拒绝继续；
- GETC 返回值必须是 0x00～0xFF，否则按固件协议异常处理；
- 驱动默认 `AllowWrites=0`，即使调用 `disable/enable` 也会拒绝；
- 写入后重新读取 REG03，只有 bit4 与目标一致才返回成功。

仍有一个固件接口本身带来的限制：GETC 与 SETC 是两个独立 ACPI 调用，原厂
`BQMG0890.sys` 理论上可能在二者之间修改 REG03 的其他位。本驱动的互斥锁只能约束自身，
无法为两个 ACPI 方法建立跨驱动原子事务。因此本驱动仍属于单机实验版本；真机手动验证前，
不能把“读—改—写”描述成对系统内其他写入完全无竞争。

## First test

DO NOT start by disabling charging.

驱动正确编译、签名并加载后，第一条命令必须是只读状态：

    powershell -ExecutionPolicy Bypass -File .\MiPadChargeCtl.ps1 status

预期格式：

    REG03=0x??, CHG_CONFIG=1 (charging enabled), writes=locked, changed=no

Only after a successful read should "disable" be tested.

## 编译与测试签名

Requires a Windows PC with:
- Visual Studio 2022
- Windows Driver Kit (WDK) for Windows 10/11
- x64 C++/driver build tools

在装有 VS2022 C++ 与 WDK 的 x64 Windows 电脑上，以 PowerShell 执行：

    powershell -ExecutionPolicy Bypass -File .\Build-And-Sign.ps1

脚本会编译 x64 Release、创建/复用本地代码签名测试证书、给 SYS 做嵌入签名，
并生成 `deploy` 文件夹。把整个 `deploy` 文件夹复制到平板。

## 平板首次只读安装

仅在已经确认 `SecureBoot = False` 和 `testsigning Yes` 后，以管理员 PowerShell
进入 deploy 目录并执行：

    powershell -ExecutionPolicy Bypass -File .\Install-ReadOnly.ps1

脚本会安装测试证书、创建按需启动的内核服务，并保持 `AllowWrites=0`，最后自动执行一次
只读 `status`。驱动映像安装到受保护的 `%SystemRoot%\System32\drivers`；此阶段不会调用 SETC。

## 只有只读测试成功后才解锁写入

先执行：

    powershell -ExecutionPolicy Bypass -File .\Unlock-Writes.ps1

它只改变驱动策略并重启驱动，不会修改充电寄存器。确认输出显示 `writes=unlocked` 后，
才可手动测试：

    .\MiPadChargeCtl.ps1 disable -ConfirmWrite
    .\MiPadChargeCtl.ps1 status
    .\MiPadChargeCtl.ps1 enable -ConfirmWrite
    .\MiPadChargeCtl.ps1 status

测试后重新锁定：

    .\Lock-Writes.ps1

## v4 芯片状态诊断

任务栏图标由原厂电池驱动上报，可能不随外部 SETC 调用及时刷新。v4 可以直接读取
BQ25890 自身的状态寄存器：

    .\MiPadChargeCtl.ps1 diagnostics

其中 `CHRG_STAT=0` 表示芯片当前未充电，`ICHG_ADC` 是芯片最近一次 ADC 充电电流结果。
REG12 只有在 ADC 转换已启用且结果有效时才具有实时意义。实际充电开关以
REG03 和 CHRG_STAT 为准；Windows BatteryStatus 的 Charging/ChargeRate 以及任务栏图标
可能长时间滞后，不能作为是否已经停充的判据。

卸载驱动、安装文件和该测试证书：

    .\Uninstall.ps1

## Controller commands

Read only:

    .\MiPadChargeCtl.ps1 status

启用充电（需要管理员、驱动写入已解锁、显式确认参数）：

    .\MiPadChargeCtl.ps1 enable -ConfirmWrite

禁用充电：

    .\MiPadChargeCtl.ps1 disable -ConfirmWrite

## 自动 50%/80% 控制

只有完成前述手动测试，并确认禁充时 `CHRG_STAT=0` 后，才安装自动控制：

    .\Install-AutoLimiter.ps1

安装阶段只运行自检与只读探测，不会解锁驱动或改变充电状态。确认输出正确后再激活：

    .\Activate-AutoLimiter.ps1

默认策略：

- 电量大于等于 80% 且当前允许充电时，关闭充电；
- 电量小于等于 50% 且当前禁止充电时，恢复充电；
- 50%～80% 之间保持当前状态，形成滞回区间；
- 每 30 秒读取一次电量；进入停充区间后每 5 秒检查一次 REG03，固件复位充电位时立即重新关闭；
- 服务停止、系统关机或连续三次检查失败时，会尝试恢复充电并验证结果；
- 控制依据是电池容量和 BQ25890 寄存器，不使用任务栏或 WMI 的 `Charging/ChargeRate` 标志。

部分米板 2 固件会在满电附近同时报告大于 100% 的容量比例和
`EstimatedChargeRemaining`（真机观测为 106%）。控制器会把这种 100%～150% 的输入钳制为
100%；50%/80% 区间内的正常读数保持原值，因此两个控制阈值不变。

电池查询和每次驱动请求都有 8 秒的控制器等待上限。若底层内核/ACPI 请求在终止子进程后仍未结束，
服务会记录该未决请求、阻止继续发送驱动命令，并拒绝报告“安全停止”。这种底层卡死状态下软件无法保证
自动恢复充电；请断开充电器并重启平板，再检查日志和驱动状态。

真机已观测到固件会不定期把 REG03 从 0x09 恢复到 0x19；五分钟验收中，守护捕获事件的
间隔约为 12～51 秒。v5.2 将电量采样与
停充守护分离：电量仍按低频率读取，停充位则按 5 秒周期守护，日志会用
`Reasserted charging disabled after firmware reset` 标记一次固件复位后的重新关闭。

查看服务、阈值、驱动状态和最近日志：

    .\AutoLimiter-Status.ps1

暂停自动控制会先停止服务、恢复充电，再锁定驱动写入：

    .\Pause-AutoLimiter.ps1

重新启用仍使用：

    .\Activate-AutoLimiter.ps1

只卸载自动控制层、保留驱动：

    .\Uninstall-AutoLimiter.ps1

日志位于 `%ProgramData%\MiPadChargeLimiter\ChargeLimiter.log`。后台程序安装在受保护的
`%ProgramFiles%\MiPadChargeLimiter`，服务以 LocalSystem 运行并依赖 MiPadChargeCtl 驱动。

## 当前真机验证状态

- Windows 10 专业版 x64，版本 10.0.19043；
- Intel Atom x5-Z8500；
- 原厂 BQMG0890 充电驱动 10.35.57.415；
- BQ25890 `PN=3`，I²C 地址 0x6A；
- 手动启停、芯片诊断、服务停止恢复、106% 输入钳制均已验证；
- v5.2 已完成五分钟固件复位守护测试，最终保持 `REG03=0x09`、`CHRG_STAT=0`；
- 重启自启、睡眠唤醒和跨越 80%/50% 的长期自然循环仍欢迎社区继续验证。

完整的 ACPI 设备、驱动版本、寄存器和容量行为见 [硬件信息](docs/HARDWARE.md)。

## 开发说明

本项目初始驱动、控制服务、脚本、测试、安全分析和文档由 **OpenAI Codex** 在项目所有者
指导下协助开发；硬件资料、目标策略与全部真机验证由项目所有者提供和执行。详见
[AUTHORS.md](AUTHORS.md)。
