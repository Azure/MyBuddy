using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace MyBuddy
{
    public static class TerminalNative
    {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetPropW(IntPtr window, string name, IntPtr value);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetPropW(IntPtr window, string name);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr RemovePropW(IntPtr window, string name);
        [DllImport("user32.dll")] private static extern bool FlashWindowEx(ref FlashInfo info);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
        private delegate bool EnumWindow(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindow callback, IntPtr parameter);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(string application, StringBuilder commandLine,
            IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags,
            IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int infoClass,
            ref JobExtendedLimits limits, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();

        [StructLayout(LayoutKind.Sequential)]
        private struct JobBasicLimits
        {
            public long processTimeLimit, jobTimeLimit;
            public uint flags;
            public UIntPtr minimumWorkingSet, maximumWorkingSet;
            public uint activeProcessLimit;
            public UIntPtr affinity;
            public uint priorityClass, schedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct JobIoCounters
        {
            public ulong readOperations, writeOperations, otherOperations;
            public ulong readBytes, writeBytes, otherBytes;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct JobExtendedLimits
        {
            public JobBasicLimits basic;
            public JobIoCounters io;
            public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
        }
        private static readonly object lifetimeLock = new object();
        private static IntPtr lifetimeJob = IntPtr.Zero;

        public static void BindCurrentTerminalHostLifetime()
        {
            lock (lifetimeLock)
            {
                if (lifetimeJob != IntPtr.Zero) return;
                var job = CreateJobObjectW(IntPtr.Zero, null);
                if (job == IntPtr.Zero)
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Cannot create the terminal process lifetime job.");
                var limits = new JobExtendedLimits();
                limits.basic.flags = 0x00002000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JobExtendedLimits>()) ||
                    !AssignProcessToJobObject(job, GetCurrentProcess()))
                {
                    var error = Marshal.GetLastWin32Error();
                    CloseHandle(job);
                    throw new System.ComponentModel.Win32Exception(error, "Cannot bind the terminal host lifetime; no Copilot runtime was started.");
                }
                // Only the dedicated terminal host calls this, before spawning Copilot.
                // Keep this sole, non-inheritable handle until OS process teardown, even
                // when closing a terminal bypasses PowerShell finally blocks. Descendants
                // that inherit this job stop with the host. Windows app activation aliases
                // can escape this job; external-session checks must still block duplicates.
                lifetimeJob = job;
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public uint size;
            public string reserved, desktop, title;
            public uint x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags;
            public ushort showWindow, reservedSize;
            public IntPtr reservedPointer, input, output, error;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInfo
        {
            public IntPtr process, thread;
            public uint processId, threadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FlashInfo
        {
            public uint size;
            public IntPtr window;
            public uint flags;
            public uint count;
            public uint timeout;
        }

        public static uint WindowProcess(IntPtr window)
        {
            uint pid;
            GetWindowThreadProcessId(window, out pid);
            return pid;
        }

        public static string Title(IntPtr window)
        {
            var text = new StringBuilder(1024);
            GetWindowText(window, text, text.Capacity);
            return text.ToString();
        }

        public static string WindowClass(IntPtr window)
        {
            var text = new StringBuilder(256);
            GetClassName(window, text, text.Capacity);
            return text.ToString();
        }

        public static bool Focus(IntPtr window)
        {
            if (IsIconic(window)) ShowWindowAsync(window, 9);
            if (SetForegroundWindow(window) && GetForegroundWindow() == window) return true;
            var info = new FlashInfo {
                size = (uint)Marshal.SizeOf<FlashInfo>(), window = window,
                flags = 3, count = 3, timeout = 0
            };
            FlashWindowEx(ref info);
            return false;
        }

        public static void MarkWindow(IntPtr window, string token)
        {
            // Window properties die with the HWND, even when Windows reuses the handle in the same process.
            if (!SetPropW(window, "MyBuddy." + token, new IntPtr(1)))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }

        public static bool HasWindowMark(IntPtr window, string token)
        {
            return !String.IsNullOrEmpty(token) && GetPropW(window, "MyBuddy." + token) == new IntPtr(1);
        }

        public static void UnmarkWindow(IntPtr window, string token)
        {
            RemovePropW(window, "MyBuddy." + token);
        }

        public static IntPtr[] TerminalWindows()
        {
            var windows = new List<IntPtr>();
            EnumWindows((window, unused) => {
                if (IsWindowVisible(window) && WindowClass(window) == "CASCADIA_HOSTING_WINDOW_CLASS")
                    windows.Add(window);
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }

        public static IntPtr FindWindow(string marker)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindows((window, unused) => {
                if (IsWindowVisible(window) && Title(window) == marker) {
                    found = window;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        public static uint StartConsole(string application, string commandLine, string directory, string title)
        {
            var startup = new StartupInfo { size = (uint)Marshal.SizeOf<StartupInfo>(), title = title };
            ProcessInfo process;
            // A real interactive console, not a child attached to the portal's hidden pipes.
            if (!CreateProcessW(application, new StringBuilder(commandLine), IntPtr.Zero,
                IntPtr.Zero, false, 0x00000010, IntPtr.Zero, directory, ref startup, out process))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try { return process.processId; }
            finally { CloseHandle(process.thread); CloseHandle(process.process); }
        }

        public static string[] Arguments(string commandLine)
        {
            int count;
            var memory = CommandLineToArgvW(commandLine, out count);
            if (memory == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            try
            {
                var values = new List<string>();
                for (int i = 0; i < count; i++)
                    values.Add(Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size)));
                return values.ToArray();
            }
            finally { LocalFree(memory); }
        }
    }
}
