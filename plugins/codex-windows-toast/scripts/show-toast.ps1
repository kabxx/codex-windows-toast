[CmdletBinding()]
param(
    [switch]$Test
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "activation-common.ps1")

if (-not ("CodexWindowsToast.WindowCapture" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace CodexWindowsToast {
    public static class WindowCapture {
        private const uint MonitorDefaultToNearest = 2;
        private const uint DwmwaExtendedFrameBounds = 9;
        private const uint DwmwaCloaked = 14;

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private delegate bool IsWindowArrangedProc(IntPtr hWnd);

        [StructLayout(LayoutKind.Sequential)]
        private struct Rect {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        private sealed class WindowEntry {
            public IntPtr Handle;
            public Rect Bounds;
        }

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetWindowRect(IntPtr hWnd, out Rect bounds);

        [DllImport("dwmapi.dll")]
        private static extern int DwmGetWindowAttribute(IntPtr hWnd, uint attribute, out Rect value, int size);

        [DllImport("dwmapi.dll")]
        private static extern int DwmGetWindowAttribute(IntPtr hWnd, uint attribute, out int value, int size);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandle(string moduleName);

        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string procedureName);

        [DllImport("kernel32.dll")]
        public static extern ushort GetUserDefaultUILanguage();

        private static readonly IsWindowArrangedProc IsWindowArranged = LoadIsWindowArranged();

        private static IsWindowArrangedProc LoadIsWindowArranged() {
            try {
                IntPtr module = GetModuleHandle("user32.dll");
                IntPtr procedure = module == IntPtr.Zero ? IntPtr.Zero : GetProcAddress(module, "IsWindowArranged");
                if (procedure != IntPtr.Zero) {
                    return (IsWindowArrangedProc)Marshal.GetDelegateForFunctionPointer(procedure, typeof(IsWindowArrangedProc));
                }
            }
            catch {
            }

            return null;
        }

        public static bool IsWindowArrangedSafe(IntPtr hWnd) {
            try {
                return IsWindowArranged != null && IsWindowArranged(hWnd);
            }
            catch {
                return false;
            }
        }

        private static bool IsCloaked(IntPtr hWnd) {
            try {
                int cloaked;
                return DwmGetWindowAttribute(hWnd, DwmwaCloaked, out cloaked, sizeof(int)) == 0 && cloaked != 0;
            }
            catch {
                return false;
            }
        }

        private static bool TryGetBounds(IntPtr hWnd, out Rect bounds) {
            try {
                if (DwmGetWindowAttribute(hWnd, DwmwaExtendedFrameBounds, out bounds, Marshal.SizeOf(typeof(Rect))) == 0 &&
                    bounds.Right > bounds.Left && bounds.Bottom > bounds.Top) {
                    return true;
                }
            }
            catch {
            }

            return GetWindowRect(hWnd, out bounds) && bounds.Right > bounds.Left && bounds.Bottom > bounds.Top;
        }

        private static double GetVisibleFraction(Rect bounds, List<Rect> higherBounds) {
            long area = (long)(bounds.Right - bounds.Left) * (bounds.Bottom - bounds.Top);
            if (area <= 0 || higherBounds.Count == 0) {
                return 1.0;
            }

            List<Rect> visible = new List<Rect>();
            visible.Add(bounds);
            foreach (Rect higher in higherBounds) {
                List<Rect> remaining = new List<Rect>();
                foreach (Rect current in visible) {
                    int left = Math.Max(current.Left, higher.Left);
                    int top = Math.Max(current.Top, higher.Top);
                    int right = Math.Min(current.Right, higher.Right);
                    int bottom = Math.Min(current.Bottom, higher.Bottom);
                    if (right <= left || bottom <= top) {
                        remaining.Add(current);
                        continue;
                    }

                    if (current.Top < top) {
                        remaining.Add(new Rect { Left = current.Left, Top = current.Top, Right = current.Right, Bottom = top });
                    }
                    if (bottom < current.Bottom) {
                        remaining.Add(new Rect { Left = current.Left, Top = bottom, Right = current.Right, Bottom = current.Bottom });
                    }
                    if (current.Left < left) {
                        remaining.Add(new Rect { Left = current.Left, Top = top, Right = left, Bottom = bottom });
                    }
                    if (right < current.Right) {
                        remaining.Add(new Rect { Left = right, Top = top, Right = current.Right, Bottom = bottom });
                    }
                }

                visible = remaining;
                if (visible.Count == 0) {
                    return 0.0;
                }
            }

            long visibleArea = 0;
            foreach (Rect current in visible) {
                visibleArea += (long)(current.Right - current.Left) * (current.Bottom - current.Top);
            }
            return visibleArea / (double)area;
        }

        public static IntPtr[] GetSnapGroupWindows(IntPtr target, int maximumCount) {
            if (target == IntPtr.Zero || maximumCount < 1 || !IsWindowArrangedSafe(target)) {
                return target == IntPtr.Zero ? new IntPtr[0] : new IntPtr[] { target };
            }

            IntPtr targetMonitor = MonitorFromWindow(target, MonitorDefaultToNearest);
            List<WindowEntry> candidates = new List<WindowEntry>();
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
                if (!IsWindowVisible(hWnd) || IsIconic(hWnd) || IsCloaked(hWnd) ||
                    !IsWindowArrangedSafe(hWnd) || MonitorFromWindow(hWnd, MonitorDefaultToNearest) != targetMonitor) {
                    return true;
                }

                Rect bounds;
                if (TryGetBounds(hWnd, out bounds)) {
                    WindowEntry entry = new WindowEntry();
                    entry.Handle = hWnd;
                    entry.Bounds = bounds;
                    candidates.Add(entry);
                }
                return true;
            }, IntPtr.Zero);

            int targetIndex = candidates.FindIndex(delegate(WindowEntry entry) { return entry.Handle == target; });
            if (targetIndex < 0) {
                return new IntPtr[] { target };
            }

            List<IntPtr> selected = new List<IntPtr>();
            List<Rect> higherBounds = new List<Rect>();
            for (int index = 0; index < candidates.Count; index++) {
                WindowEntry candidate = candidates[index];
                double visibleFraction = GetVisibleFraction(candidate.Bounds, higherBounds);
                higherBounds.Add(candidate.Bounds);

                if (index < targetIndex) {
                    continue;
                }
                if (index > targetIndex && visibleFraction < 0.90) {
                    break;
                }

                selected.Add(candidate.Handle);
                if (selected.Count == maximumCount) {
                    break;
                }
            }

            return selected.Count == 0 ? new IntPtr[] { target } : selected.ToArray();
        }
    }
}
"@
}

