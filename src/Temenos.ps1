# ============================================================
# TEMENOS
# Utilitário de Áreas de Trabalho Virtuais para Windows 10
#
# Código em src\; os dados de execução ficam em Documents\Temenos\runtime\
# (ou no caminho fornecido pelo launcher via -RuntimeRoot).
# ============================================================

param([string]$RuntimeRoot)

$ErrorActionPreference = "SilentlyContinue"

$CodeRoot    = $PSScriptRoot
. (Join-Path $CodeRoot "Config.ps1")
. (Join-Path $CodeRoot "DesktopEvents.ps1")
$ConfigPath = Join-Path (Split-Path -Parent $CodeRoot) "Temenos.json"

try {
    $Config = Import-TemenosConfig -Path $ConfigPath
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $documents = [Environment]::GetFolderPath("MyDocuments")
    $RuntimeRoot = Join-Path $documents "Temenos\runtime"
}

$Root        = $RuntimeRoot
$Common      = Join-Path $Root $Config.Paths.Common
$Wallpapers  = Join-Path $Root $Config.Paths.Wallpapers
$Cache       = Join-Path $Root $Config.Paths.WallpaperCache
$PidFile     = Join-Path $Root "Temenos.pid"

. (Join-Path $CodeRoot "Indicator.ps1")

$workspaceFolders = @($Config.Workspaces.Values | ForEach-Object { Join-Path $Root $_.Folder })
$runtimeFolders = @($Root, $Common, $Wallpapers, $Cache) + $workspaceFolders
New-Item -ItemType Directory -Force -Path $runtimeFolders | Out-Null

# ------------------------------------------------------------
# Impede duas instâncias do Temenos
# ------------------------------------------------------------
try {
    $oldPid = $null

    if (Test-Path -LiteralPath $PidFile) {
        $oldPid = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue
    }

    if ($oldPid -and ($oldPid -as [int])) {
        $oldProc = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue

        if ($oldProc -and $oldProc.Id -ne $PID) {
            try {
                Stop-Process -Id $oldProc.Id -Force -ErrorAction SilentlyContinue
                Wait-Process -Id $oldProc.Id -Timeout 2 -ErrorAction SilentlyContinue
            } catch {}
        }
    }

    Set-Content -LiteralPath $PidFile -Value $PID -Force
} catch {}

# ------------------------------------------------------------
# Wallpaper
# ------------------------------------------------------------
if (-not ("TemenosWallpaperApi" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class TemenosWallpaperApi
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SystemParametersInfo(
        uint uiAction,
        uint uiParam,
        string pvParam,
        uint fWinIni
    );
}
"@
}

function Find-Wallpaper {
    param([int]$DesktopIndex)

    $workspace = Get-TemenosWorkspace -WorkspaceIndex $DesktopIndex
    if ($null -eq $workspace -or [string]::IsNullOrWhiteSpace($workspace.Wallpaper)) {
        return $null
    }

    $candidate = Join-Path $Wallpapers $workspace.Wallpaper
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        try {
            $item = Get-Item -LiteralPath $candidate -ErrorAction Stop
            if ($item.Length -gt 0) { return $item.FullName }
        } catch {}
    }

    return $null
}

function Prepare-Wallpaper {
    param(
        [string]$Source,
        [int]$DesktopIndex
    )

    $cacheFile = Join-Path $Cache ("Area{0}.jpg" -f $DesktopIndex)

    try {
        Add-Type -AssemblyName System.Drawing

        $img = [System.Drawing.Image]::FromFile($Source)

        if ($img.Width -lt 2 -or $img.Height -lt 2) {
            $img.Dispose()
            return $null
        }

        $bitmap = New-Object System.Drawing.Bitmap($img)
        $img.Dispose()

        $tmp = "$cacheFile.tmp"
        $bitmap.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $bitmap.Dispose()

        Move-Item -LiteralPath $tmp -Destination $cacheFile -Force

        return $cacheFile
    }
    catch {
        return $null
    }
}

