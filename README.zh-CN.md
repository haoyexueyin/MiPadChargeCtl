# MiPadChargeCtl

适用于小米平板 2 Windows 版的实验性充电阈值控制工具。

MiPadChargeCtl 在电量达到 80% 时停止为电池充电，在电量降至 50% 时恢复充电，
同时保持外接电源继续为平板供电。它通过平板固件已有的 ACPI 方法，只修改
TI BQ25890 充电芯片 `REG03` 中的 `CHG_CONFIG` 位。

[英文说明](README.md) · [已验证硬件信息](docs/HARDWARE.md) ·
[架构与安全边界](docs/ARCHITECTURE.md) · [测试记录](docs/TESTING.md) ·
[v5.2 发布页面](https://github.com/haoyexueyin/MiPadChargeCtl/releases/tag/v5.2)

> [!WARNING]
> 这是仅在一台小米平板 2 Windows 版上验证过的测试签名内核驱动，不是通用的
> Windows 电池管理工具。错误的硬件、固件或操作可能造成无法充电、数据丢失，
> 甚至需要重装系统。安装前请完整阅读[安全说明](docs/SAFETY.md)。

## 当前状态

v5.2 已在 Windows 10 专业版 x64（内部版本 19043）的真机上完成测试。

| 功能 | 验证结果 |
| --- | --- |
| 通过 `BATC.GETC` 读取 BQ25890 寄存器 | 已验证 |
| 通过 `BATC.SETC` 仅修改 `REG03` 第 4 位 | 已验证 |
| 停止充电 | `REG03=0x09`、`CHRG_STAT=0` |
| 恢复充电 | `REG03=0x19`、`CHG_CONFIG=1` |
| 80% 停充、50% 复充策略 | 已实现，策略自检通过 |
| 固件复位守护 | 已完成五分钟真机验证 |
| Windows 开机启动服务 | 已安装并运行，仍建议单独验证重启后的状态 |

小米固件会不定期把 `REG03` 从 `0x09` 恢复成 `0x19`。v5.2 在目标状态为停充时，
每 5 秒检查一次 `REG03`；发现固件重新启用充电后，会再次关闭充电。真机日志已经
验证多次恢复动作，测试结束时保持 `REG03=0x09`、`CHRG_STAT=0`，控制服务没有报错。

## 已验证的设备与硬件

- 设备：小米平板 2 Windows 版；
- 系统：Windows 10 专业版 x64，版本 `10.0.19043`；
- 处理器：Intel Atom x5-Z8500；
- 电池 ACPI 设备：`ACPI\PNP0C0A\1`；
- 小米原厂充电驱动：`BQMG0890.sys`，版本 `10.35.57.415`；
- 已确认的 DSDT 方法：`BATC.GETC`、`BATC.SETC`；
- 充电芯片：TI BQ25890，I²C 地址 `0x6A`，`PN=3`；
- 充电开关：`REG03` 第 4 位（`CHG_CONFIG`）。

不同批次、BIOS、DSDT 或驱动版本可能不兼容。完整的 ACPI 路径、设备标识、驱动版本、
寄存器含义和电池容量异常记录见[已验证硬件信息](docs/HARDWARE.md)。

## 为什么需要内核驱动

普通程序可以打开 Windows 的电池设备接口，但电池类驱动栈会拒绝用户态直接发送
`IOCTL_ACPI_EVAL_METHOD`，返回 Win32 错误 50（`ERROR_NOT_SUPPORTED`）。

因此，本项目使用一个功能受限的 WDM 辅助驱动，取得 Windows 电池设备对应的底层
物理设备对象（PDO），再把 ACPI 方法请求发送给该 PDO：

```text
MiPadChargeLimiter 后台服务
        │ 受限的 IOCTL
        ▼
MiPadChargeCtl.sys
        │ IOCTL_ACPI_EVAL_METHOD
        ▼
BATC.GETC / BATC.SETC
        │ I²C 地址 0x6A
        ▼
TI BQ25890 REG03 第 4 位（CHG_CONFIG）
```

这个驱动不会替换微软电池驱动，不会安装为上层或下层筛选驱动，也不向用户态开放
任意寄存器选择或任意 I²C 写入能力。

## 安全边界

驱动公开的 IOCTL 只有以下三类：

1. `GET_STATE`
   - 固定调用 `BATC.GETC(0x03)`；
   - 返回 `REG03` 和 `CHG_CONFIG` 状态。
2. `SET_CHARGE`
   - 先读取 `REG03`；
   - 只修改第 4 位；
   - 调用 `BATC.SETC(0x03, 修改后的值)`；
   - 再次读取 `REG03`，验证目标位确实改变。
3. `GET_DIAGNOSTICS`
   - 固定读取 `REG0B`、`REG11`、`REG12`、`REG13`、`REG14`；
   - 报告充电阶段、VBUS、充电电流 ADC 和芯片型号；
   - 不允许调用者选择其他寄存器；
   - 不读取具有“读取即清除”语义的 `REG0C`，避免消费原厂驱动的故障锁存状态。

此外还实施了以下限制：

- 控制设备只允许 `SYSTEM` 和管理员访问；
- 读取和写入 IOCTL 分别要求句柄具备对应权限；
- 所有不支持的 IRP 都明确返回错误；
- 逐一只读探测电池接口，只选择真正实现 `GETC` 的 `BATC` PDO；
- 候选 PDO 的硬件 ID 必须精确包含 `ACPI\PNP0C0A`；
- 如果多个电池接口都能响应 `GETC`，因目标不唯一而拒绝继续；
- ACPI 调用串行执行，避免本驱动同时读写 `REG03`；
- `GETC` 返回值必须处于 `0x00`～`0xFF`，否则按固件协议异常处理；
- 驱动默认设置 `AllowWrites=0`，此时 `disable` 和 `enable` 都会被拒绝；
- 写入后重新读取 `REG03`，只有第 4 位与目标一致才报告成功。

需要注意：`GETC` 和 `SETC` 是两个独立的 ACPI 调用。原厂 `BQMG0890.sys` 理论上可能
在两次调用之间修改 `REG03` 的其他位。本驱动的互斥锁只能约束自身，无法在不同驱动之间
建立原子事务，所以它仍然属于特定设备上的实验性方案。

## 使用发布包

### 使用条件

- 硬件与上述已验证的小米平板 2 Windows 版相符；
- 64 位 Windows 10；
- 管理员 PowerShell；
- 安全启动（Secure Boot）已经关闭；
- Windows 测试签名模式已经启用。

从 [v5.2 发布页面](https://github.com/haoyexueyin/MiPadChargeCtl/releases/tag/v5.2)
下载测试签名安装包。安装包 SHA-256：

```text
0A930A5F7BDE3E1C2B67DD45FB39212C04FF40D03F3D1A7839F987B0D11E0114
```

### 第一步：检查环境并只读安装

不要一开始就关闭充电。请先在解压目录中运行：

```powershell
.\Check-DriverPrereqs.ps1
.\Install-ReadOnly.ps1
.\MiPadChargeCtl.ps1 diagnostics
```

只读安装会安装测试证书、创建按需启动的内核服务，并保持 `AllowWrites=0`。驱动映像会
复制到受保护的 `%SystemRoot%\System32\drivers`；此阶段不会调用 `SETC`。

诊断结果应显示 `PN=3`。首次状态读取的格式类似：

```text
REG03=0x19, CHG_CONFIG=1 (charging enabled), writes=locked, changed=no
```

如果读取失败、型号不符或出现多个可响应的电池设备，请停止操作，不要解锁写入。

### 第二步：手动验证停充与复充

只读测试成功后，执行：

```powershell
.\Unlock-Writes.ps1
.\MiPadChargeCtl.ps1 disable -ConfirmWrite
.\MiPadChargeCtl.ps1 diagnostics
.\MiPadChargeCtl.ps1 enable -ConfirmWrite
.\MiPadChargeCtl.ps1 diagnostics
.\Lock-Writes.ps1
```

`Unlock-Writes.ps1` 只改变驱动策略并重启驱动，本身不会修改充电寄存器。只有在禁用充电后
得到 `REG03=0x09`、`CHRG_STAT=0`，并且重新启用后恢复 `REG03=0x19`，才可以继续安装
自动控制服务。

任务栏电池图标和 WMI 的 `Charging`、`ChargeRate` 可能长时间滞后，不能作为是否已经停充的
判据。应以 BQ25890 的 `REG03` 和 `CHRG_STAT` 为准。`ICHG_ADC` 仅在 ADC 转换已启用且
结果有效时才代表实时充电电流。

### 第三步：安装并激活自动控制

安装和激活分为两个阶段：

```powershell
.\Install-AutoLimiter.ps1
.\Activate-AutoLimiter.ps1
.\AutoLimiter-Status.ps1
```

安装阶段只运行自检和只读探测，不会解锁驱动或改变充电状态。激活后采用以下默认策略：

- 电量大于或等于 80% 时关闭充电；
- 电量小于或等于 50% 时恢复充电；
- 50%～80% 之间保持当前策略状态，形成滞回区间；
- 每 30 秒读取一次电量；
- 目标状态为停充时，每 5 秒检查一次 `REG03`；
- 固件重新启用充电时，立即再次关闭，并在日志中记录
  `Reasserted charging disabled after firmware reset`；
- 服务停止、系统关机或连续三次检查失败时，尝试恢复充电并验证结果；
- 控制依据是电池容量和 BQ25890 寄存器，不依赖任务栏或 WMI 的充电标志。

部分小米平板 2 固件会在满电附近报告超过 100% 的容量比例和
`EstimatedChargeRemaining`，真机曾观测到 106%。控制器会把 100%～150% 的输入钳制成
100%，不会重新缩放 50% 和 80% 的正常阈值。

电池查询及每次驱动请求都有 8 秒的控制器等待上限。如果终止子进程后，底层内核或 ACPI 请求
仍未结束，服务会记录这个未决请求、阻止后续驱动命令，并拒绝报告“安全停止”。软件无法保证在
这种底层卡死状态下自动恢复充电；请断开充电器并重启平板，再检查日志和驱动状态。

### 日常管理命令

查看服务、阈值、驱动状态和最近日志：

```powershell
.\AutoLimiter-Status.ps1
```

暂停自动控制；脚本会先停止服务、恢复充电，再锁定驱动写入：

```powershell
.\Pause-AutoLimiter.ps1
```

重新激活：

```powershell
.\Activate-AutoLimiter.ps1
```

只卸载自动控制层并保留驱动：

```powershell
.\Uninstall-AutoLimiter.ps1
```

卸载驱动、安装文件和测试证书：

```powershell
.\Uninstall.ps1
```

日志位于 `%ProgramData%\MiPadChargeLimiter\ChargeLimiter.log`。控制程序安装在受保护的
`%ProgramFiles%\MiPadChargeLimiter`，以 `LocalSystem` 服务运行，并依赖
`MiPadChargeCtl` 驱动。

## 从源码构建

构建电脑需要安装：

- Visual Studio 2022；
- C++ 桌面开发工具；
- Windows 10 或 Windows 11 SDK；
- Windows Driver Kit（WDK）。

在管理员 x64 PowerShell 中运行：

```powershell
.\tests\StaticChecks.ps1
.\Build-And-Sign.ps1
```

构建过程使用 `/W4`、将警告视为错误、PREfast、ApiValidator、控制器自检和 SHA-256
Authenticode 签名。脚本会在本机创建或复用自签名测试证书，并生成 `deploy` 目录。
私有签名密钥不会写入本仓库。

## 真机验证记录

- 手动停充和复充已经验证；
- BQ25890 芯片状态诊断已经验证；
- 服务停止时恢复充电的路径已经验证；
- 超过 100% 的电量输入钳制已经验证；
- v5.2 已完成五分钟固件复位守护测试；
- 测试期间观察到的固件复位间隔约为 12～51 秒；
- 测试结束时保持 `REG03=0x09`、`CHRG_STAT=0`；
- 重启自启、睡眠唤醒、不同固件版本和跨越 80%/50% 的长期自然循环，仍需要更多社区测试。

## 重要限制

- 测试签名模式会削弱 Windows 正常的内核信任边界；
- 驱动刻意绑定 `ACPI\PNP0C0A` 和已验证的 ACPI 方法；
- `GETC` 与 `SETC` 无法针对原厂充电驱动形成原子操作；
- 如果底层内核或 ACPI 请求永久不返回，软件无法保证恢复充电；
- Windows 任务栏和 WMI 充电状态可能过期，应以芯片寄存器为准；
- 本项目不能替代电池硬件保护、原厂充电管理或人工检查；
- 长期运行、睡眠唤醒、电池更换及其他 BIOS/固件版本尚未全面验证。

## 开发说明

本项目的初始驱动、控制服务、脚本、测试、安全分析和文档由 **OpenAI Codex** 在项目所有者
指导下协助开发。硬件资料、控制目标和全部真机验证由项目所有者提供和执行。详见
[AUTHORS.md](AUTHORS.md)。

## 许可证

本项目采用 [MIT 许可证](LICENSE)。