try {
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch {
    # A redirected hook process can run without an attached console.
}

function ConvertTo-ToastText {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [int]$MaxLength
    )

    if ($MaxLength -lt 4) {
        throw "MaxLength must be at least 4."
    }

    $xmlText = New-Object Text.StringBuilder
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $unit = $Text[$index]
        if ([char]::IsHighSurrogate($unit)) {
            if ($index + 1 -lt $Text.Length -and [char]::IsLowSurrogate($Text[$index + 1])) {
                [void]$xmlText.Append($unit)
                [void]$xmlText.Append($Text[$index + 1])
                $index++
            }
            continue
        }

        if ([char]::IsLowSurrogate($unit)) {
            continue
        }

        $value = [int]$unit
        if ($value -eq 0x9 -or $value -eq 0xA -or $value -eq 0xD -or
            ($value -ge 0x20 -and $value -le 0xD7FF) -or
            ($value -ge 0xE000 -and $value -le 0xFFFD)) {
            [void]$xmlText.Append($unit)
        }
    }

    $singleLine = [regex]::Replace($xmlText.ToString(), "\s+", " ").Trim()
    $elementStarts = [Globalization.StringInfo]::ParseCombiningCharacters($singleLine)
    if ($elementStarts.Count -le $MaxLength) {
        return $singleLine
    }

    return $singleLine.Substring(0, $elementStarts[$MaxLength - 3]) + "..."
}

function Get-ToastAppId {
    $startApps = @(Get-StartApps -ErrorAction SilentlyContinue)
    foreach ($preferredName in @("ChatGPT", "Codex", "Windows Terminal", "PowerShell", "Windows PowerShell")) {
        $candidate = $startApps | Where-Object Name -EQ $preferredName | Select-Object -First 1
        if ($null -ne $candidate) {
            return $candidate.AppID
        }
    }

    return $null
}

