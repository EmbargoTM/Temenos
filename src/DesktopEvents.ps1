# Wait for Windows to update the virtual-desktop registry state.
if (-not ("TemenosDesktopChangeWatcher" -as [type])) {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Threading;
using Microsoft.Win32;
using System.Diagnostics;
using System.Runtime.InteropServices;

public sealed class TemenosDesktopChangeWatcher : IDisposable
{
    private const uint NotifyLastSet = 0x00000004;
    private readonly List<RegistryKey> keys = new List<RegistryKey>();
    private readonly List<EventWaitHandle> changedEvents = new List<EventWaitHandle>();
    private readonly List<int> sourceKinds = new List<int>();
    private bool disposed;

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int RegNotifyChangeKeyValue(
        IntPtr key,
        [MarshalAs(UnmanagedType.Bool)] bool watchSubtree,
        uint notifyFilter,
        IntPtr eventHandle,
        [MarshalAs(UnmanagedType.Bool)] bool asynchronous
    );

    public TemenosDesktopChangeWatcher()
    {
        string[] paths = new string[] {
            @"Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops",
            @"Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\" +
                Process.GetCurrentProcess().SessionId + @"\VirtualDesktops"
        };

        using (RegistryKey root = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Default))
        {
            for (int i = 0; i < paths.Length; i++)
            {
                RegistryKey key = root.OpenSubKey(paths[i], false);
                if (key != null)
                {
                    keys.Add(key);
                    changedEvents.Add(new EventWaitHandle(false, EventResetMode.ManualReset));
                    sourceKinds.Add(i);
                }
            }

            if (keys.Count == 0)
                throw new InvalidOperationException("Windows virtual desktop registry keys are unavailable.");

            for (int i = 0; i < keys.Count; i++) Arm(i);
        }
    }

    public int WaitForChange(int timeoutMilliseconds)
    {
        if (disposed) throw new ObjectDisposedException("TemenosDesktopChangeWatcher");
        int signaledIndex = WaitHandle.WaitAny(changedEvents.ToArray(), timeoutMilliseconds);
        if (signaledIndex == WaitHandle.WaitTimeout) return -1;

        // Preserve other already-signaled keys; the caller reads this source
        // first, then consumes any additional pending signal on the next wait.
        int source = sourceKinds[signaledIndex];
        Arm(signaledIndex);
        return source;
    }

    private void Arm(int index)
    {
        changedEvents[index].Reset();
        int result = RegNotifyChangeKeyValue(
            keys[index].Handle.DangerousGetHandle(),
            false,
            NotifyLastSet,
            changedEvents[index].SafeWaitHandle.DangerousGetHandle(),
            true
        );
        if (result != 0) throw new Win32Exception(result, "Could not watch virtual desktop changes.");
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (RegistryKey key in keys) key.Dispose();
        foreach (EventWaitHandle changeEvent in changedEvents) changeEvent.Dispose();
    }
}
"@
}