function Set-Wallpaper {
    param([int]$DesktopIndex)

    $source = Find-Wallpaper -DesktopIndex $DesktopIndex

    # Sem wallpaper configurado: mantém o atual.
    if ($null -eq $source) {
        return
    }

    $cached = Prepare-Wallpaper -Source $source -DesktopIndex $DesktopIndex

    # Arquivo temporariamente bloqueado/incompleto: não mexe no fundo atual.
    if ($null -eq $cached) {
        return
    }

    [void][TemenosWallpaperApi]::SystemParametersInfo(
        0x0014,
        0,
        $cached,
        0x0003
    )
}

# ------------------------------------------------------------
# Identificação da Área de Trabalho Virtual
# ------------------------------------------------------------
function Get-RegBinary {
    param(
        [Microsoft.Win32.RegistryKey]$Key,
        [string]$Name
    )

    if ($null -eq $Key) { return $null }

    try {
        $v = $Key.GetValue(
            $Name,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )

        if ($v -is [byte[]]) {
            return [byte[]]$v
        }
    } catch {}

    return $null
}

function Get-CurrentDesktopBytes {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser,
        [Microsoft.Win32.RegistryView]::Default
    )

    try {
        $global = $base.OpenSubKey(
            "Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops",
            $false
        )

        try {
            $v = Get-RegBinary $global "CurrentVirtualDesktop"

            if ($null -ne $v -and $v.Length -eq 16) {
                return $v
            }
        } finally {
            if ($global) { $global.Dispose() }
        }

        $sid = try { (Get-Process -Id $PID).SessionId } catch { 1 }

        $session = $base.OpenSubKey(
            "Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\$sid\VirtualDesktops",
            $false
        )

        try {
            $v = Get-RegBinary $session "CurrentVirtualDesktop"

            if ($null -ne $v -and $v.Length -eq 16) {
                return $v
            }
        } finally {
            if ($session) { $session.Dispose() }
        }
    } finally {
        if ($base) { $base.Dispose() }
    }

    return $null
}

function Get-AllDesktopIds {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser,
        [Microsoft.Win32.RegistryView]::Default
    )

    try {
        $key = $base.OpenSubKey(
            "Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops",
            $false
        )

        try {
            $v = Get-RegBinary $key "VirtualDesktopIDs"

            if ($null -ne $v -and $v.Length -ge 16) {
                return $v
            }
        } finally {
            if ($key) { $key.Dispose() }
        }
    } finally {
        if ($base) { $base.Dispose() }
    }

    return $null
}

function Test-BytesEqual {
    param([byte[]]$A, [byte[]]$B)

    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length) { return $false }

    for ($i = 0; $i -lt $A.Length; $i++) {
        if ($A[$i] -ne $B[$i]) {
            return $false
        }
    }

    return $true
}

function Get-CurrentDesktopIndex {
    $current = Get-CurrentDesktopBytes
    $all = Get-AllDesktopIds

    if ($null -eq $current -or $null -eq $all -or $all.Length -lt 16) {
        return $null
    }

    $count = [int]($all.Length / 16)

    for ($i = 0; $i -lt $count; $i++) {
        $one = New-Object byte[] 16
        [Array]::Copy($all, $i * 16, $one, 0, 16)

        if (Test-BytesEqual $one $current) {
            return $i + 1
        }
    }

    return $null
}

function Get-DesktopCount {
    $all = Get-AllDesktopIds

    if ($null -eq $all -or $all.Length -lt 16) {
        return 1
    }

    return [int]($all.Length / 16)
}

# ------------------------------------------------------------
# Workspace metadata comes from Temenos.json.
# ------------------------------------------------------------
function Get-AreaFolder {
    param([int]$DesktopIndex)

    $workspace = Get-TemenosWorkspace -WorkspaceIndex $DesktopIndex
    if ($null -eq $workspace) { return $null }
    return Join-Path $Root $workspace.Folder
}

