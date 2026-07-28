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
        public static extern IntPtr GetForegroundWindow();
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

    $expectedNames = @("v", "hwnd", "pid", "started", "sig")
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
    if ($query.v -cne "1" -or
        $query.hwnd -notmatch "^[1-9][0-9]{0,18}$" -or
        $query.pid -notmatch "^[1-9][0-9]{0,9}$" -or
        $query.started -notmatch "^[1-9][0-9]{0,18}$" -or
        $query.sig -notmatch "^[0-9a-f]{64}$") {
        throw "Invalid activation values."
    }

    $context = Get-CodexToastActivationContext
    if (-not $context.Installed) {
        throw $context.Error
    }

    $payload = "v=1&hwnd=$($query.hwnd)&pid=$($query.pid)&started=$($query.started)"
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

    $window = [IntPtr]([long]$query.hwnd)
    $processId = [uint32]$query.pid
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
    if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$query.started) {
        Write-CodexToastActivationStatus -Result "target-changed"
        exit 0
    }

    if ([CodexWindowsToast.WindowActivator]::IsIconic($window)) {
        [void][CodexWindowsToast.WindowActivator]::ShowWindowAsync($window, 9)
    }

    $requested = [CodexWindowsToast.WindowActivator]::SetForegroundWindow($window)
    Start-Sleep -Milliseconds 150
    $activated = [CodexWindowsToast.WindowActivator]::GetForegroundWindow() -eq $window
    if ($activated) {
        Write-CodexToastActivationStatus -Result "activated"
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
