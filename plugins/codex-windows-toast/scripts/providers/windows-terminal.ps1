$script:CodexToastWindowsTerminalCaptureTimeoutMilliseconds = 1500
$script:CodexToastWindowsTerminalActivationTimeoutMilliseconds = 1500
$script:CodexToastWindowsTerminalMaximumOutputBytes = 16384

function ConvertTo-CodexToastAutomationRuntimeId {
    param(
        [AllowNull()]$Value,
        [switch]$AllowEmpty
    )

    $items = @($Value)
    if ($items.Count -gt 64 -or ($items.Count -eq 0 -and -not $AllowEmpty)) {
        throw "Invalid UI Automation runtime ID."
    }

    $normalized = @()
    foreach ($item in $items) {
        $text = [string]$item
        [int]$parsed = 0
        if ($text -notmatch "^(0|[1-9][0-9]{0,9}|-[1-9][0-9]{0,9})$" -or
            -not [int]::TryParse($text, [ref]$parsed)) {
            throw "Invalid UI Automation runtime ID."
        }
        $normalized += $parsed
    }
    return $normalized
}

function ConvertFrom-CodexToastWindowsTerminalLocator {
    param([Parameter(Mandatory)]$Value)

    if (-not (Test-CodexToastObjectShape `
        -Value $Value `
        -PropertyNames @("session_guid", "tab_runtime_id", "pane_runtime_id"))) {
        throw "Invalid Windows Terminal locator."
    }

    [Guid]$sessionGuid = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$Value.session_guid, [ref]$sessionGuid) -or
        $sessionGuid -eq [Guid]::Empty) {
        throw "Invalid Windows Terminal locator."
    }

    $tabRuntimeId = @(ConvertTo-CodexToastAutomationRuntimeId -Value $Value.tab_runtime_id)
    $paneRuntimeId = @(ConvertTo-CodexToastAutomationRuntimeId -Value $Value.pane_runtime_id -AllowEmpty)
    return [pscustomobject][ordered]@{
        session_guid = $sessionGuid.ToString("D")
        tab_runtime_id = @($tabRuntimeId)
        pane_runtime_id = @($paneRuntimeId)
    }
}

function Invoke-CodexToastWindowsTerminalWorker {
    param(
        [Parameter(Mandatory)][ValidateSet("capture", "activate")][string]$Mode,
        [Parameter(Mandatory)]$Target,
        [int[]]$TabRuntimeId = @(),
        [int[]]$PaneRuntimeId = @(),
        [Parameter(Mandatory)][ValidateRange(1, 5000)][int]$TimeoutMilliseconds
    )

    $workerPath = Join-Path $PSScriptRoot "windows-terminal-uia.ps1"
    $powerShellPath = Join-Path `
        ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) `
        "WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
        return $null
    }

    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$workerPath`"" +
        " -Mode $Mode -Hwnd $([long]$Target.hwnd) -ProcessId $([int]$Target.pid)" +
        " -StartedUtcTicks $([long]$Target.started_utc_ticks)"
    if ($Mode -ceq "activate") {
        $arguments += " -TabRuntimeId `"$($TabRuntimeId -join ',')`""
        if ($PaneRuntimeId.Count -gt 0) {
            $arguments += " -PaneRuntimeId `"$($PaneRuntimeId -join ',')`""
        }
    }

    $result = Invoke-CodexToastTerminalProcess `
        -FilePath $powerShellPath `
        -Arguments $arguments `
        -TimeoutMilliseconds $TimeoutMilliseconds
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or
        [Text.Encoding]::UTF8.GetByteCount($result.StandardOutput) -gt $script:CodexToastWindowsTerminalMaximumOutputBytes) {
        return $null
    }

    try {
        $value = $result.StandardOutput | ConvertFrom-Json
        if (-not (Test-CodexToastObjectShape `
            -Value $value `
            -PropertyNames @("status", "detail", "tab_runtime_id", "pane_runtime_id")) -or
            [string]$value.status -cnotin @("captured", "activated", "stale", "failed")) {
            return $null
        }
        return $value
    }
    catch {
        return $null
    }
}

function Get-CodexToastWindowsTerminalCapture {
    param(
        [Parameter(Mandatory)]$Target,
        [DateTime]$DeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(1500)
    )

    [Guid]$sessionGuid = [Guid]::Empty
    if (-not [Guid]::TryParse(
        [Environment]::GetEnvironmentVariable("WT_SESSION", "Process"),
        [ref]$sessionGuid
    ) -or $sessionGuid -eq [Guid]::Empty -or
        $null -eq (Get-CodexToastValidatedTargetProcess `
            -Target $Target `
            -ExpectedExecutableNames @("WindowsTerminal.exe"))) {
        return $null
    }

    $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
        -DeadlineUtc $DeadlineUtc `
        -MaximumMilliseconds $script:CodexToastWindowsTerminalCaptureTimeoutMilliseconds
    if ($timeout -le 0) {
        return $null
    }
    $capture = Invoke-CodexToastWindowsTerminalWorker `
        -Mode "capture" `
        -Target $Target `
        -TimeoutMilliseconds $timeout
    if ($null -eq $capture -or [string]$capture.status -cne "captured") {
        return $null
    }

    try {
        $locator = ConvertFrom-CodexToastWindowsTerminalLocator -Value ([pscustomobject]@{
            session_guid = $sessionGuid.ToString("D")
            tab_runtime_id = @($capture.tab_runtime_id)
            pane_runtime_id = @($capture.pane_runtime_id)
        })
    }
    catch {
        return $null
    }

    return [pscustomobject][ordered]@{
        provider = "windows-terminal"
        version = 1
        locator = $locator
    }
}

function Invoke-CodexToastWindowsTerminalActivation {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Target
    )

    if ([int]$Context.version -ne 1) {
        return New-CodexToastTerminalResult -Status "unsupported" -Provider "windows-terminal"
    }
    try {
        $locator = ConvertFrom-CodexToastWindowsTerminalLocator -Value $Context.locator
    }
    catch {
        return New-CodexToastTerminalResult -Status "failed" -Provider "windows-terminal" -Detail "invalid-locator"
    }
    if ($null -eq (Get-CodexToastValidatedTargetProcess `
        -Target $Target `
        -ExpectedExecutableNames @("WindowsTerminal.exe"))) {
        return New-CodexToastTerminalResult -Status "stale" -Provider "windows-terminal"
    }

    $activation = Invoke-CodexToastWindowsTerminalWorker `
        -Mode "activate" `
        -Target $Target `
        -TabRuntimeId @($locator.tab_runtime_id) `
        -PaneRuntimeId @($locator.pane_runtime_id) `
        -TimeoutMilliseconds $script:CodexToastWindowsTerminalActivationTimeoutMilliseconds
    if ($null -eq $activation) {
        return New-CodexToastTerminalResult -Status "failed" -Provider "windows-terminal" -Detail "uia-timeout"
    }
    if ([string]$activation.status -ceq "stale") {
        return New-CodexToastTerminalResult -Status "stale" -Provider "windows-terminal"
    }
    if ([string]$activation.status -cne "activated" -or
        [string]$activation.detail -cnotin @("tab-only", "tab-pane")) {
        return New-CodexToastTerminalResult -Status "failed" -Provider "windows-terminal" -Detail ([string]$activation.detail)
    }
    return New-CodexToastTerminalResult `
        -Status "activated" `
        -Provider "windows-terminal" `
        -Detail ([string]$activation.detail)
}
