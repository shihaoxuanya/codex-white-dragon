param(
    [switch]$Preview,
    # Failsafe for the animation window.
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$appId = 'OpenAI.Codex_2p2nqsd0c76g0!App'
$animationPath = Join-Path $PSScriptRoot 'animation.html'
$edgePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
$profilePath = Join-Path $env:LOCALAPPDATA 'CodexStartupEffect\EdgeProfile'
$logPath = Join-Path $env:LOCALAPPDATA 'CodexStartupEffect\launcher.log'
function Write-LaunchLog([string]$message) {
    try {
        $folder = Split-Path -Parent $logPath
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 262144) {
            Move-Item -LiteralPath $logPath -Destination ($logPath + '.old') -Force
        }
        Add-Content -LiteralPath $logPath -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') + ' ' + $message) -Encoding UTF8
    } catch { }
}

function Open-Codex {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$appId" | Out-Null
}
function Start-ReadinessCheck([IntPtr]$windowHandle) {
    # Only inspect accessibility metadata; never read the editor's contents.
    Start-Job -ArgumentList ([long]$windowHandle) -ScriptBlock {
        param([long]$handle)
        try {
            Add-Type -AssemblyName UIAutomationClient
            Add-Type -AssemblyName UIAutomationTypes
            $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$handle)
            $condition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit)
            $samples = 0
            $until = [DateTime]::UtcNow.AddSeconds(40)
            while ([DateTime]::UtcNow -lt $until) {
                $found = $false
                $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
                foreach ($edit in $edits) {
                    $current = $edit.Current
                    if ($current.ClassName -like '*ProseMirror*' -and $current.IsEnabled -and -not $current.IsOffscreen) {
                        $found = $true
                        break
                    }
                }
                if ($found) { $samples++ } else { $samples = 0 }
                if ($samples -ge 2) { return $true }
                Start-Sleep -Milliseconds 750
            }
        } catch { }
        return $false
    }
}