function Get-WindowsUserUICultureName {
    try {
        $languageId = [CodexWindowsToast.WindowCapture]::GetUserDefaultUILanguage()
        if ($languageId -ne 0) {
            return ([Globalization.CultureInfo]::GetCultureInfo([int]$languageId)).Name
        }
    }
    catch {
    }

    try {
        $cultureName = [Globalization.CultureInfo]::CurrentCulture.Name
        if (-not [string]::IsNullOrWhiteSpace($cultureName)) {
            return $cultureName
        }
    }
    catch {
    }

    return "en"
}

function Get-ToastActionLabels {
    param(
        [string]$CultureName = (Get-WindowsUserUICultureName)
    )

    try {
        $language = ([Globalization.CultureInfo]::GetCultureInfo($CultureName)).TwoLetterISOLanguageName.ToLowerInvariant()
    }
    catch {
        $language = "en"
    }

    switch ($language) {
        "ar" { return @{ Return = "&#x0631;&#x062C;&#x0648;&#x0639;"; Dismiss = "&#x0625;&#x063A;&#x0644;&#x0627;&#x0642;" } }
        "cs" { return @{ Return = "Zp&#x011B;t"; Dismiss = "Zav&#x0159;&#x00ED;t" } }
        "da" { return @{ Return = "Tilbage"; Dismiss = "Luk" } }
        "de" { return @{ Return = "Zur&#x00FC;ck"; Dismiss = "Schlie&#x00DF;en" } }
        "es" { return @{ Return = "Volver"; Dismiss = "Cerrar" } }
        "fi" { return @{ Return = "Takaisin"; Dismiss = "Sulje" } }
        "fr" { return @{ Return = "Retour"; Dismiss = "Fermer" } }
        "he" { return @{ Return = "&#x05D7;&#x05D6;&#x05E8;&#x05D4;"; Dismiss = "&#x05E1;&#x05D2;&#x05D5;&#x05E8;" } }
        "hi" { return @{ Return = "&#x0935;&#x093E;&#x092A;&#x0938;"; Dismiss = "&#x092C;&#x0902;&#x0926;" } }
        "id" { return @{ Return = "Kembali"; Dismiss = "Tutup" } }
        "it" { return @{ Return = "Indietro"; Dismiss = "Chiudi" } }
        "ja" { return @{ Return = "&#x623B;&#x308B;"; Dismiss = "&#x9589;&#x3058;&#x308B;" } }
        "ko" { return @{ Return = "&#xB3CC;&#xC544;&#xAC00;&#xAE30;"; Dismiss = "&#xB2EB;&#xAE30;" } }
        "nb" { return @{ Return = "Tilbake"; Dismiss = "Lukk" } }
        "nl" { return @{ Return = "Terug"; Dismiss = "Sluiten" } }
        "no" { return @{ Return = "Tilbake"; Dismiss = "Lukk" } }
        "pl" { return @{ Return = "Wr&#x00F3;&#x0107;"; Dismiss = "Zamknij" } }
        "pt" { return @{ Return = "Voltar"; Dismiss = "Fechar" } }
        "ru" { return @{ Return = "&#x041D;&#x0430;&#x0437;&#x0430;&#x0434;"; Dismiss = "&#x0417;&#x0430;&#x043A;&#x0440;&#x044B;&#x0442;&#x044C;" } }
        "sv" { return @{ Return = "Tillbaka"; Dismiss = "St&#x00E4;ng" } }
        "th" { return @{ Return = "&#x0E01;&#x0E25;&#x0E31;&#x0E1A;"; Dismiss = "&#x0E1B;&#x0E34;&#x0E14;" } }
        "tr" { return @{ Return = "D&#x00F6;n"; Dismiss = "Kapat" } }
        "uk" { return @{ Return = "&#x041D;&#x0430;&#x0437;&#x0430;&#x0434;"; Dismiss = "&#x0417;&#x0430;&#x043A;&#x0440;&#x0438;&#x0442;&#x0438;" } }
        "vi" { return @{ Return = "Quay l&#x1EA1;i"; Dismiss = "B&#x1ECF; qua" } }
        "zh" { return @{ Return = "&#x8FD4;&#x56DE;"; Dismiss = "&#x5FFD;&#x7565;" } }
        default { return @{ Return = "Return"; Dismiss = "Dismiss" } }
    }
}

