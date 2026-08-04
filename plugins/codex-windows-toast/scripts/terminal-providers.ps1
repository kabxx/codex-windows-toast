$script:CodexToastTerminalProviderStatuses = @("activated", "unsupported", "stale", "failed")
$script:CodexToastTerminalProviderRoot = Join-Path $PSScriptRoot "providers"
$script:CodexToastTerminalCaptureBudgetMilliseconds = 3000

. (Join-Path $script:CodexToastTerminalProviderRoot "wezterm.ps1")
. (Join-Path $script:CodexToastTerminalProviderRoot "windows-terminal.ps1")
. (Join-Path $script:CodexToastTerminalProviderRoot "tmux.ps1")

function Test-CodexToastObjectShape {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string[]]$PropertyNames
    )

    if ($null -eq $Value) {
        return $false
    }

    $actualNames = @($Value.PSObject.Properties.Name)
    if ($actualNames.Count -ne $PropertyNames.Count) {
        return $false
    }

    return @($PropertyNames | Where-Object { $_ -cnotin $actualNames }).Count -eq 0
}

function Get-CodexToastValidatedTargetProcess {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string[]]$ExpectedExecutableNames
    )

    try {
        if ([long]$Target.pid -le 0 -or [long]$Target.started_utc_ticks -le 0) {
            return $null
        }

        $process = Get-Process -Id ([int]$Target.pid) -ErrorAction Stop
        if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$Target.started_utc_ticks -or
            [string]::IsNullOrWhiteSpace([string]$process.Path)) {
            return $null
        }

        $executableName = [IO.Path]::GetFileName([string]$process.Path)
        if ($executableName -notin $ExpectedExecutableNames) {
            return $null
        }

        return $process
    }
    catch {
        return $null
    }
}

