using System;
using System.Collections.Generic;
using System.Globalization;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Threading;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace MiPadChargeLimiter
{
    internal enum ChargeCommand
    {
        None,
        Enable,
        Disable
    }

    internal static class ChargePolicy
    {
        internal static ChargeCommand Decide(
            double percent,
            bool chargeEnabled,
            int lowerThreshold,
            int upperThreshold,
            bool stopRequested)
        {
            if (stopRequested)
                return ChargeCommand.None;

            if (percent >= upperThreshold && chargeEnabled)
                return ChargeCommand.Disable;

            if (percent <= lowerThreshold && !chargeEnabled)
                return ChargeCommand.Enable;

            return ChargeCommand.None;
        }

        internal static bool ShouldFailOpen(int consecutiveFailures, int failureLimit)
        {
            return consecutiveFailures >= failureLimit;
        }

        internal static bool UpdateHoldDisabled(
            double percent,
            bool currentHoldDisabled,
            bool policyKnown,
            bool chargeEnabled,
            int lowerThreshold,
            int upperThreshold)
        {
            if (percent >= upperThreshold)
                return true;
            if (percent <= lowerThreshold)
                return false;
            return policyKnown ? currentHoldDisabled : !chargeEnabled;
        }

        internal static int NextDelaySeconds(
            bool holdDisabled,
            int enforcementSeconds,
            int pollSeconds)
        {
            return holdDisabled ? enforcementSeconds : pollSeconds;
        }

        internal static bool IsChargeEnabledReg03(uint reg03)
        {
            return (reg03 & 0x10U) != 0;
        }
    }

    internal sealed class LimiterConfiguration
    {
        internal int LowerThreshold;
        internal int UpperThreshold;
        internal int PollSeconds;
        internal int EnforcementSeconds;
        internal int FailureLimit;

        internal static LimiterConfiguration Load()
        {
            using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
                @"SOFTWARE\MiPadChargeLimiter", false))
            {
                if (key == null)
                    throw new InvalidOperationException("Controller registry configuration is missing.");

                LimiterConfiguration result = new LimiterConfiguration();
                result.LowerThreshold = ReadInt(key, "LowerThreshold", 50);
                result.UpperThreshold = ReadInt(key, "UpperThreshold", 80);
                result.PollSeconds = ReadInt(key, "PollSeconds", 30);
                result.EnforcementSeconds = ReadInt(key, "EnforcementSeconds", 5);
                result.FailureLimit = ReadInt(key, "FailureLimit", 3);
                result.Validate();
                return result;
            }
        }

        private static int ReadInt(RegistryKey key, string name, int defaultValue)
        {
            object value = key.GetValue(name, defaultValue);
            return Convert.ToInt32(value, CultureInfo.InvariantCulture);
        }

        internal void Validate()
        {
            if (LowerThreshold < 5 || UpperThreshold > 100 ||
                LowerThreshold >= UpperThreshold ||
                UpperThreshold - LowerThreshold < 5)
                throw new InvalidOperationException("Invalid charge thresholds.");

            if (PollSeconds < 10 || PollSeconds > 600)
                throw new InvalidOperationException("PollSeconds must be between 10 and 600.");

            if (EnforcementSeconds < 2 || EnforcementSeconds > 15 ||
                EnforcementSeconds >= PollSeconds)
                throw new InvalidOperationException(
                    "EnforcementSeconds must be between 2 and 15 and below PollSeconds.");

            if (FailureLimit < 1 || FailureLimit > 10)
                throw new InvalidOperationException("FailureLimit must be between 1 and 10.");
        }
    }

    internal sealed class BatteryReading
    {
        internal double Percent;
        internal uint RemainingCapacity;
        internal uint FullChargedCapacity;
        internal string Source;
    }

    internal static class BatteryReader
    {
        internal static double ClampPercent(double percent)
        {
            if (percent < 0.0 || percent > 150.0)
                throw new InvalidOperationException("Battery percentage is outside the accepted firmware range.");
            return Math.Min(percent, 100.0);
        }

        internal static BatteryReading ReadWithTimeout(int timeoutMilliseconds)
        {
            string executable = Process.GetCurrentProcess().MainModule.FileName;
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = executable;
            startInfo.Arguments = "--read-battery";
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;

            using (Process process = Process.Start(startInfo))
            {
                if (!process.WaitForExit(timeoutMilliseconds))
                {
                    process.Kill();
                    process.WaitForExit();
                    throw new System.TimeoutException("Battery WMI query exceeded its time limit.");
                }

                string output = process.StandardOutput.ReadToEnd().Trim();
                string error = process.StandardError.ReadToEnd().Trim();
                if (process.ExitCode != 0)
                    throw new InvalidOperationException("Battery query failed: " + error);

                string[] fields = output.Split('|');
                if (fields.Length != 4)
                    throw new InvalidOperationException("Battery query returned malformed data.");

                return new BatteryReading {
                    Percent = Double.Parse(fields[0], CultureInfo.InvariantCulture),
                    RemainingCapacity = UInt32.Parse(fields[1], CultureInfo.InvariantCulture),
                    FullChargedCapacity = UInt32.Parse(fields[2], CultureInfo.InvariantCulture),
                    Source = fields[3]
                };
            }
        }

        internal static BatteryReading Read()
        {
            Dictionary<uint, uint> fullByTag = new Dictionary<uint, uint>();

            using (ManagementObjectSearcher fullSearcher = new ManagementObjectSearcher(
                @"root\WMI", "SELECT Tag,FullChargedCapacity FROM BatteryFullChargedCapacity"))
            using (ManagementObjectCollection fullResults = fullSearcher.Get())
            {
                foreach (ManagementObject item in fullResults)
                {
                    using (item)
                    {
                        uint tag = Convert.ToUInt32(item["Tag"], CultureInfo.InvariantCulture);
                        uint full = Convert.ToUInt32(
                            item["FullChargedCapacity"], CultureInfo.InvariantCulture);
                        if (full > 0)
                            fullByTag[tag] = full;
                    }
                }
            }

            using (ManagementObjectSearcher statusSearcher = new ManagementObjectSearcher(
                @"root\WMI", "SELECT Active,Tag,RemainingCapacity FROM BatteryStatus"))
            using (ManagementObjectCollection statusResults = statusSearcher.Get())
            {
                foreach (ManagementObject item in statusResults)
                {
                    using (item)
                    {
                        bool active = item["Active"] == null ||
                            Convert.ToBoolean(item["Active"], CultureInfo.InvariantCulture);
                        uint tag = Convert.ToUInt32(item["Tag"], CultureInfo.InvariantCulture);
                        uint remaining = Convert.ToUInt32(
                            item["RemainingCapacity"], CultureInfo.InvariantCulture);
                        uint full;

                        if (active && fullByTag.TryGetValue(tag, out full) && full > 0)
                        {
                            double percent = remaining * 100.0 / full;
                            double clampedPercent = ClampPercent(percent);
                            return new BatteryReading {
                                Percent = clampedPercent,
                                RemainingCapacity = remaining,
                                FullChargedCapacity = full,
                                Source = percent > 100.0
                                    ? String.Format(
                                        CultureInfo.InvariantCulture,
                                        "root/WMI capacity (raw {0:F1}% clamped)",
                                        percent)
                                    : "root/WMI capacity"
                            };
                        }
                    }
                }
            }

            using (ManagementObjectSearcher fallbackSearcher = new ManagementObjectSearcher(
                @"root\CIMV2", "SELECT EstimatedChargeRemaining FROM Win32_Battery"))
            using (ManagementObjectCollection fallbackResults = fallbackSearcher.Get())
            {
                foreach (ManagementObject item in fallbackResults)
                {
                    using (item)
                    {
                        uint percent = Convert.ToUInt32(
                            item["EstimatedChargeRemaining"], CultureInfo.InvariantCulture);
                        if (percent <= 100)
                        {
                            return new BatteryReading {
                                Percent = percent,
                                RemainingCapacity = 0,
                                FullChargedCapacity = 0,
                                Source = "Win32_Battery fallback"
                            };
                        }
                    }
                }
            }

            throw new InvalidOperationException("No valid battery capacity reading is available.");
        }
    }

    internal sealed class DriverState
    {
        internal uint Reg03;
        internal bool ChargeEnabled;
        internal bool WritesEnabled;
        internal bool Changed;
    }

    internal sealed class DriverDiagnostics
    {
        internal uint Reg03;
        internal uint Reg0B;
        internal uint Reg11;
        internal uint Reg12;
        internal uint Reg13;
        internal uint Reg14;

        internal uint ChargeStatus { get { return (Reg0B >> 3) & 3; } }
        internal uint PartNumber { get { return (Reg14 >> 3) & 7; } }
    }

    internal static class DriverClient
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint FileShareRead = 1;
        private const uint FileShareWrite = 2;
        private const uint OpenExisting = 3;
        private const uint IoctlGetState = 0x00226004;
        private const uint IoctlSetCharge = 0x0022E008;
        private const uint IoctlGetDiagnostics = 0x0022600C;
        private const uint ProtocolVersion = 1;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            SafeFileHandle device,
            uint controlCode,
            byte[] input,
            int inputLength,
            byte[] output,
            int outputLength,
            out int bytesReturned,
            IntPtr overlapped);

        private static SafeFileHandle Open()
        {
            SafeFileHandle handle = CreateFile(
                @"\\.\MiPadChargeCtl",
                GenericRead | GenericWrite,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                0,
                IntPtr.Zero);

            if (handle.IsInvalid)
                throw new System.ComponentModel.Win32Exception(
                    Marshal.GetLastWin32Error(), "Cannot open MiPadChargeCtl driver.");

            return handle;
        }

        internal static DriverState GetState()
        {
            using (SafeFileHandle handle = Open())
            {
                byte[] output = Call(handle, IoctlGetState, null, 0, 20);
                RequireVersion(output);
                return new DriverState {
                    Reg03 = ReadUInt32(output, 4) & 0xFF,
                    ChargeEnabled = ReadUInt32(output, 8) != 0,
                    WritesEnabled = ReadUInt32(output, 12) != 0,
                    Changed = ReadUInt32(output, 16) != 0
                };
            }
        }

        internal static DriverState SetCharge(bool enable)
        {
            using (SafeFileHandle handle = Open())
            {
                byte[] input = new byte[8];
                Buffer.BlockCopy(BitConverter.GetBytes(ProtocolVersion), 0, input, 0, 4);
                Buffer.BlockCopy(BitConverter.GetBytes(enable ? 1U : 0U), 0, input, 4, 4);
                byte[] output = Call(handle, IoctlSetCharge, input, input.Length, 20);
                RequireVersion(output);
                return new DriverState {
                    Reg03 = ReadUInt32(output, 4) & 0xFF,
                    ChargeEnabled = ReadUInt32(output, 8) != 0,
                    WritesEnabled = ReadUInt32(output, 12) != 0,
                    Changed = ReadUInt32(output, 16) != 0
                };
            }
        }

        internal static DriverDiagnostics GetDiagnostics()
        {
            using (SafeFileHandle handle = Open())
            {
                byte[] output = Call(handle, IoctlGetDiagnostics, null, 0, 28);
                RequireVersion(output);
                return new DriverDiagnostics {
                    Reg03 = ReadUInt32(output, 4) & 0xFF,
                    Reg0B = ReadUInt32(output, 8) & 0xFF,
                    Reg11 = ReadUInt32(output, 12) & 0xFF,
                    Reg12 = ReadUInt32(output, 16) & 0xFF,
                    Reg13 = ReadUInt32(output, 20) & 0xFF,
                    Reg14 = ReadUInt32(output, 24) & 0xFF
                };
            }
        }

        private static byte[] Call(
            SafeFileHandle handle,
            uint code,
            byte[] input,
            int inputLength,
            int outputLength)
        {
            byte[] output = new byte[outputLength];
            int returned;
            if (!DeviceIoControl(
                handle, code, input, inputLength, output, output.Length,
                out returned, IntPtr.Zero))
                throw new System.ComponentModel.Win32Exception(
                    Marshal.GetLastWin32Error(), "Driver request failed.");

            if (returned != outputLength)
                throw new InvalidOperationException("Driver returned an unexpected response size.");

            return output;
        }

        private static uint ReadUInt32(byte[] data, int offset)
        {
            return BitConverter.ToUInt32(data, offset);
        }

        private static void RequireVersion(byte[] data)
        {
            if (ReadUInt32(data, 0) != ProtocolVersion)
                throw new InvalidOperationException("Driver protocol version mismatch.");
        }
    }

    internal static class DriverProxy
    {
        private const int TimeoutMilliseconds = 8000;
        private static readonly object Sync = new object();
        private static Process unresolvedProcess;
        private static string unresolvedOperation;

        private static string[] Run(string operation)
        {
            lock (Sync)
            {
                if (unresolvedProcess != null)
                {
                    if (!unresolvedProcess.HasExited)
                        throw new InvalidOperationException(
                            "A prior timed-out driver request is still unresolved (" +
                            unresolvedOperation + "); refusing a concurrent request.");
                    unresolvedProcess.Dispose();
                    unresolvedProcess = null;
                    unresolvedOperation = null;
                }

                string executable = Process.GetCurrentProcess().MainModule.FileName;
                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = executable;
                startInfo.Arguments = "--driver-op " + operation;
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = true;
                startInfo.RedirectStandardOutput = true;
                startInfo.RedirectStandardError = true;

                Process process = null;
                bool retained = false;
                try
                {
                    process = Process.Start(startInfo);
                    if (!process.WaitForExit(TimeoutMilliseconds))
                    {
                        try { process.Kill(); }
                        catch (Exception) { }

                        if (!process.WaitForExit(2000))
                        {
                            unresolvedProcess = process;
                            unresolvedOperation = operation;
                            retained = true;
                            throw new System.TimeoutException(
                                "Driver request timed out and remains unresolved; " +
                                "future requests are blocked: " + operation);
                        }

                        throw new System.TimeoutException(
                            "Driver request exceeded its 8 second time limit and was terminated: " +
                            operation);
                    }

                    string output = process.StandardOutput.ReadToEnd().Trim();
                    string error = process.StandardError.ReadToEnd().Trim();
                    if (process.ExitCode != 0)
                        throw new InvalidOperationException("Driver request failed: " + error);

                    return output.Split('|');
                }
                finally
                {
                    if (process != null && !retained)
                        process.Dispose();
                }
            }
        }

        internal static DriverState GetState()
        {
            return ParseState(Run("state"));
        }

        internal static DriverState SetCharge(bool enable)
        {
            return ParseState(Run(enable ? "enable" : "disable"));
        }

        internal static DriverDiagnostics GetDiagnostics()
        {
            string[] fields = Run("diagnostics");
            if (fields.Length != 7 || fields[0] != "diagnostics")
                throw new InvalidOperationException("Driver diagnostics returned malformed data.");
            return new DriverDiagnostics {
                Reg03 = ParseUInt(fields[1]),
                Reg0B = ParseUInt(fields[2]),
                Reg11 = ParseUInt(fields[3]),
                Reg12 = ParseUInt(fields[4]),
                Reg13 = ParseUInt(fields[5]),
                Reg14 = ParseUInt(fields[6])
            };
        }

        private static DriverState ParseState(string[] fields)
        {
            if (fields.Length != 5 || fields[0] != "state")
                throw new InvalidOperationException("Driver state returned malformed data.");
            if ((fields[2] != "0" && fields[2] != "1") ||
                (fields[3] != "0" && fields[3] != "1") ||
                (fields[4] != "0" && fields[4] != "1"))
                throw new InvalidOperationException("Driver state returned invalid Boolean data.");
            return new DriverState {
                Reg03 = ParseUInt(fields[1]),
                ChargeEnabled = fields[2] == "1",
                WritesEnabled = fields[3] == "1",
                Changed = fields[4] == "1"
            };
        }

        private static uint ParseUInt(string value)
        {
            return UInt32.Parse(value, CultureInfo.InvariantCulture);
        }
    }

    internal static class LimiterLog
    {
        private static readonly object Sync = new object();
        private static readonly string DirectoryPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "MiPadChargeLimiter");
        private static readonly string FilePath = Path.Combine(DirectoryPath, "ChargeLimiter.log");

        internal static void Write(string message)
        {
            try
            {
                lock (Sync)
                {
                    Directory.CreateDirectory(DirectoryPath);
                    if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 1024 * 1024)
                    {
                        string previous = FilePath + ".previous";
                        if (File.Exists(previous))
                            File.Delete(previous);
                        File.Move(FilePath, previous);
                    }

                    File.AppendAllText(
                        FilePath,
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) +
                        "  " + message + Environment.NewLine);
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    internal sealed class ChargeLimiterController
    {
        private readonly ManualResetEvent stop = new ManualResetEvent(false);
        private int consecutiveFailures;
        private DateTime nextHeartbeat = DateTime.MinValue;
        private DateTime nextBatterySample = DateTime.MinValue;
        private string previousSummary;
        private BatteryReading lastBattery;
        private bool policyKnown;
        private bool holdDisabled;

        internal void RequestStop()
        {
            stop.Set();
        }

        internal void Run()
        {
            LimiterLog.Write("Controller started.");
            try
            {
                while (!stop.WaitOne(0))
                {
                    LimiterConfiguration configuration;
                    try
                    {
                        configuration = LimiterConfiguration.Load();
                    }
                    catch (Exception ex)
                    {
                        consecutiveFailures++;
                        LimiterLog.Write("Configuration failure " + consecutiveFailures + ": " + ex.Message);
                        if (consecutiveFailures >= 3 &&
                            EnsureChargingEnabled("configuration failure limit reached"))
                            ResetPolicyAfterFailOpen();
                        if (stop.WaitOne(30000))
                            break;
                        continue;
                    }
                    Evaluate(configuration);
                    int delaySeconds = ChargePolicy.NextDelaySeconds(
                        holdDisabled,
                        configuration.EnforcementSeconds,
                        configuration.PollSeconds);
                    if (stop.WaitOne(delaySeconds * 1000))
                        break;
                }
            }
            finally
            {
                if (EnsureChargingEnabled("controller exit"))
                    LimiterLog.Write("Controller stopped after charging recovery was verified.");
                else
                    LimiterLog.Write("Controller exit recovery failed; charging state is not verified safe.");
            }
        }

        private void Evaluate(LimiterConfiguration configuration)
        {
            try
            {
                DriverState state = DriverProxy.GetState();
                if (!state.WritesEnabled)
                    throw new InvalidOperationException("Driver write policy is locked.");

                if (policyKnown && holdDisabled && state.ChargeEnabled && !stop.WaitOne(0))
                {
                    state = DriverProxy.SetCharge(false);
                    Thread.Sleep(1100);
                    DriverDiagnostics enforcementDiagnostics = DriverProxy.GetDiagnostics();
                    ApplyVerifiedReg03(state, enforcementDiagnostics);
                    if (state.ChargeEnabled || enforcementDiagnostics.ChargeStatus != 0)
                        throw new InvalidOperationException("Charge reassertion verification failed.");
                    LimiterLog.Write(FormatState(
                        "Reasserted charging disabled after firmware reset",
                        lastBattery,
                        state,
                        enforcementDiagnostics));
                }

                if (lastBattery == null || DateTime.UtcNow >= nextBatterySample)
                {
                    BatteryReading battery = BatteryReader.ReadWithTimeout(8000);
                    DriverDiagnostics diagnostics = DriverProxy.GetDiagnostics();
                    if (diagnostics.PartNumber != 3)
                        throw new InvalidOperationException("Unexpected charger part number.");

                    bool wasPolicyKnown = policyKnown;
                    bool previousHoldDisabled = holdDisabled;
                    holdDisabled = ChargePolicy.UpdateHoldDisabled(
                        battery.Percent,
                        holdDisabled,
                        policyKnown,
                        state.ChargeEnabled,
                        configuration.LowerThreshold,
                        configuration.UpperThreshold);
                    policyKnown = true;
                    lastBattery = battery;
                    nextBatterySample = DateTime.UtcNow.AddSeconds(configuration.PollSeconds);

                    if (stop.WaitOne(0))
                        return;

                    if (holdDisabled && state.ChargeEnabled)
                    {
                        state = DriverProxy.SetCharge(false);
                        Thread.Sleep(1100);
                        diagnostics = DriverProxy.GetDiagnostics();
                        ApplyVerifiedReg03(state, diagnostics);
                        if (state.ChargeEnabled || diagnostics.ChargeStatus != 0)
                            throw new InvalidOperationException("Charge-disable verification failed.");
                        string reason = !wasPolicyKnown || !previousHoldDisabled
                            ? "Disabled charging at upper threshold"
                            : "Reasserted charging disabled after battery sample";
                        LimiterLog.Write(FormatState(reason, battery, state, diagnostics));
                    }
                    else if (!holdDisabled && !state.ChargeEnabled)
                    {
                        state = DriverProxy.SetCharge(true);
                        Thread.Sleep(1100);
                        diagnostics = DriverProxy.GetDiagnostics();
                        ApplyVerifiedReg03(state, diagnostics);
                        if (!state.ChargeEnabled)
                            throw new InvalidOperationException("Charge-enable verification failed.");
                        LimiterLog.Write(FormatState(
                            "Enabled charging at lower threshold", battery, state, diagnostics));
                    }
                    else
                    {
                        string summary = FormatState("Holding state", battery, state, diagnostics);
                        if (!String.Equals(summary, previousSummary, StringComparison.Ordinal) ||
                            DateTime.UtcNow >= nextHeartbeat)
                        {
                            LimiterLog.Write(summary);
                            previousSummary = summary;
                            nextHeartbeat = DateTime.UtcNow.AddMinutes(10);
                        }
                    }
                }

                consecutiveFailures = 0;
            }
            catch (Exception ex)
            {
                consecutiveFailures++;
                LimiterLog.Write("Evaluation failure " + consecutiveFailures + ": " + ex.Message);
                if (ChargePolicy.ShouldFailOpen(consecutiveFailures, configuration.FailureLimit))
                {
                    if (EnsureChargingEnabled("failure limit reached"))
                        ResetPolicyAfterFailOpen();
                }
            }
        }

        private void ResetPolicyAfterFailOpen()
        {
            holdDisabled = false;
            policyKnown = false;
            lastBattery = null;
            nextBatterySample = DateTime.MinValue;
        }

        private static void ApplyVerifiedReg03(
            DriverState state,
            DriverDiagnostics diagnostics)
        {
            state.Reg03 = diagnostics.Reg03;
            state.ChargeEnabled = ChargePolicy.IsChargeEnabledReg03(diagnostics.Reg03);
        }

        internal static bool EnsureChargingEnabled(string reason)
        {
            try
            {
                DriverState state = DriverProxy.GetState();
                if (!state.ChargeEnabled)
                {
                    if (!state.WritesEnabled)
                        throw new InvalidOperationException("Driver is locked while charging is disabled.");
                    state = DriverProxy.SetCharge(true);
                    Thread.Sleep(1100);
                }
                DriverDiagnostics diagnostics = DriverProxy.GetDiagnostics();
                ApplyVerifiedReg03(state, diagnostics);
                if (!state.ChargeEnabled)
                    throw new InvalidOperationException("Driver did not verify charging enabled.");
                LimiterLog.Write("Fail-open check (" + reason + "): charging enabled=" + state.ChargeEnabled + ".");
                return true;
            }
            catch (Exception ex)
            {
                LimiterLog.Write("Fail-open check failed (" + reason + "): " + ex.Message);
                return false;
            }
        }

        private static string FormatState(
            string prefix,
            BatteryReading battery,
            DriverState state,
            DriverDiagnostics diagnostics)
        {
            return String.Format(
                CultureInfo.InvariantCulture,
                "{0}: battery={1:F1}% ({2}/{3}, {4}), REG03=0x{5:X2}, enabled={6}, " +
                "CHRG_STAT={7}, VBUS_GD={8}.",
                prefix,
                battery.Percent,
                battery.RemainingCapacity,
                battery.FullChargedCapacity,
                battery.Source,
                state.Reg03,
                state.ChargeEnabled,
                diagnostics.ChargeStatus,
                (diagnostics.Reg11 >> 7) & 1);
        }
    }

    public sealed class ChargeLimiterWindowsService : ServiceBase
    {
        private ChargeLimiterController controller;
        private Thread worker;

        public ChargeLimiterWindowsService()
        {
            ServiceName = "MiPadChargeLimiter";
            CanStop = true;
            CanShutdown = true;
            AutoLog = false;
        }

        protected override void OnStart(string[] args)
        {
            controller = new ChargeLimiterController();
            worker = new Thread(controller.Run);
            worker.IsBackground = true;
            worker.Name = "MiPadChargeLimiter worker";
            worker.Start();
        }

        protected override void OnStop()
        {
            StopWorker("service stop");
        }

        protected override void OnShutdown()
        {
            StopWorker("system shutdown");
            base.OnShutdown();
        }

        private void StopWorker(string reason)
        {
            if (controller != null)
                controller.RequestStop();
            if (worker != null && !worker.Join(20000))
            {
                LimiterLog.Write("Service stop refused because the controller worker did not exit.");
                throw new System.TimeoutException(
                    "Controller worker did not stop within 20 seconds; charging state was not changed concurrently.");
            }
            if (!ChargeLimiterController.EnsureChargingEnabled(reason))
                throw new InvalidOperationException(
                    "Service cannot stop cleanly because charging recovery could not be verified.");
        }
    }

    internal static class SelfTests
    {
        internal static int Run()
        {
            Assert(ChargePolicy.Decide(80, true, 50, 80, false) == ChargeCommand.Disable, "80 disables");
            Assert(ChargePolicy.Decide(100, true, 50, 80, false) == ChargeCommand.Disable, "100 disables");
            Assert(ChargePolicy.Decide(79.9, true, 50, 80, false) == ChargeCommand.None, "below 80 holds");
            Assert(ChargePolicy.Decide(50, false, 50, 80, false) == ChargeCommand.Enable, "50 enables");
            Assert(ChargePolicy.Decide(49, false, 50, 80, false) == ChargeCommand.Enable, "below 50 enables");
            Assert(ChargePolicy.Decide(50.1, false, 50, 80, false) == ChargeCommand.None, "above 50 holds");
            Assert(ChargePolicy.Decide(65, true, 50, 80, false) == ChargeCommand.None, "middle enabled holds");
            Assert(ChargePolicy.Decide(65, false, 50, 80, false) == ChargeCommand.None, "middle disabled holds");
            Assert(ChargePolicy.Decide(100, true, 50, 80, true) == ChargeCommand.None, "stop suppresses late disable");
            Assert(!ChargePolicy.ShouldFailOpen(2, 3), "two failures hold");
            Assert(ChargePolicy.ShouldFailOpen(3, 3), "three failures fail open");
            Assert(BatteryReader.ClampPercent(106.2) == 100.0, "firmware over-100 percentage clamps");
            Assert(BatteryReader.ClampPercent(80.0) == 80.0, "normal percentage remains unchanged");
            Assert(ChargePolicy.UpdateHoldDisabled(80, false, true, true, 50, 80), "upper threshold latches enforcement");
            Assert(ChargePolicy.UpdateHoldDisabled(65, true, true, true, 50, 80), "middle band retains enforcement");
            Assert(!ChargePolicy.UpdateHoldDisabled(50, true, true, false, 50, 80), "lower threshold releases enforcement");
            Assert(ChargePolicy.NextDelaySeconds(true, 5, 30) == 5, "disabled state uses fast enforcement interval");
            Assert(ChargePolicy.NextDelaySeconds(false, 5, 30) == 30, "enabled state uses battery poll interval");
            Assert(!ChargePolicy.UpdateHoldDisabled(65, false, false, true, 50, 80), "fail-open reset waits for a fresh sample");
            Assert(ChargePolicy.IsChargeEnabledReg03(0x19), "latest REG03 detects firmware re-enable");
            Assert(!ChargePolicy.IsChargeEnabledReg03(0x09), "latest REG03 verifies disabled state");
            Console.WriteLine("ChargeLimiter self-tests passed: 21 policy, scheduling, input, and recovery cases.");
            return 0;
        }

        private static void Assert(bool condition, string name)
        {
            if (!condition)
                throw new InvalidOperationException("Self-test failed: " + name);
        }
    }

    internal static class Program
    {
        private static int Main(string[] args)
        {
            if (args.Length == 1 && args[0] == "--self-test")
                return SelfTests.Run();

            if (args.Length == 1 && args[0] == "--probe")
            {
                BatteryReading battery = BatteryReader.ReadWithTimeout(8000);
                DriverState state = DriverProxy.GetState();
                DriverDiagnostics diagnostics = DriverProxy.GetDiagnostics();
                Console.WriteLine(
                    "Battery={0:F1}% Remaining={1} Full={2} Source={3}",
                    battery.Percent,
                    battery.RemainingCapacity,
                    battery.FullChargedCapacity,
                    battery.Source);
                Console.WriteLine(
                    "REG03=0x{0:X2} Enabled={1} Writes={2} REG0B=0x{3:X2} CHRG_STAT={4} PN={5}",
                    state.Reg03,
                    state.ChargeEnabled,
                    state.WritesEnabled,
                    diagnostics.Reg0B,
                    diagnostics.ChargeStatus,
                    diagnostics.PartNumber);
                return 0;
            }

            if (args.Length == 2 && args[0] == "--driver-op")
            {
                try
                {
                    if (args[1] == "state" || args[1] == "enable" || args[1] == "disable")
                    {
                        DriverState state = args[1] == "state"
                            ? DriverClient.GetState()
                            : DriverClient.SetCharge(args[1] == "enable");
                        Console.WriteLine(
                            String.Format(
                                CultureInfo.InvariantCulture,
                                "state|{0}|{1}|{2}|{3}",
                                state.Reg03,
                                state.ChargeEnabled ? 1 : 0,
                                state.WritesEnabled ? 1 : 0,
                                state.Changed ? 1 : 0));
                        return 0;
                    }

                    if (args[1] == "diagnostics")
                    {
                        DriverDiagnostics diagnostics = DriverClient.GetDiagnostics();
                        Console.WriteLine(
                            String.Format(
                                CultureInfo.InvariantCulture,
                                "diagnostics|{0}|{1}|{2}|{3}|{4}|{5}",
                                diagnostics.Reg03,
                                diagnostics.Reg0B,
                                diagnostics.Reg11,
                                diagnostics.Reg12,
                                diagnostics.Reg13,
                                diagnostics.Reg14));
                        return 0;
                    }

                    throw new InvalidOperationException("Unknown internal driver operation.");
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine(ex.Message);
                    return 1;
                }
            }

            if (args.Length == 1 && args[0] == "--read-battery")
            {
                try
                {
                    BatteryReading battery = BatteryReader.Read();
                    Console.WriteLine(
                        String.Format(
                            CultureInfo.InvariantCulture,
                            "{0:R}|{1}|{2}|{3}",
                            battery.Percent,
                            battery.RemainingCapacity,
                            battery.FullChargedCapacity,
                            battery.Source));
                    return 0;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine(ex.Message);
                    return 1;
                }
            }

            if (Environment.UserInteractive)
            {
                Console.Error.WriteLine("Use --probe or --self-test, or run this executable as a Windows service.");
                return 2;
            }

            ServiceBase.Run(new ChargeLimiterWindowsService());
            return 0;
        }
    }
}
