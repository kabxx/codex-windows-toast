[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$ActivationUri
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "activation-common.ps1")

if (-not ("CodexWindowsToast.WindowActivator" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace CodexWindowsToast {
    public static class WindowActivator {
        private const uint MonitorDefaultToNearest = 2;

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindowAsync(IntPtr hWnd, int command);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);

        public static IntPtr GetWindowMonitor(IntPtr hWnd) {
            return MonitorFromWindow(hWnd, MonitorDefaultToNearest);
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private delegate bool IsWindowArrangedProc(IntPtr hWnd);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandle(string moduleName);

        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string procedureName);

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
    }
}
"@
}

function ConvertFrom-CodexToastQuery {
    param([Uri]$Uri)

    $values = @{}
    foreach ($pair in $Uri.Query.TrimStart("?").Split("&")) {
        $parts = $pair.Split("=", 2)
        if ($parts.Count -ne 2 -or $values.ContainsKey($parts[0])) {
            throw "Malformed activation query."
        }

        $values[$parts[0]] = [Uri]::UnescapeDataString($parts[1])
    }

    $expectedNames = @("v", "targets", "sig")
    if ($values.Count -ne $expectedNames.Count -or @($expectedNames | Where-Object { -not $values.ContainsKey($_) }).Count -ne 0) {
        throw "Unexpected activation query fields."
    }

    return $values
}

