using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using InvertMouse.Utils;

// ReSharper disable IdentifierTypo
// ReSharper disable InconsistentNaming

namespace DriverInstaller.Utils
{
    internal class DriverInstaller
    {
        private const uint SC_MANAGER_CONNECT = 0x0001;
        private const uint SC_MANAGER_ALL_ACCESS = 0xF003F;
        private const uint SERVICE_ALL_ACCESS = 0xF01FF;
        private const uint SERVICE_QUERY_STATUS = 0x0004;
        private const uint SERVICE_STOP = 0x0020;
        private const uint DELETE = 0x10000;
        private const uint SERVICE_KERNEL_DRIVER = 0x00000001;
        private const uint SERVICE_DEMAND_START = 0x00000003;
        private const uint SERVICE_ERROR_NORMAL = 0x00000001;
        private const uint SERVICE_CONTROL_STOP = 0x00000001;
        private const uint ERROR_SERVICE_DOES_NOT_EXIST = 1060;
        private const uint ERROR_SERVICE_NOT_ACTIVE = 1062;
        private const uint ERROR_SERVICE_MARKED_FOR_DELETE = 1072;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;
        private const int ERROR_FILE_NOT_FOUND = 2;
        private const int ERROR_INVALID_DATA = 13;

        private const ushort IMAGE_FILE_MACHINE_AMD64 = 0x8664;
        private const ushort IMAGE_FILE_MACHINE_ARM64 = 0xAA64;

        private const string AdvApi32 = "advapi32.dll";
        private const string Kernel32 = "kernel32.dll";

