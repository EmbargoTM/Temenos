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
    private static Form LoopHost;
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
        if (postUpdate) LoopHost.BeginInvoke((MethodInvoker)ApplyPendingText);
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

        if (Window != LoopHost)
        {
            Window.Close();
            Window.Dispose();
        }
        Window = CreateOverlayWindow();
        Caption.Text = text;
        LayoutWindow(Window, Caption, text);
        Window.Show();
        Window.BringToFront();
        HideTimer.Stop();
        HideTimer.Start();
    }

    private static void HideIfIdle()
    {
        lock (Gate)
        {
            if (UpdateQueued || !String.IsNullOrEmpty(PendingText))
            {
                HideTimer.Stop();
                HideTimer.Start();
                return;
            }
        }
        HideTimer.Stop();
        if (Window != LoopHost)
        {
            Window.Hide();
            Window.Close();
            Window.Dispose();
            Window = LoopHost;
            Caption = null;
        }
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
        LoopHost = new Form();
        LoopHost.ShowInTaskbar = false;
        LoopHost.WindowState = FormWindowState.Minimized;
        LoopHost.Opacity = 0;
        LoopHost.Show();
        LoopHost.Hide();
        Window = LoopHost;

        HideTimer = new System.Windows.Forms.Timer();
        HideTimer.Interval = 2000;
        HideTimer.Tick += delegate { HideIfIdle(); };
        // Create the native handle before Show() can call BeginInvoke.
        IntPtr windowHandle = LoopHost.Handle;
        Ready.Set();
        Application.Run(LoopHost);
    }

    private static Form CreateOverlayWindow()
    {
        Form overlay = new Form();
        overlay.FormBorderStyle = FormBorderStyle.None;
        overlay.ShowInTaskbar = false;
        overlay.TopMost = true;
        overlay.StartPosition = FormStartPosition.Manual;
        overlay.BackColor = Color.FromArgb(18, 20, 26);
        overlay.Opacity = 0.70;
        overlay.AutoScaleMode = AutoScaleMode.None;

        Caption = new Label();
        Caption.AutoSize = false;
        Caption.ForeColor = Color.FromArgb(220, 235, 255);
        Caption.BackColor = Color.Transparent;
        Caption.Font = new Font("Consolas", 18, FontStyle.Bold);
        Caption.TextAlign = ContentAlignment.MiddleCenter;
        overlay.Controls.Add(Caption);
        overlay.Shown += delegate { PositionWindow(overlay); };
        overlay.Resize += delegate { PositionWindow(overlay); };
        return overlay;
    }

    private static void LayoutWindow(Form window, Label caption, string text)
    {
        string[] lines = text.Split(new string[] { "\r\n" }, StringSplitOptions.None);
        int columns = 0;
        foreach (string line in lines) columns = Math.Max(columns, line.Length);

        Size cell = TextRenderer.MeasureText(
            "M",
            caption.Font,
            Size.Empty,
            TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix
        );
        int textWidth = columns * cell.Width;
        int lineHeight = caption.Font.Height + 4;
        int textHeight = lines.Length * lineHeight;
        caption.SetBounds(20, 14, textWidth, textHeight);
        window.ClientSize = new Size(textWidth + 40, textHeight + 28);
        PositionWindow(window);
    }

    private static void PositionWindow(Form window)
    {
        Rectangle area = Screen.PrimaryScreen.Bounds;
        window.Location = new Point(
            area.Left + (area.Width - window.Width) / 2,
            area.Top + (area.Height - window.Height) / 2
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

    $contentLines = @("AREA $WorkspaceIndex")
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceName)) {
        $contentLines += $WorkspaceName
    }

    $maxContentLength = 0
    foreach ($contentLine in $contentLines) {
        $maxContentLength = [Math]::Max($maxContentLength, $contentLine.Length)
    }

    $innerWidth = [Math]::Max(24, $maxContentLength + 4)
    $border = "+" + (('-' * $innerWidth) -join '') + "+"
    $rows = foreach ($contentLine in $contentLines) {
        $sideSpace = $innerWidth - $contentLine.Length
        $leftSpace = [Math]::Floor($sideSpace / 2)
        $rightSpace = $sideSpace - $leftSpace
        "|" + ((' ' * $leftSpace) -join '') + $contentLine + ((' ' * $rightSpace) -join '') + "|"
    }
    $caption = (@($border) + @($rows) + @($border)) -join "`r`n"
    try { [TemenosWorkspaceIndicator]::Show($caption) } catch {}
}