function Invoke-CodexToastTerminalProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [hashtable]$Environment = @{},
        [ValidateRange(1, 5000)][int]$TimeoutMilliseconds = 1000
    )

    if (-not [IO.Path]::IsPathRooted($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Terminal provider executable is unavailable."
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($name in $Environment.Keys) {
        if ([string]$name -notmatch "^[A-Z][A-Z0-9_]{0,63}$") {
            throw "Terminal provider environment name is invalid."
        }
        $startInfo.EnvironmentVariables[[string]$name] = [string]$Environment[$name]
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutMilliseconds)
        if ($timedOut) {
            try {
                $process.Kill()
            }
            catch {
                # The process may have exited between WaitForExit and Kill.
            }
            [void]$process.WaitForExit(250)
            return [pscustomobject]@{
                TimedOut = $true
                ExitCode = -1
                StandardOutput = ""
                StandardError = ""
            }
        }
        $process.WaitForExit()

        return [pscustomobject]@{
            TimedOut = $false
            ExitCode = $process.ExitCode
            StandardOutput = [string]$standardOutput.GetAwaiter().GetResult()
            StandardError = [string]$standardError.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function New-CodexToastTerminalResult {
    param(
        [Parameter(Mandatory)][string]$Status,
        [AllowEmptyString()][string]$Provider = "",
        [AllowEmptyString()][string]$Detail = ""
    )

    if ($Status -cnotin $script:CodexToastTerminalProviderStatuses) {
        throw "Terminal provider returned an invalid status."
    }

    return [pscustomobject]@{
        Status = $Status
        Provider = $Provider
        Detail = $Detail
    }
}

function Get-CodexToastTerminalTimeoutMilliseconds {
    param(
        [Parameter(Mandatory)][DateTime]$DeadlineUtc,
        [Parameter(Mandatory)][ValidateRange(1, 5000)][int]$MaximumMilliseconds
    )

    $remaining = [int][Math]::Floor(($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
    if ($remaining -le 0) {
        return 0
    }
    return [Math]::Min($remaining, $MaximumMilliseconds)
}

function Get-CodexToastTerminalProviders {
    return @(
        [pscustomobject]@{
            Id = "wezterm"
            Layer = "outer"
            Capture = "Get-CodexToastWezTermCapture"
            Activate = "Invoke-CodexToastWezTermActivation"
        }
        [pscustomobject]@{
            Id = "windows-terminal"
            Layer = "outer"
            Capture = "Get-CodexToastWindowsTerminalCapture"
            Activate = "Invoke-CodexToastWindowsTerminalActivation"
        }
        [pscustomobject]@{
            Id = "tmux"
            Layer = "inner"
            Capture = "Get-CodexToastTmuxCapture"
            Activate = "Invoke-CodexToastTmuxActivation"
        }
    )
}

function Get-CodexToastTerminalContext {
    param([Parameter(Mandatory)]$PrimaryTarget)

    $deadlineUtc = [DateTime]::UtcNow.AddMilliseconds($script:CodexToastTerminalCaptureBudgetMilliseconds)
    $outer = $null
    foreach ($provider in @(Get-CodexToastTerminalProviders | Where-Object { $_.Layer -ceq "outer" })) {
        try {
            $captured = @(& ([string]$provider.Capture) -Target $PrimaryTarget -DeadlineUtc $deadlineUtc)
            if ($captured.Count -eq 1 -and $null -ne $captured[0]) {
                $outer = $captured[0]
                break
            }
        }
        catch {
            continue
        }
    }

    if ($null -eq $outer) {
        return $null
    }

    $inner = @()
    foreach ($provider in @(Get-CodexToastTerminalProviders | Where-Object { $_.Layer -ceq "inner" })) {
        try {
            $captured = @(& ([string]$provider.Capture) -Target $PrimaryTarget -DeadlineUtc $deadlineUtc)
            if ($captured.Count -eq 1 -and $null -ne $captured[0]) {
                $inner += $captured[0]
            }
        }
        catch {
            continue
        }
    }

    return [pscustomobject][ordered]@{
        outer = $outer
        inner = @($inner)
    }
}

function Invoke-CodexToastTerminalLayerActivation {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet("outer", "inner")][string]$Layer,
        [Parameter(Mandatory)]$Target
    )

    if (-not (Test-CodexToastObjectShape -Value $Context -PropertyNames @("provider", "version", "locator")) -or
        [string]$Context.provider -notmatch "^[a-z][a-z0-9-]{0,31}$" -or
        [int]$Context.version -le 0) {
        return New-CodexToastTerminalResult -Status "failed" -Detail "invalid-context"
    }

    $provider = @(Get-CodexToastTerminalProviders | Where-Object {
        $_.Id -ceq [string]$Context.provider -and $_.Layer -ceq $Layer
    })
    if ($provider.Count -ne 1) {
        return New-CodexToastTerminalResult -Status "unsupported" -Provider ([string]$Context.provider)
    }

    try {
        $result = @(& ([string]$provider[0].Activate) -Context $Context -Target $Target)
        if ($result.Count -ne 1 -or
            -not (Test-CodexToastObjectShape -Value $result[0] -PropertyNames @("Status", "Provider", "Detail")) -or
            [string]$result[0].Status -cnotin $script:CodexToastTerminalProviderStatuses) {
            return New-CodexToastTerminalResult -Status "failed" -Provider ([string]$Context.provider) -Detail "invalid-result"
        }
        return $result[0]
    }
    catch {
        return New-CodexToastTerminalResult -Status "failed" -Provider ([string]$Context.provider) -Detail "provider-error"
    }
}

function Invoke-CodexToastTerminalActivation {
    param(
        [AllowNull()]$Terminal,
        [Parameter(Mandatory)]$Target
    )

    if ($null -eq $Terminal) {
        return New-CodexToastTerminalResult -Status "unsupported"
    }
    if (-not (Test-CodexToastObjectShape -Value $Terminal -PropertyNames @("outer", "inner"))) {
        return New-CodexToastTerminalResult -Status "failed" -Detail "invalid-context"
    }

    $inner = @($Terminal.inner)
    if ($null -eq $Terminal.outer -or $inner.Count -gt 4) {
        return New-CodexToastTerminalResult -Status "unsupported" -Detail "outer-required"
    }

    $activatedProviders = @()
    $result = Invoke-CodexToastTerminalLayerActivation -Context $Terminal.outer -Layer "outer" -Target $Target
    if ($result.Status -cne "activated") {
        return $result
    }
    $activatedProviders += $result.Provider

    foreach ($context in $inner) {
        $result = Invoke-CodexToastTerminalLayerActivation -Context $context -Layer "inner" -Target $Target
        if ($result.Status -cne "activated") {
            return $result
        }
        $activatedProviders += $result.Provider
    }

    if ($activatedProviders.Count -eq 0) {
        return New-CodexToastTerminalResult -Status "unsupported"
    }
    return New-CodexToastTerminalResult -Status "activated" -Provider ($activatedProviders -join ",")
}