        [DllImport(AdvApi32, SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr OpenSCManager(string machineName, string databaseName, uint dwAccess);

        [DllImport(AdvApi32, SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateService(
            IntPtr hSCManager, string lpServiceName, string lpDisplayName,
            uint dwDesiredAccess, uint dwServiceType, uint dwStartType, uint dwErrorControl,
            string lpBinaryPathName, string lpLoadOrderGroup, IntPtr lpdwTagId,
            string lpDependencies, string lpServiceStartName, string lpPassword);

        [DllImport(AdvApi32, SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr OpenService(IntPtr hSCManager, string lpServiceName, uint dwDesiredAccess);

        [DllImport(AdvApi32, SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool ChangeServiceConfig(
            IntPtr hService, uint nServiceType, uint nStartType, uint nErrorControl,
            string lpBinaryPathName, string lpLoadOrderGroup, IntPtr lpdwTagId,
            string lpDependencies, string lpServiceStartName, string lpPassword, string lpDisplayName);

        [DllImport(AdvApi32, SetLastError = true)]
        static extern bool DeleteService(IntPtr hService);

        [DllImport(AdvApi32, SetLastError = true)]
        static extern bool ControlService(IntPtr hService, uint dwControl, ref SERVICE_STATUS lpServiceStatus);

        [DllImport(AdvApi32, SetLastError = true)]
        static extern bool CloseServiceHandle(IntPtr hSCObject);

        [DllImport(Kernel32, SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);

        private const int MOVEFILE_REPLACE_EXISTING = 0x1;
        private const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;

        public const string DriverName = "InvertMouse";
        public const string DriverFileName = DriverName + ".sys";
        private readonly string DriverDestPath = Path.Combine(Environment.SystemDirectory, "drivers", DriverFileName);

        private const string SetupApi = "setupapi.dll";
        private const uint SPCRP_UPPERFILTERS = 0x00000011;

        private static readonly Guid GUID_DEVCLASS_MOUSE =
            new Guid(0x4d36e96f, 0xe325, 0x11ce, 0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18);

        [DllImport(SetupApi, SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool SetupDiGetClassRegistryPropertyW(
            [In] ref Guid ClassGuid,
            uint Property,
            out uint PropertyRegDataType,
            [Out] byte[] PropertyBuffer,
            uint PropertyBufferSize,
            out uint RequiredSize,
            IntPtr MachineName,
            IntPtr Reserved2);

        [DllImport(SetupApi, SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool SetupDiSetClassRegistryPropertyW(
            [In] ref Guid ClassGuid,
            uint Property,
            byte[] PropertyBuffer,
            uint PropertyBufferSize,
            IntPtr MachineName,
            IntPtr Reserved);

        private const string PsApi = "psapi.dll";

        [DllImport(PsApi, SetLastError = true)]
        static extern bool EnumDeviceDrivers(
            [Out] IntPtr[] lpImageBase,
            uint cb,
            [Out] out uint lpcbNeeded
        );

        [DllImport(PsApi, SetLastError = true, CharSet = CharSet.Unicode)]
        static extern uint GetDeviceDriverBaseName(
            IntPtr ImageBase,
            [Out] StringBuilder lpBaseName,
            uint nSize
        );

        [StructLayout(LayoutKind.Sequential)]
        private struct SERVICE_STATUS
        {
            public uint dwServiceType;
            public uint dwCurrentState;
            public uint dwControlsAccepted;
            public uint dwWin32ExitCode;
            public uint dwServiceSpecificExitCode;
            public uint dwCheckPoint;
            public uint dwWaitHint;
        }

        private void AddService(IntPtr scm)
        {
            var srv = CreateService(
                scm, DriverName, DriverName, SERVICE_ALL_ACCESS, SERVICE_KERNEL_DRIVER,
                SERVICE_DEMAND_START, SERVICE_ERROR_NORMAL, DriverDestPath,
                null, IntPtr.Zero, null, null, null
            );
            if (srv == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateService failed");

            CloseServiceHandle(srv);
        }

        private bool UpdateService(IntPtr srv)
        {
            return ChangeServiceConfig(
                srv, SERVICE_KERNEL_DRIVER, SERVICE_DEMAND_START, SERVICE_ERROR_NORMAL,
                DriverDestPath, null, IntPtr.Zero, null, null, null, DriverName
            );
        }

        public bool Install(string driverSourcePath)
        {
            var osVersion = Environment.OSVersion.Version;
            if (osVersion.Major < 10)
                throw new Exception("OS not supported, you need at least Windows 10");

            if (!File.Exists(driverSourcePath))
                throw new Exception("Can't find driver binary");

            ValidateDriverBinary(driverSourcePath);

            var previousFilters = GetFiltersValue();
            var hadFile = File.Exists(DriverDestPath);
            var hadService = HasService();
            var createdService = false;
            var copiedFile = false;
            var scm = IntPtr.Zero;

            try
            {
                if (hadFile)
                {
                    var tmpDestPath = DriverDestPath + ".tmp";
                    if (MoveFileEx(DriverDestPath, tmpDestPath, MOVEFILE_REPLACE_EXISTING))
                        MoveFileEx(tmpDestPath, null, MOVEFILE_DELAY_UNTIL_REBOOT);
                }

                File.Copy(driverSourcePath, DriverDestPath, true);
                copiedFile = true;

                scm = OpenSCManager(null, null, SC_MANAGER_ALL_ACCESS);
                if (scm == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManager failed");

                var srv = OpenService(scm, DriverName, SERVICE_ALL_ACCESS);
                if (srv != IntPtr.Zero)
                {
                    var success = UpdateService(srv);
                    CloseServiceHandle(srv);
                    if (!success)
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "ChangeServiceConfig failed");
                }
                else
                {
                    var error = Marshal.GetLastWin32Error();
                    if (error != ERROR_SERVICE_DOES_NOT_EXIST)
                        throw new Win32Exception(error, "OpenService failed");

                    AddService(scm);
                    createdService = true;
                }

                UpdateRegistry(true);
            }
            catch
            {
                TryRollback(previousFilters, hadFile, copiedFile, createdService, !hadService && createdService);
                throw;
            }
            finally
            {
                if (scm != IntPtr.Zero)
                {
                    CloseServiceHandle(scm);
                }
            }

            return !IsLoaded() || NeedsRebootForFileReplace();
        }

        public bool Uninstall()
        {
            var rebootRequired = UpdateRegistry(false);
            rebootRequired |= TryStopAndDeleteService();
            rebootRequired |= RemoveDriverFile();
            return rebootRequired || IsLoaded() || HasService();
        }

        public bool IsInstalled()
        {
            return File.Exists(DriverDestPath) && HasDriverFilter() && HasService();
        }

        public bool IsInstalledPartially()
        {
            return File.Exists(DriverDestPath) || HasDriverFilter() || HasService();
        }

        private void ValidateDriverBinary(string driverSourcePath)
        {
            var machine = ReadPeMachine(driverSourcePath);
            var architecture = WinAPI.GetArchitecture();
            ushort expected;
            switch (architecture)
            {
                case "x64":
                    expected = IMAGE_FILE_MACHINE_AMD64;
                    break;
                case "ARM64":
                    expected = IMAGE_FILE_MACHINE_ARM64;
                    break;
                default:
                    throw new Exception($"Unsupported architecture: {architecture ?? "unknown"}");
            }

            if (machine != expected)
            {
                throw new Exception(
                    $"Driver architecture 0x{machine:X} does not match this system ({architecture})");
            }

            var version = FileVersionInfo.GetVersionInfo(driverSourcePath);
            if (string.IsNullOrEmpty(version.FileVersion))
            {
                throw new Exception("Driver binary is missing a file version resource");
            }
        }

        private static ushort ReadPeMachine(string path)
        {
            using (var stream = File.OpenRead(path))
            using (var reader = new BinaryReader(stream))
            {
                if (reader.ReadUInt16() != 0x5A4D)
                    throw new Exception("Driver binary is not a valid PE image");

                stream.Seek(0x3C, SeekOrigin.Begin);
                var lfanew = reader.ReadInt32();
                stream.Seek(lfanew, SeekOrigin.Begin);
                if (reader.ReadUInt32() != 0x00004550)
                    throw new Exception("Driver binary is not a valid PE image");

                return reader.ReadUInt16();
            }
        }

        private void TryRollback(string previousFilters, bool hadFile, bool copiedFile, bool createdService,
            bool deleteCreatedService)
        {
            try
            {
                if (previousFilters != null)
                {
                    SetFiltersValue(previousFilters);
                }
            }
            catch
            {
                // Keep the original install exception.
            }

            if (deleteCreatedService && createdService)
            {
                try
                {
                    TryStopAndDeleteService();
                }
                catch
                {
                    // Keep the original install exception and continue file cleanup.
                }
            }

            if (copiedFile && !hadFile)
            {
                try
                {
                    File.Delete(DriverDestPath);
                }
                catch
                {
                    // File may be locked; reboot cleanup is handled by a later uninstall.
                }
            }
        }

        private bool TryStopAndDeleteService()
        {
            var scm = OpenSCManager(null, null, SC_MANAGER_ALL_ACCESS);
            if (scm == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManager failed");

            try
            {
                var srv = OpenService(scm, DriverName, SERVICE_ALL_ACCESS | SERVICE_STOP | DELETE | SERVICE_QUERY_STATUS);
                if (srv == IntPtr.Zero)
                {
                    var error = (uint)Marshal.GetLastWin32Error();
                    if (error == ERROR_SERVICE_DOES_NOT_EXIST)
                    {
                        return false;
                    }

                    throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenService failed");
                }

                try
                {
                    var status = new SERVICE_STATUS();
                    if (!ControlService(srv, SERVICE_CONTROL_STOP, ref status))
                    {
                        var error = (uint)Marshal.GetLastWin32Error();
                        if (error != ERROR_SERVICE_NOT_ACTIVE && error != ERROR_SERVICE_MARKED_FOR_DELETE)
                        {
                            // In-use kernel filters typically cannot stop until reboot.
                        }
                    }

                    if (!DeleteService(srv))
                    {
                        var error = (uint)Marshal.GetLastWin32Error();
                        if (error != ERROR_SERVICE_DOES_NOT_EXIST && error != ERROR_SERVICE_MARKED_FOR_DELETE)
                        {
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "DeleteService failed");
                        }
                    }

                    return IsLoaded();
                }
                finally
                {
                    CloseServiceHandle(srv);
                }
            }
            finally
            {
                CloseServiceHandle(scm);
            }
        }

        private bool RemoveDriverFile()
        {
            var tmp = DriverDestPath + ".tmp";
            if (!File.Exists(DriverDestPath))
            {
                return File.Exists(tmp);
            }

            var renamed = MoveFileEx(DriverDestPath, tmp, MOVEFILE_REPLACE_EXISTING);
            if (renamed)
            {
                MoveFileEx(tmp, null, MOVEFILE_DELAY_UNTIL_REBOOT);
                return true;
            }

            try
            {
                File.Delete(DriverDestPath);
            }
            catch
            {
                return true;
            }

            return File.Exists(DriverDestPath) || File.Exists(tmp);
        }

        private bool NeedsRebootForFileReplace()
        {
            return File.Exists(DriverDestPath + ".tmp");
        }

        private string GetFiltersValue()
        {
            var guid = GUID_DEVCLASS_MOUSE;

            SetupDiGetClassRegistryPropertyW(ref guid, SPCRP_UPPERFILTERS, out _, null, 0,
                out var size, IntPtr.Zero, IntPtr.Zero);
            var queryError = Marshal.GetLastWin32Error();

            if (queryError == ERROR_FILE_NOT_FOUND || queryError == ERROR_INVALID_DATA)
            {
                return "\0";
            }

            if (queryError != ERROR_INSUFFICIENT_BUFFER || size == 0)
            {
                throw new Win32Exception(queryError, "Read UpperFilters failed");
            }

            var buffer = new byte[Math.Max(size, 2u)];
            if (!SetupDiGetClassRegistryPropertyW(ref guid, SPCRP_UPPERFILTERS, out _, buffer, (uint)buffer.Length,
                    out _, IntPtr.Zero, IntPtr.Zero))
            {
                var error = Marshal.GetLastWin32Error();
                if (error == ERROR_FILE_NOT_FOUND || error == ERROR_INVALID_DATA)
                {
                    return "\0";
                }

                throw new Win32Exception(error, "Read UpperFilters failed");
            }

            return Encoding.Unicode.GetString(buffer);
        }

        private bool SetFiltersValue(string value)
        {
            var guid = GUID_DEVCLASS_MOUSE;
            var buffer = Encoding.Unicode.GetBytes(value);
            return SetupDiSetClassRegistryPropertyW(ref guid, SPCRP_UPPERFILTERS, buffer, (uint)buffer.Length, IntPtr.Zero, IntPtr.Zero);
        }

        private bool HasDriverFilter()
        {
            var value = GetFiltersValue();
            return value != null && GetDriverPosition(value) >= 0;
        }

        private bool HasService()
        {
            var scm = OpenSCManager(null, null, SC_MANAGER_CONNECT);
            if (scm == IntPtr.Zero)
            {
                return false;
            }

            try
            {
                var srv = OpenService(scm, DriverName, SERVICE_QUERY_STATUS);
                if (srv == IntPtr.Zero)
                {
                    return false;
                }

                CloseServiceHandle(srv);
                return true;
            }
            finally
            {
                CloseServiceHandle(scm);
            }
        }

        private int GetDriverPosition(string value)
        {
            const string driverNameWithZero = DriverName + "\0";

            if (value.StartsWith(driverNameWithZero, StringComparison.InvariantCultureIgnoreCase))
            {
                return 0;
            }

            var indexOf = value.IndexOf("\0" + driverNameWithZero, StringComparison.InvariantCultureIgnoreCase);
            if (indexOf >= 0)
            {
                return indexOf + 1;
            }

            return -1;
        }

        private bool UpdateRegistry(bool install)
        {
            var stringValue = GetFiltersValue();
            if (stringValue == null)
            {
                throw new Exception("Read registry failed");
            }

            const string driverNameWithZero = DriverName + "\0";

            string newStringValue;

            var indexOf = GetDriverPosition(stringValue);
            if (indexOf >= 0)
            {
                newStringValue = stringValue.Substring(0, indexOf) +
                                 stringValue.Substring(indexOf + driverNameWithZero.Length);
            }
            else
            {
                newStringValue = stringValue;
            }

            if (install)
            {
                newStringValue = driverNameWithZero + newStringValue;
            }

            if (stringValue == newStringValue)
            {
                return false;
            }

            if (!SetFiltersValue(newStringValue))
            {
                throw new Exception("Write registry failed");
            }
            return true;
        }

        public bool IsLoaded()
        {
            EnumDeviceDrivers(Array.Empty<IntPtr>(), 0, out var needed);
            if (needed == 0)
            {
                return false;
            }

            var count = (int)(needed / IntPtr.Size);
            var drivers = new IntPtr[count];

            if (EnumDeviceDrivers(drivers, (uint)(IntPtr.Size * drivers.Length), out var sizeNeeded) && sizeNeeded > 0)
            {
                var buffer = new StringBuilder(1024);
                for (var i = 0; i < count; i++)
                {
                    if (GetDeviceDriverBaseName(drivers[i], buffer, (uint)buffer.Capacity) != 0)
                    {
                        if (buffer.ToString().Equals(DriverFileName, StringComparison.OrdinalIgnoreCase))
                        {
                            return true;
                        }
                    }
                }
            }

            return false;
        }
    }
}
