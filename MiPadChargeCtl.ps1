param(
    [ValidateSet("status","diagnostics","enable","disable")]
    [string]$Action = "status",

    [switch]$ConfirmWrite
)

$ErrorActionPreference = "Stop"

$src = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class MiPadChargeNative
{
    private const uint GENERIC_READ  = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ  = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;

    // GET requires read access; SET requires read + write access.
    private const uint IOCTL_GET_STATE  = 0x00226004;
    private const uint IOCTL_SET_CHARGE = 0x0022E008;
    private const uint IOCTL_GET_DIAGNOSTICS = 0x0022600C;
    private const uint PROTOCOL_VERSION = 1;

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle hDevice,
        uint dwIoControlCode,
        byte[] lpInBuffer,
        int nInBufferSize,
        byte[] lpOutBuffer,
        int nOutBufferSize,
        out int lpBytesReturned,
        IntPtr lpOverlapped);

    private static SafeFileHandle Open()
    {
        SafeFileHandle h = CreateFile(
            @"\\.\MiPadChargeCtl",
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero,
            OPEN_EXISTING,
            0,
            IntPtr.Zero);

        if (h.IsInvalid)
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Cannot open \\\\.\\MiPadChargeCtl");

        return h;
    }

    private static string Parse(byte[] output, int returned)
    {
        if (returned < 20)
            throw new Exception("Driver returned fewer than 20 bytes.");

        uint version = BitConverter.ToUInt32(output, 0);
        uint reg03 = BitConverter.ToUInt32(output, 4);
        uint enabled = BitConverter.ToUInt32(output, 8);
        uint writesEnabled = BitConverter.ToUInt32(output, 12);
        uint changed = BitConverter.ToUInt32(output, 16);

        if (version != PROTOCOL_VERSION)
            throw new Exception("Driver protocol version mismatch.");

        return String.Format(
            "REG03=0x{0:X2}, CHG_CONFIG={1} ({2}), writes={3}, changed={4}",
            reg03 & 0xFF,
            enabled,
            enabled != 0 ? "charging enabled" : "charging disabled",
            writesEnabled != 0 ? "unlocked" : "locked",
            changed != 0 ? "yes" : "no");
    }

    public static string Status()
    {
        using (SafeFileHandle h = Open())
        {
            byte[] output = new byte[20];
            int returned;

            if (!DeviceIoControl(
                h, IOCTL_GET_STATE,
                null, 0,
                output, output.Length,
                out returned, IntPtr.Zero))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "IOCTL_MIPAD_GET_STATE failed");
            }

            return Parse(output, returned);
        }
    }

    public static string SetCharge(bool enable)
    {
        using (SafeFileHandle h = Open())
        {
            byte[] input = new byte[8];
            Buffer.BlockCopy(BitConverter.GetBytes(PROTOCOL_VERSION), 0, input, 0, 4);
            Buffer.BlockCopy(BitConverter.GetBytes(enable ? 1u : 0u), 0, input, 4, 4);
            byte[] output = new byte[20];
            int returned;

            if (!DeviceIoControl(
                h, IOCTL_SET_CHARGE,
                input, input.Length,
                output, output.Length,
                out returned, IntPtr.Zero))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "IOCTL_MIPAD_SET_CHARGE failed");
            }

            return Parse(output, returned);
        }
    }

    public static string Diagnostics()
    {
        using (SafeFileHandle h = Open())
        {
            byte[] output = new byte[28];
            int returned;

            if (!DeviceIoControl(
                h, IOCTL_GET_DIAGNOSTICS,
                null, 0,
                output, output.Length,
                out returned, IntPtr.Zero))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "IOCTL_MIPAD_GET_DIAGNOSTICS failed");
            }

            if (returned < 28)
                throw new Exception("Driver returned fewer than 28 diagnostic bytes.");

            uint version = BitConverter.ToUInt32(output, 0);
            if (version != PROTOCOL_VERSION)
                throw new Exception("Driver protocol version mismatch.");

            uint reg03 = BitConverter.ToUInt32(output, 4) & 0xFF;
            uint reg0B = BitConverter.ToUInt32(output, 8) & 0xFF;
            uint reg11 = BitConverter.ToUInt32(output, 12) & 0xFF;
            uint reg12 = BitConverter.ToUInt32(output, 16) & 0xFF;
            uint reg13 = BitConverter.ToUInt32(output, 20) & 0xFF;
            uint reg14 = BitConverter.ToUInt32(output, 24) & 0xFF;
            uint chargeStatus = (reg0B >> 3) & 0x3;
            string[] chargeNames = {
                "not charging", "pre-charge", "fast charging", "charge done"
            };
            uint chargeCurrentMa = (reg12 & 0x7F) * 50;
            uint vbusMv = 2600 + (reg11 & 0x7F) * 100;

            return String.Format(
                "REG03=0x{0:X2}; REG0B=0x{1:X2}, CHRG_STAT={2} ({3}), PG={4}; " +
                "REG12=0x{5:X2}, ICHG_ADC={6}mA; REG11=0x{7:X2}, VBUS_GD={8}, VBUS_ADC={9}mV; " +
                "REG13=0x{10:X2}; REG14=0x{11:X2}, PN={12}",
                reg03, reg0B, chargeStatus, chargeNames[chargeStatus],
                (reg0B >> 2) & 0x1, reg12, chargeCurrentMa,
                reg11, (reg11 >> 7) & 0x1, vbusMv,
                reg13, reg14, (reg14 >> 3) & 0x7);
        }
    }
}
'@

Add-Type -TypeDefinition $src -Language CSharp

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this command from an elevated PowerShell window."
}

if ($Action -in @("enable", "disable") -and -not $ConfirmWrite) {
    throw "Write refused. Re-run with -ConfirmWrite after the read-only status test succeeds."
}

switch ($Action) {
    "status"      { [MiPadChargeNative]::Status() }
    "diagnostics" { [MiPadChargeNative]::Diagnostics() }
    "enable"      { [MiPadChargeNative]::SetCharge($true) }
    "disable"     { [MiPadChargeNative]::SetCharge($false) }
}