try {
    $uri = [Uri]$ActivationUri
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne $script:CodexToastProtocol) {
        throw "Invalid activation URI."
    }

    if ($uri.Host -ceq "ignore" -and $uri.AbsolutePath -eq "/" -and [string]::IsNullOrEmpty($uri.Query)) {
        exit 0
    }

    if ($uri.Host -cne "activate" -or $uri.AbsolutePath -ne "/") {
        throw "Invalid activation URI."
    }

    $query = ConvertFrom-CodexToastQuery -Uri $uri
    if ($query.v -cne "2" -or $query.sig -notmatch "^[0-9a-f]{64}$") {
        throw "Invalid activation values."
    }
    $targets = @(ConvertFrom-CodexToastActivationTargets -Value $query.targets)

    $context = Get-CodexToastActivationContext
    if (-not $context.Installed) {
        throw $context.Error
    }

    $serializedTargets = ConvertTo-CodexToastActivationTargets -Targets $targets
    $payload = "v=2&targets=$serializedTargets"
    $secret = Get-CodexToastSecret -Path $context.SecretPath
    try {
        $expectedSignature = Get-CodexToastHmacHex -Key $secret -Payload $payload
    }
    finally {
        [Array]::Clear($secret, 0, $secret.Length)
    }

    if (-not (Test-CodexToastSignature -Expected $expectedSignature -Actual $query.sig)) {
        throw "Invalid activation signature."
    }

    $primary = $targets[0]
    $window = [IntPtr]([long]$primary.hwnd)
    $processId = [uint32]$primary.pid
    if (-not [CodexWindowsToast.WindowActivator]::IsWindow($window)) {
        Write-CodexToastActivationStatus -Result "target-missing"
        exit 0
    }

    [uint32]$windowProcessId = 0
    [void][CodexWindowsToast.WindowActivator]::GetWindowThreadProcessId($window, [ref]$windowProcessId)
    if ($windowProcessId -ne $processId) {
        Write-CodexToastActivationStatus -Result "target-changed"
        exit 0
    }

    $process = Get-Process -Id $processId -ErrorAction Stop
    if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$primary.started_utc_ticks) {
        Write-CodexToastActivationStatus -Result "target-changed"
        exit 0
    }

    $windows = @($window)
    if ([CodexWindowsToast.WindowActivator]::IsWindowArrangedSafe($window)) {
        $primaryMonitor = [CodexWindowsToast.WindowActivator]::GetWindowMonitor($window)
        foreach ($target in @($targets | Select-Object -Skip 1)) {
            try {
                $candidate = [IntPtr]([long]$target.hwnd)
                if (-not [CodexWindowsToast.WindowActivator]::IsWindow($candidate) -or
                    -not [CodexWindowsToast.WindowActivator]::IsWindowArrangedSafe($candidate) -or
                    [CodexWindowsToast.WindowActivator]::GetWindowMonitor($candidate) -ne $primaryMonitor) {
                    continue
                }

                [uint32]$candidateProcessId = 0
                [void][CodexWindowsToast.WindowActivator]::GetWindowThreadProcessId($candidate, [ref]$candidateProcessId)
                if ($candidateProcessId -ne [uint32]$target.pid) {
                    continue
                }

                $candidateProcess = Get-Process -Id $candidateProcessId -ErrorAction Stop
                if ($candidateProcess.StartTime.ToUniversalTime().Ticks -ne [long]$target.started_utc_ticks) {
                    continue
                }

                $windows += $candidate
            }
            catch {
                continue
            }
        }
    }

    $retryIntervalMilliseconds = 50
    $restoreTimeoutMilliseconds = 500
    $activationTimeoutMilliseconds = 1000

    $restoreRequested = $false
    foreach ($candidate in $windows) {
        if ([CodexWindowsToast.WindowActivator]::IsIconic($candidate)) {
            [void][CodexWindowsToast.WindowActivator]::ShowWindowAsync($candidate, 9)
            $restoreRequested = $true
        }
    }
    if ($restoreRequested) {
        $restoreTimer = [Diagnostics.Stopwatch]::StartNew()
        while ($restoreTimer.ElapsedMilliseconds -lt $restoreTimeoutMilliseconds) {
            $stillMinimized = $false
            foreach ($candidate in $windows) {
                if ([CodexWindowsToast.WindowActivator]::IsIconic($candidate)) {
                    $stillMinimized = $true
                    break
                }
            }

            if (-not $stillMinimized) {
                break
            }
            Start-Sleep -Milliseconds $retryIntervalMilliseconds
        }
    }

    if ($windows.Count -gt 1) {
        try {
            for ($index = $windows.Count - 1; $index -ge 0; $index--) {
                [void][CodexWindowsToast.WindowActivator]::SetWindowPos($windows[$index], [IntPtr](-1), 0, 0, 0, 0, 0x13)
            }
        }
        finally {
            for ($index = $windows.Count - 1; $index -ge 0; $index--) {
                [void][CodexWindowsToast.WindowActivator]::SetWindowPos($windows[$index], [IntPtr](-2), 0, 0, 0, 0, 0x13)
            }
        }
    }

    $activated = [CodexWindowsToast.WindowActivator]::GetForegroundWindow() -eq $window
    $requested = $false
    $activationTimer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $activated -and $activationTimer.ElapsedMilliseconds -lt $activationTimeoutMilliseconds) {
        if ([CodexWindowsToast.WindowActivator]::SetForegroundWindow($window)) {
            $requested = $true
        }
        $activated = [CodexWindowsToast.WindowActivator]::GetForegroundWindow() -eq $window
        if (-not $activated) {
            Start-Sleep -Milliseconds $retryIntervalMilliseconds
            $activated = [CodexWindowsToast.WindowActivator]::GetForegroundWindow() -eq $window
        }
    }

    if ($activated) {
        $result = if ($windows.Count -gt 1) { "group-activated" } else { "activated" }
        Write-CodexToastActivationStatus -Result $result
    }
    elseif ($requested) {
        Write-CodexToastActivationStatus -Result "activation-requested" -Detail "Windows did not switch to the target window."
    }
    else {
        Write-CodexToastActivationStatus -Result "activation-blocked" -Detail "Windows rejected the foreground request."
    }
}
catch {
    Write-CodexToastActivationStatus -Result "invalid-request" -Detail $_.Exception.Message
}

exit 0
