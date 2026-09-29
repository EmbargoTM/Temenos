# ============================================================
# Temenos - DesktopActions.ps1
# Ações sobre Áreas de Trabalho Virtuais do Windows 10.
# ============================================================

if (-not ("TemenosKeyboardActions" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class TemenosKeyboardActions
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern void keybd_event(
        byte bVk,
        byte bScan,
        uint dwFlags,
        UIntPtr dwExtraInfo
    );
}
"@
}

function Invoke-TemenosKeyChord {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Keys
    )

    $KEYUP = 0x0002

    try {
        foreach ($key in $Keys) {
            [TemenosKeyboardActions]::keybd_event(
                $key, 0, 0, [UIntPtr]::Zero
            )
            Start-Sleep -Milliseconds 20
        }

        for ($i = $Keys.Count - 1; $i -ge 0; $i--) {
            [TemenosKeyboardActions]::keybd_event(
                $Keys[$i], 0, $KEYUP, [UIntPtr]::Zero
            )
            Start-Sleep -Milliseconds 20
        }

        return $true
    }
    catch {
        return $false
    }
}

function New-TemenosVirtualDesktop {
    # Ctrl + Win + D
    [void](Invoke-TemenosKeyChord -Keys ([byte[]](0x11, 0x5B, 0x44)))
}