function Get-PluginDataPath {
    $pluginData = [Environment]::GetEnvironmentVariable("PLUGIN_DATA")
    if ([string]::IsNullOrWhiteSpace($pluginData)) {
        return Join-Path ([IO.Path]::GetTempPath()) "codex-windows-toast"
    }

    return $pluginData
}

function Get-SessionStatePath {
    param([string]$SessionId)

    $safeSessionId = [regex]::Replace($SessionId, "[^A-Za-z0-9._-]", "_")
    if ([string]::IsNullOrWhiteSpace($safeSessionId)) {
        $safeSessionId = "unknown-session"
    }

    return Join-Path (Get-PluginDataPath) "turn-$safeSessionId.json"
}

function Get-WindowTarget {
    param([Parameter(Mandatory)][IntPtr]$Window)

    try {
        [uint32]$processId = 0
        [void][CodexWindowsToast.WindowCapture]::GetWindowThreadProcessId($Window, [ref]$processId)
        if ($processId -eq 0) {
            return $null
        }

        $process = Get-Process -Id $processId -ErrorAction Stop
        return [pscustomobject]@{
            hwnd = $Window.ToInt64()
            pid = [long]$processId
            started_utc_ticks = $process.StartTime.ToUniversalTime().Ticks
        }
    }
    catch {
        return $null
    }
}

function Get-ForegroundWindowTargets {
    try {
        $window = [CodexWindowsToast.WindowCapture]::GetForegroundWindow()
        if ($window -eq [IntPtr]::Zero) {
            return
        }

        $rootWindow = [CodexWindowsToast.WindowCapture]::GetAncestor($window, 2)
        if ($rootWindow -ne [IntPtr]::Zero) {
            $window = $rootWindow
        }

        $windows = [CodexWindowsToast.WindowCapture]::GetSnapGroupWindows($window, 8)
        for ($index = 0; $index -lt $windows.Count; $index++) {
            $target = Get-WindowTarget -Window $windows[$index]
            if ($null -eq $target) {
                if ($index -eq 0) {
                    return
                }
                continue
            }

            Write-Output $target
        }
    }
    catch {
        return
    }
}

function Write-HookStatus {
    param(
        [string]$EventName,
        [string]$SessionId,
        [string]$TurnId,
        [string]$Result,
        [AllowEmptyString()]
        [string]$ErrorMessage = ""
    )

    try {
        $pluginData = Get-PluginDataPath
        New-Item -ItemType Directory -Path $pluginData -Force | Out-Null
        [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString("o")
            event = $EventName
            session_id = $SessionId
            turn_id = $TurnId
            result = $Result
            error = $ErrorMessage
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $pluginData "last-hook-status.json") -Encoding UTF8
    }
    catch {
        # Diagnostics must never interfere with Codex.
    }
}