function Get-AreaDisplayName {
    param([int]$DesktopIndex)

    $workspace = Get-TemenosWorkspace -WorkspaceIndex $DesktopIndex
    if ($null -eq $workspace) { return "" }
    return $workspace.Name
}

# ------------------------------------------------------------
# Ícones
# ------------------------------------------------------------
function Get-ManagedShortcutNames {
    $names = @{}

    if (Test-Path $Common) {
        Get-ChildItem -Path $Common -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in ".lnk", ".url" } |
            ForEach-Object { $names[$_.Name] = $true }
    }

    foreach ($workspace in $Config.Workspaces.Values) {
        $folder = Join-Path $Root $workspace.Folder
        if (Test-Path -LiteralPath $folder -PathType Container) {
            Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in ".lnk", ".url" } |
                ForEach-Object { $names[$_.Name] = $true }
        }
    }

    return @($names.Keys)
}

if (-not ("TemenosShellRefresh" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class TemenosShellRefresh
{
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(
        uint wEventId,
        uint uFlags,
        IntPtr dwItem1,
        IntPtr dwItem2
    );
}
"@
}

function Refresh-Desktop {
    [TemenosShellRefresh]::SHChangeNotify(
        0x8000000,
        0,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    )

    Start-Sleep -Milliseconds 50

    [TemenosShellRefresh]::SHChangeNotify(
        0x8000000,
        0,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    )
}

function Set-DesktopState {
    param([int]$DesktopIndex)

    $desktop = [Environment]::GetFolderPath("Desktop")
    $area = Get-AreaFolder -DesktopIndex $DesktopIndex

    if ($area) { New-Item -ItemType Directory -Force -Path $area | Out-Null }

    $managed = @(Get-ManagedShortcutNames)

    foreach ($name in $managed) {
        $target = Join-Path $desktop $name

        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $Common) {
        Get-ChildItem -Path $Common -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in ".lnk", ".url" } |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName `
                    -Destination (Join-Path $desktop $_.Name) `
                    -Force -ErrorAction SilentlyContinue
            }
    }

    if ($area -and (Test-Path -LiteralPath $area -PathType Container)) {
        Get-ChildItem -Path $area -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in ".lnk", ".url" } |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName `
                    -Destination (Join-Path $desktop $_.Name) `
                    -Force -ErrorAction SilentlyContinue
            }
    }

    Set-Wallpaper -DesktopIndex $DesktopIndex
    Refresh-Desktop
}

# ------------------------------------------------------------
# Diagnóstico
# ------------------------------------------------------------
if ($args -contains "-Test") {
    $i = Get-CurrentDesktopIndex
    $n = Get-DesktopCount

    Write-Host "Temenos"
    Write-Host "Área atual: $i"
    Write-Host "Total de áreas: $n"
    Write-Host "Runtime: $Root"

    $source = Find-Wallpaper -DesktopIndex $i

    if ($source) {
        Write-Host "Wallpaper: $source"
    } else {
        Write-Host "Wallpaper: nenhum configurado"
    }

    exit
}

# ------------------------------------------------------------
# Inicialização + notificações de mudança
# ------------------------------------------------------------
$last = 0
try {
    $desktopWatcher = New-Object TemenosDesktopChangeWatcher -ErrorAction Stop
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}

$current = Get-CurrentDesktopIndex
while ($null -eq $current) {
    [void]$desktopWatcher.WaitForChange(-1)
    $current = Get-CurrentDesktopIndex
}

Show-WorkspaceIndicator -WorkspaceIndex $current -WorkspaceName (Get-AreaDisplayName -DesktopIndex $current)
$last = $current
Set-DesktopState -DesktopIndex $current

while ($true) {
    [void]$desktopWatcher.WaitForChange(-1)
    $current = Get-CurrentDesktopIndex

    if ($null -ne $current -and $current -ne $last) {
        $last = $current
        Show-WorkspaceIndicator -WorkspaceIndex $current -WorkspaceName (Get-AreaDisplayName -DesktopIndex $current)
        Set-DesktopState -DesktopIndex $current
    }
}
