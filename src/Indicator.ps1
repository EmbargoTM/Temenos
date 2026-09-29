# Visual feedback for the active workspace. The display name is supplied by
# the caller so this module can later consume centralized configuration.
if (-not ("TemenosWorkspaceIndicator" -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;

public static class TemenosWorkspaceIndicator
{
    private static readonly object Gate = new object();
    private static Form Window;
    private static Label Caption;
    private static System.Windows.Forms.Timer HideTimer;
    private static Thread UiThread;
    private static readonly ManualResetEvent Ready = new ManualResetEvent(false);
    private static string PendingText;
    private static bool UpdateQueued;

    public static void Show(string text)
    {
        EnsureStarted();
        bool postUpdate = false;
        lock (Gate)
        {
            PendingText = text;
            if (!UpdateQueued)
            {
                UpdateQueued = true;
                postUpdate = true;
            }
        }
        if (postUpdate) Window.BeginInvoke((MethodInvoker)ApplyPendingText);
    }

    private static void ApplyPendingText()
    {
        string text;
        lock (Gate)
        {
            text = PendingText;
            PendingText = null;
            UpdateQueued = false;
        }
        if (String.IsNullOrEmpty(text)) return;

        Caption.Text = text;
        Window.Show();
        Window.BringToFront();
        HideTimer.Stop();
        HideTimer.Start();
    }

    private static void EnsureStarted()
    {
        lock (Gate)
        {
            if (UiThread == null)
            {
                UiThread = new Thread(CreateWindow);
                UiThread.IsBackground = true;
                UiThread.SetApartmentState(ApartmentState.STA);
                UiThread.Start();
            }
        }
        Ready.WaitOne();
    }

    private static void CreateWindow()
    {
        Window = new Form();
        Window.FormBorderStyle = FormBorderStyle.None;
        Window.ShowInTaskbar = false;
        Window.TopMost = true;
        Window.StartPosition = FormStartPosition.Manual;
        Window.BackColor = Color.FromArgb(18, 20, 26);
        Window.Opacity = 0.70;
        Window.Padding = new Padding(20, 14, 20, 14);
        Window.AutoSize = true;
        Window.AutoSizeMode = AutoSizeMode.GrowAndShrink;

        Caption = new Label();
        Caption.AutoSize = true;
        Caption.ForeColor = Color.FromArgb(220, 235, 255);
        Caption.BackColor = Color.Transparent;
        Caption.Font = new Font("Consolas", 18, FontStyle.Bold);
        Caption.TextAlign = ContentAlignment.MiddleCenter;
        Window.Controls.Add(Caption);

        HideTimer = new System.Windows.Forms.Timer();
        HideTimer.Interval = 2400;
        HideTimer.Tick += delegate { HideTimer.Stop(); Window.Hide(); };
        Window.Shown += delegate { PositionWindow(); };
        Window.Resize += delegate { PositionWindow(); };
        Window.VisibleChanged += delegate { if (Window.Visible) PositionWindow(); };
        // Create the native handle before Show() can call BeginInvoke.
        IntPtr windowHandle = Window.Handle;
        Ready.Set();
        Application.Run(Window);
    }

    private static void PositionWindow()
    {
        Rectangle area = Screen.PrimaryScreen.Bounds;
        Window.Location = new Point(
            area.Left + (area.Width - Window.Width) / 2,
            area.Top + (area.Height - Window.Height) / 2
        );
    }
}
"@
}

function Show-WorkspaceIndicator {
    param(
        [Parameter(Mandatory = $true)][int]$WorkspaceIndex,
        [AllowNull()][AllowEmptyString()][string]$WorkspaceName
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceName)) {
        $displayName = "AREA $WorkspaceIndex"
    } else {
        $displayName = "AREA $WorkspaceIndex - $WorkspaceName"
    }
    $innerWidth = [Math]::Max(24, $displayName.Length + 4)
    $sideSpace = $innerWidth - $displayName.Length
    $leftSpace = [Math]::Floor($sideSpace / 2)
    $rightSpace = $sideSpace - $leftSpace
    $border = "+" + (('-' * $innerWidth) -join '') + "+"
    $line = "|" + ((' ' * $leftSpace) -join '') + $displayName + ((' ' * $rightSpace) -join '') + "|"
    $caption = "$border`r`n$line`r`n$border"
    try { [TemenosWorkspaceIndicator]::Show($caption) } catch {}
}