function Send-CodexToast {
    param(
        [string]$Title,
        [string]$Message,
        [AllowEmptyString()]
        [string]$ActivationUri = ""
    )

    $appId = Get-ToastAppId
    if ([string]::IsNullOrWhiteSpace($appId)) {
        throw "No Windows application identity is available for toast notifications."
    }

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $escapedTitle = [System.Security.SecurityElement]::Escape($Title)
    $escapedMessage = [System.Security.SecurityElement]::Escape($Message)
    $actionsXml = ""
    $toastAttributes = 'duration="long"'
    if (-not [string]::IsNullOrWhiteSpace($ActivationUri)) {
        $escapedActivationUri = [System.Security.SecurityElement]::Escape($ActivationUri)
        $ignoredUri = [System.Security.SecurityElement]::Escape("${script:CodexToastProtocol}://ignore")
        $actionLabels = Get-ToastActionLabels
        $toastAttributes += " launch=`"$ignoredUri`" activationType=`"protocol`""
        $actionsXml = @"
    <actions>
      <action content="$($actionLabels.Return)" arguments="$escapedActivationUri" activationType="protocol" />
      <action content="$($actionLabels.Dismiss)" arguments="dismiss" activationType="system" />
    </actions>
"@
    }

    $toastXml = @"
<toast $toastAttributes>
  <visual>
    <binding template="ToastGeneric">
      <text>$escapedTitle</text>
      <text>$escapedMessage</text>
      <text placement="attribution">Codex CLI</text>
    </binding>
  </visual>
$actionsXml
  <audio src="ms-winsoundevent:Notification.Default" />
</toast>
"@

    $xmlDocument = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xmlDocument.LoadXml($toastXml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xmlDocument
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
}

try {
    if ($Test) {
        $activationUri = ""
        $targets = @(Get-ForegroundWindowTargets)
        $activationContext = Get-CodexToastActivationContext
        if ($targets.Count -gt 0 -and $activationContext.Installed -and $activationContext.Current) {
            try {
                $activationUri = New-CodexToastActivationUri -Targets $targets -Context $activationContext
            }
            catch {
                $activationUri = ""
            }
        }

        Send-CodexToast -Title "Codex is ready" -Message "Windows toast notifications are working." -ActivationUri $activationUri
    }
    else {
        $rawInput = [Console]::In.ReadToEnd()
        if ($rawInput.Length -gt 0 -and [int]$rawInput[0] -eq 0xFEFF) {
            $rawInput = $rawInput.Substring(1)
        }
        $hookInput = $rawInput | ConvertFrom-Json
        $eventName = [string]$hookInput.hook_event_name
        $sessionId = [string]$hookInput.session_id
        $turnId = [string]$hookInput.turn_id

        if ($eventName -eq "UserPromptSubmit") {
            $pluginData = Get-PluginDataPath
            New-Item -ItemType Directory -Path $pluginData -Force | Out-Null
            $targets = @(Get-ForegroundWindowTargets)
            $turnState = [ordered]@{
                turn_id = $turnId
                title = ConvertTo-ToastText -Text ([string]$hookInput.prompt) -MaxLength 120
            }
            if ($targets.Count -gt 0) {
                $turnState.targets = $targets
            }

            $turnState | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Get-SessionStatePath -SessionId $sessionId) -Encoding UTF8
            Write-HookStatus -EventName $eventName -SessionId $sessionId -TurnId $turnId -Result "prompt-saved"
            [Console]::Out.WriteLine('{"continue":true}')
            exit 0
        }

        if ($eventName -ne "Stop") {
            [Console]::Out.WriteLine('{"continue":true}')
            exit 0
        }

        $title = ""
        $activationUri = ""
        $statePath = Get-SessionStatePath -SessionId $sessionId
        if (Test-Path -LiteralPath $statePath) {
            $turnState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
            if ([string]$turnState.turn_id -eq $turnId -and -not [string]::IsNullOrWhiteSpace([string]$turnState.title)) {
                $title = [string]$turnState.title

                $activationContext = Get-CodexToastActivationContext
                $targets = @($turnState.targets)
                if ($targets.Count -eq 0 -and
                    [long]$turnState.hwnd -gt 0 -and [long]$turnState.pid -gt 0 -and
                    [long]$turnState.started_utc_ticks -gt 0) {
                    $targets = @([pscustomobject]@{
                        hwnd = [long]$turnState.hwnd
                        pid = [long]$turnState.pid
                        started_utc_ticks = [long]$turnState.started_utc_ticks
                    })
                }
                if ($activationContext.Installed -and $activationContext.Current -and $targets.Count -gt 0) {
                    try {
                        $activationUri = New-CodexToastActivationUri -Targets $targets -Context $activationContext
                    }
                    catch {
                        $activationUri = ""
                    }
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($title)) {
            if (Test-Path -LiteralPath $statePath -PathType Leaf) {
                Remove-Item -LiteralPath $statePath -Force
            }
            Write-HookStatus -EventName $eventName -SessionId $sessionId -TurnId $turnId -Result "skipped-no-prompt"
            [Console]::Out.WriteLine('{"continue":true}')
            exit 0
        }

        $message = ConvertTo-ToastText -Text ([string]$hookInput.last_assistant_message) -MaxLength 240
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "The current turn has finished."
        }

        Send-CodexToast -Title $title -Message $message -ActivationUri $activationUri
        Write-HookStatus -EventName $eventName -SessionId $sessionId -TurnId $turnId -Result "toast-sent"
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            Remove-Item -LiteralPath $statePath -Force
        }
    }
}
catch {
    if ($Test) {
        Write-Error $_
        exit 1
    }

    Write-HookStatus -EventName $eventName -SessionId $sessionId -TurnId $turnId -Result "error" -ErrorMessage $_.Exception.Message
}

if ($Test) {
    Write-Output "Toast sent."
}
else {
    [Console]::Out.WriteLine('{"continue":true}')
}
