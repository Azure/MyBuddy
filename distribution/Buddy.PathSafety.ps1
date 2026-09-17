#requires -Version 7.2
function Assert-BuddySafePath {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if (-not $IsWindows) { throw "Reparse-point paths are not supported: $current" }
                if (-not ('MyBuddy.DistributionPathSafety' -as [type])) {
                    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace MyBuddy {
    public static class DistributionPathSafety {
        [StructLayout(LayoutKind.Sequential)]
        private struct AttributeTag { public uint Attributes; public uint Tag; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int info,
            out AttributeTag tag, uint size);
        public static bool IsCloudPlaceholder(string path) {
            // Open the reparse point itself, never its potential link target.
            using (var handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                AttributeTag tag;
                if (!GetFileInformationByHandleEx(handle, 9, out tag, 8))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                // Cloud Files tags (OneDrive) do not redirect a name to another path.
                // Reject every other tag, including symlinks and mount-point junctions.
                return (tag.Tag & 0xffff0fffU) == 0x9000001aU;
            }
        }
    }
}
'@
                }
                if (-not [MyBuddy.DistributionPathSafety]::IsCloudPlaceholder($current)) {
                    throw "Junctions, symbolic links and unknown reparse points are not supported: $current"
                }
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