$ownsMutex = $false
$mutex = $null
$codexRequested = $false
$edge = $null
$overlayHandle = [IntPtr]::Zero
$readyJob = $null
$readyWindowHandle = [IntPtr]::Zero
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\CodexStartupEffectLauncher')
    try { $ownsMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { Write-LaunchLog 'Another launch is already running'; return }
    Write-LaunchLog "Launch started; preview=$Preview"

    if (-not (Test-Path -LiteralPath $animationPath -PathType Leaf)) {
        throw "Animation file not found: $animationPath"
    }
    if (-not (Test-Path -LiteralPath $edgePath -PathType Leaf)) {
        throw "Microsoft Edge not found: $edgePath"
    }
    New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
    $uri = ([System.Uri]$animationPath).AbsoluteUri + '?launcher=1'
    if ($Preview) { $uri += '&preview=1' } else { $uri += '&wait=1' }
    $arguments = @(
        "--app=`"$uri`"",
        "--user-data-dir=`"$profilePath`"",
        '--disable-background-mode',
        '--disable-backgrounding-occluded-windows',
        '--disable-renderer-backgrounding',
        '--disable-features=CalculateNativeWinOcclusion',
        '--autoplay-policy=no-user-gesture-required',
        '--no-first-run',
        '--no-default-browser-check'
    )
    if (-not $Preview) { $arguments += @('--window-position=-32000,-32000', '--start-minimized') } else { $arguments += '--start-fullscreen' }
    if (-not $Preview) {
        # Compile window helpers before starting Edge, to minimize the time
        # between creation of the off-screen window and hiding it.
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexStartupWindow {
    static bool surfaceHeld;
    [StructLayout(LayoutKind.Sequential)] public struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr window, uint key, byte alpha, uint flags);
    static Rect lastMonitor; static bool haveMonitor;
    public static bool MonitorBounds(IntPtr window, out Rect bounds) {
        var info = new MonitorInfo(); info.Size = Marshal.SizeOf(typeof(MonitorInfo));
        if (window != IntPtr.Zero && IsWindow(window) && GetMonitorInfo(MonitorFromWindow(window, 2), ref info)) {
            lastMonitor = info.Monitor; haveMonitor = true;
        }
        bounds = lastMonitor; return haveMonitor;
    }
    public static bool SetOpacity(IntPtr window, byte alpha) {
        int ex = GetWindowLong(window, -20);
        if ((ex & 0x80000) == 0) SetWindowLong(window, -20, ex | 0x80000);
        return SetLayeredWindowAttributes(window, 0, alpha, 2);
    }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr param);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int size);
    [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr window, IntPtr region, bool redraw);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    public delegate bool EnumChildProc(IntPtr window, IntPtr param);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int size);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint="SetWindowLongW")] public static extern int SetWindowLong(IntPtr window, int index, int value);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect rect, int size);
    [StructLayout(LayoutKind.Sequential)] struct LastInputInfo { public uint Size, Time; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInputInfo info);
    public static uint LastInputTick() {
        var info = new LastInputInfo(); info.Size = (uint)Marshal.SizeOf(typeof(LastInputInfo));
        return GetLastInputInfo(ref info) ? info.Time : 0;
    }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    public static void FocusAnimation(IntPtr window, uint foregroundThread) {
        uint current = GetCurrentThreadId();
        bool attached = current != foregroundThread && AttachThreadInput(current, foregroundThread, true);
        try { SetForegroundWindow(window); }
        finally { if (attached) AttachThreadInput(current, foregroundThread, false); }
    }
    public static void MakeBorderless(IntPtr window) {
        const int frame = 0x00C00000 | 0x00040000 | 0x00080000 | 0x00020000 | 0x00010000;
        SetWindowLong(window, -16, GetWindowLong(window, -16) & ~frame);
        int noCorners = 1;
        DwmSetWindowAttribute(window, 33, ref noCorners, sizeof(int));
    }
    public static bool HasFrame(IntPtr window) {
        return (GetWindowLong(window, -16) & 0x00C00000) != 0;
    }
    public static bool PrimeViewport(IntPtr overlay) {
        // Keep the window far outside the desktop while Chromium creates
        // its rendering child; showing it hidden prevents that child existing.
        IntPtr empty = CreateRectRgn(0, 0, 0, 0);
        if (empty == IntPtr.Zero) return false;
        if (SetWindowRgn(overlay, empty, true) == 0) { DeleteObject(empty); return false; }
        surfaceHeld = true;
        if (!SetWindowPos(overlay, IntPtr.Zero, -32000, -32000, 0, 0, 0x35)) return false;
        ShowWindow(overlay, 4);
        return SetWindowPos(overlay, IntPtr.Zero, -32000, -32000, 0, 0, 0x15);
    }
    public static IntPtr Viewport(IntPtr overlay) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(overlay, delegate(IntPtr child, IntPtr param) {
            var name = new System.Text.StringBuilder(128);
            GetClassName(child, name, name.Capacity);
            if (name.ToString() == "Chrome_RenderWidgetHostHWND") { found = child; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static bool ReleaseViewport(IntPtr overlay) {
        Rect outer, view;
        IntPtr child = Viewport(overlay);
        if (child == IntPtr.Zero || !GetWindowRect(overlay, out outer) || !GetWindowRect(child, out view)) return false;
        IntPtr region = CreateRectRgn(view.Left-outer.Left, view.Top-outer.Top, view.Right-outer.Left, view.Bottom-outer.Top);
        if (region == IntPtr.Zero) return false;
        if (SetWindowRgn(overlay, region, true) == 0) { DeleteObject(region); return false; }
        surfaceHeld = false;
        return true;
    }
    public static bool Near(Rect a, Rect b) {
        // Fractional display scaling can round a one-pixel resize in either
        // direction. The two-pixel bleed still covers the target's border.
        return Math.Abs(a.Left-b.Left) <= 1 && Math.Abs(a.Top-b.Top) <= 1 &&
            Math.Abs(a.Right-b.Right) <= 1 && Math.Abs(a.Bottom-b.Bottom) <= 1;
    }
    public static bool Align(IntPtr overlay, IntPtr target, bool frameChanged, bool topmost) {
        Rect bounds, current, viewport;
        if (!MonitorBounds(target, out bounds)) return false;
        int width = bounds.Right - bounds.Left, height = bounds.Bottom - bounds.Top;
        if (width < 100 || height < 100) return false;
        IntPtr child = Viewport(overlay);
        if (child == IntPtr.Zero || !GetWindowRect(overlay, out current) || !GetWindowRect(child, out viewport)) return false;
        if (!frameChanged && Near(viewport, bounds)) return true;
        int x = current.Left + bounds.Left - viewport.Left;
        int y = current.Top + bounds.Top - viewport.Top;
        int newWidth = (current.Right - current.Left) + width - (viewport.Right - viewport.Left);
        int newHeight = (current.Bottom - current.Top) + height - (viewport.Bottom - viewport.Top);
        if (newWidth < 100 || newHeight < 100) return false;
        // Clip before moving on screen so Edge's chrome is never exposed.
        int clipX = bounds.Left - x, clipY = bounds.Top - y;
        if (!surfaceHeld) {
            IntPtr region = CreateRectRgn(clipX, clipY, clipX + width, clipY + height);
            if (region == IntPtr.Zero) return false;
            if (SetWindowRgn(overlay, region, true) == 0) { DeleteObject(region); return false; }
        }
        // Align the actual web viewport, not Edge's larger decorated window.
        return SetWindowPos(overlay, new IntPtr(topmost ? -1 : -2), x, y, newWidth, newHeight, 0x210u | (frameChanged ? 0x20u : 0u));
    }
    public static bool Matches(IntPtr overlay, IntPtr target) {
        Rect a, b;
        IntPtr child = Viewport(overlay);
        if (child == IntPtr.Zero || !GetWindowRect(child, out a) ||
            !MonitorBounds(target, out b)) return false;
        return Near(a, b);
    }
    public static void SetTopmost(IntPtr window, bool topmost) {
        SetWindowPos(window, new IntPtr(topmost ? -1 : -2), 0, 0, 0, 0, 0x213);
    }
}
'@
            # The host may already have a process-wide DPI setting. Set this
            # thread's context explicitly so GetWindowRect/SetWindowPos use the
            # same physical coordinates as DWM, including on mixed-DPI screens.
            try { $null = [CodexStartupWindow]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
            try { $null = [CodexStartupWindow]::SetThreadDpiAwarenessContext([IntPtr](-4)) } catch { }
            $edge = Start-Process -FilePath $edgePath -ArgumentList $arguments -PassThru
            $windowDeadline = [DateTime]::UtcNow.AddSeconds(8)
            do {
                $edge.Refresh()
                if ($edge.MainWindowHandle -ne [IntPtr]::Zero -or $edge.HasExited) { break }
                Start-Sleep -Milliseconds 50
            } while ([DateTime]::UtcNow -lt $windowDeadline)
            $overlayHandle = $edge.MainWindowHandle
            if ($overlayHandle -eq [IntPtr]::Zero) { throw 'Animation window did not appear.' }
            $null = [CodexStartupWindow]::ShowWindow($overlayHandle, 0)
            if ([CodexStartupWindow]::IsWindowVisible($overlayHandle)) { throw 'Animation window could not be hidden.' }
        } catch {
            if ($null -ne $edge -and -not $edge.HasExited) {
                if ($overlayHandle -and $overlayHandle -ne [IntPtr]::Zero) { $null = [CodexStartupWindow]::PostMessage($overlayHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
                else { $edge.Kill() }
            }
            throw
        }
        Open-Codex
        $codexRequested = $true
        Write-LaunchLog 'Codex requested; waiting for window and decoded animation'
        # Do not reveal a default Edge window or start the sequence until both
        # the HTML is listening and the actual Codex window can be aligned.
        $revealDeadline = [DateTime]::UtcNow.AddSeconds(30)
        $revealed = $false
        $viewportPrimed = $false
        do {
            $edge.Refresh()
            if ($edge.HasExited -or -not [CodexStartupWindow]::IsWindow($overlayHandle)) { break }
            $title = New-Object System.Text.StringBuilder 256
            $null = [CodexStartupWindow]::GetWindowText($overlayHandle, $title, $title.Capacity)
            $target = Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {
                $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.Path -like '*\WindowsApps\OpenAI.Codex_*' -and
                [CodexStartupWindow]::IsWindowVisible($_.MainWindowHandle) -and -not [CodexStartupWindow]::IsIconic($_.MainWindowHandle)
            } | Select-Object -First 1
            if ($target -and $title.ToString() -in @('CodexAnimationReady','CodexAnimationPrepared')) {
                # Start the independent accessibility probe while the scene
                # is still invisible, avoiding process startup during playback.
                if ($null -eq $readyJob) {
                    try { $readyWindowHandle = $target.MainWindowHandle; $readyJob = Start-ReadinessCheck $readyWindowHandle } catch { $readyJob = $null }
                }
                $foregroundProcessId = [uint32]0
                $foreground = [CodexStartupWindow]::GetForegroundWindow()
                $foregroundThread = [CodexStartupWindow]::GetWindowThreadProcessId($foreground, [ref]$foregroundProcessId)
                # Never surface the overlay over an unrelated application.
                if ($foregroundProcessId -eq $target.Id -or ($viewportPrimed -and $foreground -eq $overlayHandle)) {
                    [CodexStartupWindow]::MakeBorderless($overlayHandle)
                    # Keep the Chromium surface invisible even if its region changes during startup.
                    if (-not [CodexStartupWindow]::SetOpacity($overlayHandle, 0)) { throw 'Cannot hide animation during preparation.' }
                    if (-not $viewportPrimed) { $viewportPrimed = [CodexStartupWindow]::PrimeViewport($overlayHandle) }
                    if ([CodexStartupWindow]::Align($overlayHandle, $target.MainWindowHandle, $true, $true)) {
                        # Crossing from the off-screen monitor to a scaled
                        # display can make Edge resize itself after the first
                        # SetWindowPos. Correct and verify while still hidden.
                        $stableDeadline = [DateTime]::UtcNow.AddSeconds(15)
                        $stableSamples = 0
                        $sceneStarted = $false
                        do {
                            Start-Sleep -Milliseconds 100
                            # Reacquire the target because startup may replace its window.
                            $candidate = Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {
                                $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.Path -like '*\WindowsApps\OpenAI.Codex_*' -and
                                [CodexStartupWindow]::IsWindowVisible($_.MainWindowHandle) -and -not [CodexStartupWindow]::IsIconic($_.MainWindowHandle)
                            } | Select-Object -First 1
                            if ($candidate -and $candidate.MainWindowHandle -ne $target.MainWindowHandle) {
                                Write-LaunchLog 'Codex startup window changed; reacquiring target'
                                $target = $candidate
                                $stableSamples = 0
                                if ($null -ne $readyJob) { Remove-Job -Job $readyJob -Force -ErrorAction SilentlyContinue; $readyJob = $null }
                                try { $readyWindowHandle = $target.MainWindowHandle; $readyJob = Start-ReadinessCheck $readyWindowHandle } catch { $readyJob = $null }
                            } elseif ($candidate) { $target = $candidate }
                            if ([CodexStartupWindow]::Matches($overlayHandle, $target.MainWindowHandle)) {
                                $stableSamples++
                            } else {
                                $stableSamples = 0
                                $null = [CodexStartupWindow]::Align($overlayHandle, $target.MainWindowHandle, $false, $true)
                            }
                            $sceneTitle = New-Object System.Text.StringBuilder 256
                            $null = [CodexStartupWindow]::GetWindowText($overlayHandle, $sceneTitle, $sceneTitle.Capacity)
                            $sceneStarted = $sceneTitle.ToString() -eq 'CodexAnimationPrepared'
                        } while (($stableSamples -lt 3 -or -not $sceneStarted) -and [DateTime]::UtcNow -lt $stableDeadline)
                        $currentForeground = [CodexStartupWindow]::GetForegroundWindow()
                        $currentForegroundPid = [uint32]0
                        $null = [CodexStartupWindow]::GetWindowThreadProcessId($currentForeground, [ref]$currentForegroundPid)
                        $stillInLaunch = $currentForegroundPid -eq $target.Id -or $currentForeground -eq $overlayHandle
                        if ($stableSamples -ge 3 -and $sceneStarted -and $stillInLaunch -and [CodexStartupWindow]::ReleaseViewport($overlayHandle)) {
                            # Hide and wait for the page to acknowledge the transition;
                            # only the subsequent show starts animation and sound.
                            # Hiding the foreground Edge window may itself cause
                            # Windows to activate another window. Only treat this as
                            # a user switch if new input occurred during the handoff.
                            $beforeHidePid = [uint32]0
                            $beforeHide = [CodexStartupWindow]::GetForegroundWindow()
                            $null = [CodexStartupWindow]::GetWindowThreadProcessId($beforeHide, [ref]$beforeHidePid)
                            if ($beforeHide -ne $overlayHandle -and $beforeHidePid -ne $target.Id) {
                                Write-LaunchLog 'Reveal cancelled because foreground changed before handoff'
                                return
                            }
                            $inputBeforeHide = [CodexStartupWindow]::LastInputTick()
                            $null = [CodexStartupWindow]::ShowWindow($overlayHandle, 0)
                            $armDeadline = [DateTime]::UtcNow.AddSeconds(3)
                            $armed = $false
                            do {
                                Start-Sleep -Milliseconds 50
                                $armTitle = New-Object System.Text.StringBuilder 256
                                $null = [CodexStartupWindow]::GetWindowText($overlayHandle, $armTitle, $armTitle.Capacity)
                                $armed = $armTitle.ToString() -eq 'CodexAnimationArmed'
                            } while (-not $armed -and [DateTime]::UtcNow -lt $armDeadline)
                            if (-not $armed) { throw 'Animation did not acknowledge reveal.' }
                            $afterHidePid = [uint32]0
                            $afterHide = [CodexStartupWindow]::GetForegroundWindow()
                            $null = [CodexStartupWindow]::GetWindowThreadProcessId($afterHide, [ref]$afterHidePid)
                            $inputAfterHide = [CodexStartupWindow]::LastInputTick()
                            if ($afterHide -ne $overlayHandle -and $afterHidePid -ne $target.Id -and ($inputBeforeHide -eq 0 -or $inputAfterHide -eq 0 -or $inputAfterHide -ne $inputBeforeHide)) {
                                Write-LaunchLog "Reveal cancelled after foreground and user input changed; foregroundPid=$afterHidePid targetPid=$($target.Id)"
                                return
                            }
                            if ($afterHide -ne $overlayHandle -and $afterHidePid -ne $target.Id) {
                                Write-LaunchLog "System changed foreground while hiding animation; continuing without new user input"
                            }
                            if (-not [CodexStartupWindow]::SetOpacity($overlayHandle, 255)) { throw 'Cannot reveal animation.' }
                            $null = [CodexStartupWindow]::ShowWindow($overlayHandle, 8)
                            if ([CodexStartupWindow]::IsWindow($target.MainWindowHandle)) { $null = [CodexStartupWindow]::ShowWindow($target.MainWindowHandle, 3) }
                            $focusPid = [uint32]0
                            $focusThread = [CodexStartupWindow]::GetWindowThreadProcessId([CodexStartupWindow]::GetForegroundWindow(), [ref]$focusPid)
                            [CodexStartupWindow]::FocusAnimation($overlayHandle, $focusThread)
                            $revealed = $true
                            Write-LaunchLog 'Animation revealed'
                            break
                        }
                        Write-LaunchLog "Animation reveal failed: stableSamples=$stableSamples sceneStarted=$sceneStarted stillInLaunch=$stillInLaunch"
                        $viewRect = New-Object CodexStartupWindow+Rect
                        $screenRect = New-Object CodexStartupWindow+Rect
                        $outerRect = New-Object CodexStartupWindow+Rect
                        $child = [CodexStartupWindow]::Viewport($overlayHandle)
                        $null = [CodexStartupWindow]::GetWindowRect($child, [ref]$viewRect)
                        $null = [CodexStartupWindow]::GetWindowRect($overlayHandle, [ref]$outerRect)
                        $null = [CodexStartupWindow]::MonitorBounds($target.MainWindowHandle, [ref]$screenRect)
                        $currentPid = [uint32]0
                        $null = [CodexStartupWindow]::GetWindowThreadProcessId([CodexStartupWindow]::GetForegroundWindow(), [ref]$currentPid)
                        Write-LaunchLog "Reveal geometry: view=$($viewRect.Left),$($viewRect.Top),$($viewRect.Right),$($viewRect.Bottom) outer=$($outerRect.Left),$($outerRect.Top),$($outerRect.Right),$($outerRect.Bottom) monitor=$($screenRect.Left),$($screenRect.Top),$($screenRect.Right),$($screenRect.Bottom) overlayMaximized=$([CodexStartupWindow]::IsZoomed($overlayHandle)) foregroundPid=$currentPid targetPid=$($target.Id) edgePid=$($edge.Id)"
                        # If focus changed or alignment could not settle, do
                        # not leave a visible overlay over another application.
                        $null = [CodexStartupWindow]::PostMessage($overlayHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
                        return
                    }
                } elseif ($viewportPrimed) {
                    $null = [CodexStartupWindow]::PostMessage($overlayHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
                    return
                }
            }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $revealDeadline)
        if (-not $revealed) {
            Write-LaunchLog "Animation not revealed; edgeExited=$($edge.HasExited) title=$($title.ToString()) targetFound=$([bool]$target) foregroundPid=$foregroundProcessId targetPid=$(if ($target) { $target.Id } else { 0 })"
            if ([CodexStartupWindow]::IsWindow($overlayHandle)) { $null = [CodexStartupWindow]::PostMessage($overlayHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
            return
        }
    } else {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexPreviewWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    public delegate bool EnumChildProc(IntPtr h, IntPtr param);
    [DllImport("user32.dll", EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr h, int index);
    [DllImport("user32.dll", EntryPoint="SetWindowLongW")] public static extern int SetWindowLong(IntPtr h, int index, int value);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumChildProc callback, IntPtr param);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder name, int size);
    [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr h, IntPtr region, bool redraw);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    static Rect last; static IntPtr lastWindow = IntPtr.Zero;
    public static void MakeBorderless(IntPtr h) {
        const int frame = 0x00C00000 | 0x00040000 | 0x00080000 | 0x00020000 | 0x00010000;
        SetWindowLong(h, -16, GetWindowLong(h, -16) & ~frame);
        SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x37);
    }
    public static void TrimToViewport(IntPtr h) {
        IntPtr child = IntPtr.Zero;
        EnumChildWindows(h, delegate(IntPtr c, IntPtr param) {
            var name = new System.Text.StringBuilder(128);
            GetClassName(c, name, name.Capacity);
            if (name.ToString() == "Chrome_RenderWidgetHostHWND") { child = c; return false; }
            return true;
        }, IntPtr.Zero);
        Rect root, view;
        if (child == IntPtr.Zero || !GetWindowRect(h, out root) || !GetWindowRect(child, out view)) return;
        Rect clip = new Rect { Left = view.Left-root.Left, Top = view.Top-root.Top, Right = view.Right-root.Left, Bottom = view.Bottom-root.Top };
        if (h == lastWindow && clip.Left == last.Left && clip.Top == last.Top && clip.Right == last.Right && clip.Bottom == last.Bottom) return;
        IntPtr region = CreateRectRgn(clip.Left, clip.Top, clip.Right, clip.Bottom);
        if (region == IntPtr.Zero) return;
        if (SetWindowRgn(h, region, true) == 0) { DeleteObject(region); return; }
        last = clip; lastWindow = h;
    }
}
'@
        try { $null = [CodexPreviewWindow]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
        try { $null = [CodexPreviewWindow]::SetThreadDpiAwarenessContext([IntPtr](-4)) } catch { }
        $edge = Start-Process -FilePath $edgePath -ArgumentList $arguments -PassThru
        $windowDeadline = [DateTime]::UtcNow.AddSeconds(8)
        do {
            $edge.Refresh()
            if ($edge.MainWindowHandle -ne [IntPtr]::Zero -or $edge.HasExited) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $windowDeadline)
        if ($edge.MainWindowHandle -ne [IntPtr]::Zero) { [CodexPreviewWindow]::MakeBorderless($edge.MainWindowHandle) }
    }
    $limit = if ($Preview) { [Math]::Min(24, [Math]::Max(1, $TimeoutSeconds)) } else { [Math]::Max(1, $TimeoutSeconds) }
    $deadline = [DateTime]::UtcNow.AddSeconds($limit)
    $borderless = -not $Preview
    $wasTopmost = $true
    $finishedAt = $null
    $revealedAt = [DateTime]::UtcNow
    do {
        $edge.Refresh()
        if ($edge.HasExited) { break }
        if (-not $Preview -and $overlayHandle -ne [IntPtr]::Zero -and [CodexStartupWindow]::IsWindow($overlayHandle)) {
            try {
                # Only the Store Codex process is eligible; never move its window.
                $target = Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {
                    $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.Path -like '*\WindowsApps\OpenAI.Codex_*' -and
                    [CodexStartupWindow]::IsWindowVisible($_.MainWindowHandle) -and -not [CodexStartupWindow]::IsIconic($_.MainWindowHandle)
                } | Select-Object -First 1
                if ($target) {
                    if ($target.MainWindowHandle -ne $readyWindowHandle) {
                        if ($null -ne $readyJob) { Remove-Job -Job $readyJob -Force -ErrorAction SilentlyContinue; $readyJob = $null }
                        try { $readyWindowHandle = $target.MainWindowHandle; $readyJob = Start-ReadinessCheck $readyWindowHandle } catch { $readyJob = $null }
                    }
                    $foregroundProcessId = [uint32]0
                    $foreground = [CodexStartupWindow]::GetForegroundWindow()
                    $foregroundThread = [CodexStartupWindow]::GetWindowThreadProcessId($foreground, [ref]$foregroundProcessId)
                    $shouldBeTopmost = $foreground -eq $overlayHandle -or $foregroundProcessId -eq $target.Id
                    if ($shouldBeTopmost -and -not [CodexStartupWindow]::IsZoomed($target.MainWindowHandle)) {
                        $null = [CodexStartupWindow]::ShowWindow($target.MainWindowHandle, 3)
                        [CodexStartupWindow]::FocusAnimation($overlayHandle, $foregroundThread)
                    }
                    if ([CodexStartupWindow]::HasFrame($overlayHandle)) { $borderless = $false }
                    if (-not $borderless) { [CodexStartupWindow]::MakeBorderless($overlayHandle) }
                    if ([CodexStartupWindow]::Align($overlayHandle, $target.MainWindowHandle, -not $borderless, $shouldBeTopmost)) { $borderless = $true }
                    if ($shouldBeTopmost -ne $wasTopmost) { [CodexStartupWindow]::SetTopmost($overlayHandle, $shouldBeTopmost); $wasTopmost = $shouldBeTopmost }
                    if ($foregroundProcessId -eq $target.Id) { [CodexStartupWindow]::FocusAnimation($overlayHandle, $foregroundThread) }
                }
                $title = New-Object System.Text.StringBuilder 256
                $null = [CodexStartupWindow]::GetWindowText($overlayHandle, $title, $title.Capacity)
                if ($title.ToString() -eq 'CodexAnimationFinished' -and $null -eq $finishedAt) { $finishedAt = [DateTime]::UtcNow }
                $ready = $false
                if ($null -ne $finishedAt -and $null -ne $readyJob -and $readyJob.State -eq 'Completed' -and $target -and $target.MainWindowHandle -eq $readyWindowHandle) {
                    $ready = (Receive-Job -Job $readyJob -Keep | Select-Object -Last 1) -eq $true
                }
                $playbackStalled = $null -eq $finishedAt -and [DateTime]::UtcNow -ge $revealedAt.AddSeconds(22)
                $waitingExpired = $null -ne $finishedAt -and [DateTime]::UtcNow -ge $finishedAt.AddSeconds(15)
                if ($playbackStalled -or $waitingExpired -or ($null -ne $finishedAt -and $ready -and $target -and $target.Responding)) {
                        Write-LaunchLog "Transition: ready=$ready stalled=$playbackStalled waitExpired=$waitingExpired"
                        # Bring Codex forward only when the user is still in
                        # this launch flow, never after switching to another app.
                        if ($target -and ($foreground -eq $overlayHandle -or $foregroundProcessId -eq $target.Id)) {
                            # Fade the whole overlay while Codex remains underneath.
                            # Stop immediately if the user switches applications.
                            $fadeClock = [System.Diagnostics.Stopwatch]::StartNew()
                            while ($fadeClock.ElapsedMilliseconds -lt 850) {
                                $active = [CodexStartupWindow]::GetForegroundWindow()
                                if ($active -ne $overlayHandle -and $active -ne $target.MainWindowHandle) { break }
                                $t = [Math]::Min(1.0, $fadeClock.ElapsedMilliseconds / 850.0)
                                $smooth = $t * $t * (3.0 - 2.0 * $t)
                                if (-not [CodexStartupWindow]::SetOpacity($overlayHandle, [byte][Math]::Round(255 * (1 - $smooth)))) { break }
                                Start-Sleep -Milliseconds 16
                            }
                            $active = [CodexStartupWindow]::GetForegroundWindow()
                            if ($active -eq $overlayHandle -or $active -eq $target.MainWindowHandle) {
                                $null = [CodexStartupWindow]::SetOpacity($overlayHandle, 0)
                                [CodexStartupWindow]::SetTopmost($overlayHandle, $false)
                                [CodexStartupWindow]::FocusAnimation($target.MainWindowHandle, $foregroundThread)
                            }
                        }
                        $null = [CodexStartupWindow]::PostMessage($overlayHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
                        $closeDeadline = [DateTime]::UtcNow.AddSeconds(2)
                        do {
                            Start-Sleep -Milliseconds 50
                        } while ([CodexStartupWindow]::IsWindow($overlayHandle) -and [DateTime]::UtcNow -lt $closeDeadline)
                        if ([CodexStartupWindow]::IsWindow($overlayHandle) -and -not $edge.HasExited) { $edge.Kill() }
                    break
                }
            } catch { }
        } elseif ($Preview -and $edge.MainWindowHandle -ne [IntPtr]::Zero) {
            if (([CodexPreviewWindow]::GetWindowLong($edge.MainWindowHandle, -16) -band 0x00C00000) -ne 0) {
                [CodexPreviewWindow]::MakeBorderless($edge.MainWindowHandle)
            }
            [CodexPreviewWindow]::TrimToViewport($edge.MainWindowHandle)
        }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $edge.HasExited) {
        # Only ask the dedicated Edge process to close its own window. Never kill
        # unrelated Edge processes, even if graceful window close fails.
        $null = $edge.CloseMainWindow()
    }
} catch {
    Write-LaunchLog ('Launcher error: ' + $_.Exception.Message)
    if (-not $Preview -and -not $codexRequested) {
        # A broken animation should not prevent the real app from opening.
        Open-Codex
    } elseif ($Preview) {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Codex animation preview') | Out-Null
    }
} finally {
    if ($null -ne $readyJob) { Remove-Job -Job $readyJob -Force -ErrorAction SilentlyContinue }
    # If an unexpected error interrupts coordination, do not leave our
    # dedicated animation window hidden or stranded above another app.
    try {
        if (-not $Preview -and $null -ne $edge -and -not $edge.HasExited -and $overlayHandle -ne [IntPtr]::Zero -and [CodexStartupWindow]::IsWindow($overlayHandle)) {
            $null = [CodexStartupWindow]::PostMessage($overlayHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
        }
    } catch { }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
