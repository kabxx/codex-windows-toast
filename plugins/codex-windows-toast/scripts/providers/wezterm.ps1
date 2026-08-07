$script:CodexToastWezTermCaptureTimeoutMilliseconds = 750
$script:CodexToastWezTermActivationTimeoutMilliseconds = 1000
$script:CodexToastWezTermActivationVerificationMilliseconds = 1000

function ConvertFrom-CodexToastWezTermJsonList {
    param([Parameter(Mandatory)][string]$Json)

    $parsed = $Json | ConvertFrom-Json
    foreach ($item in @($parsed)) {
        Write-Output $item
    }
}

function ConvertFrom-CodexToastWezTermLocator {
    param([Parameter(Mandatory)]$Value)

    if (-not (Test-CodexToastObjectShape -Value $Value -PropertyNames @("pane_id", "socket_path", "mux_window_id"))) {
        throw "Invalid WezTerm locator."
    }

    $paneId = [string]$Value.pane_id
    $socketPath = [string]$Value.socket_path
    $muxWindowId = [string]$Value.mux_window_id
    [uint64]$parsed = 0
    if ($paneId -notmatch "^(0|[1-9][0-9]{0,19})$" -or
        -not [uint64]::TryParse($paneId, [ref]$parsed) -or
        $muxWindowId -notmatch "^(0|[1-9][0-9]{0,19})$" -or
        -not [uint64]::TryParse($muxWindowId, [ref]$parsed) -or
        $socketPath.Length -gt 1024 -or
        $socketPath -notmatch "^[A-Za-z]:[\\/][^\x00-\x1f]+$") {
        throw "Invalid WezTerm locator."
    }

    return [pscustomobject][ordered]@{
        pane_id = $paneId
        socket_path = $socketPath
        mux_window_id = $muxWindowId
    }
}

function Get-CodexToastWezTermExecutable {
    param([Parameter(Mandatory)]$Target)

    $process = Get-CodexToastValidatedTargetProcess -Target $Target -ExpectedExecutableNames @("wezterm-gui.exe")
    if ($null -eq $process) {
        return $null
    }

    $executable = Join-Path (Split-Path ([string]$process.Path) -Parent) "wezterm.exe"
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        return $null
    }
    return [IO.Path]::GetFullPath($executable)
}

function Invoke-CodexToastWezTermList {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$SocketPath,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $result = Invoke-CodexToastTerminalProcess `
        -FilePath $Executable `
        -Arguments "cli --no-auto-start list --format json" `
        -Environment @{ WEZTERM_UNIX_SOCKET = $SocketPath } `
        -TimeoutMilliseconds $TimeoutMilliseconds
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or
        [Text.Encoding]::UTF8.GetByteCount($result.StandardOutput) -gt 1048576) {
        return $null
    }

    try {
        return @(ConvertFrom-CodexToastWezTermJsonList -Json $result.StandardOutput)
    }
    catch {
        return $null
    }
}

function Invoke-CodexToastWezTermListClients {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$SocketPath,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $result = Invoke-CodexToastTerminalProcess `
        -FilePath $Executable `
        -Arguments "cli --no-auto-start list-clients --format json" `
        -Environment @{ WEZTERM_UNIX_SOCKET = $SocketPath } `
        -TimeoutMilliseconds $TimeoutMilliseconds
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or
        [Text.Encoding]::UTF8.GetByteCount($result.StandardOutput) -gt 1048576) {
        return $null
    }

    try {
        return @(ConvertFrom-CodexToastWezTermJsonList -Json $result.StandardOutput)
    }
    catch {
        return $null
    }
}

function Resolve-CodexToastWezTermCapturePaneId {
    param(
        [Parameter(Mandatory)][string]$EnvironmentPaneId,
        [Parameter(Mandatory)][string]$FocusedPaneId,
        [Parameter(Mandatory)][bool]$TmuxAttached
    )

    if ($TmuxAttached) {
        return $FocusedPaneId
    }

    return $EnvironmentPaneId
}

function Resolve-CodexToastWezTermOriginProcessId {
    param(
        [Parameter(Mandatory)][object[]]$Clients,
        [Parameter(Mandatory)][string]$EnvironmentPaneId
    )

    $validClients = @($Clients | Where-Object {
        [string]$_.pid -match "^[1-9][0-9]{0,9}$"
    })
    if ($validClients.Count -eq 1) {
        return [long]$validClients[0].pid
    }

    $focusedClients = @($validClients | Where-Object {
        [string]$_.focused_pane_id -ceq $EnvironmentPaneId
    })
    if ($focusedClients.Count -eq 1) {
        return [long]$focusedClients[0].pid
    }

    return $null
}

function Get-CodexToastWezTermOriginProcessId {
    param([DateTime]$DeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(1500))

    if ([Environment]::GetEnvironmentVariable("TERM_PROGRAM", "Process") -ine "WezTerm") {
        return $null
    }

    $paneId = [Environment]::GetEnvironmentVariable("WEZTERM_PANE", "Process")
    $socketPath = [Environment]::GetEnvironmentVariable("WEZTERM_UNIX_SOCKET", "Process")
    try {
        $probe = ConvertFrom-CodexToastWezTermLocator -Value ([pscustomobject]@{
            pane_id = $paneId
            socket_path = $socketPath
            mux_window_id = "0"
        })
    }
    catch {
        return $null
    }

    $guiProcesses = @(Get-Process -Name "wezterm-gui" -ErrorAction SilentlyContinue | Where-Object {
        try {
            -not [string]::IsNullOrWhiteSpace([string]$_.Path)
        }
        catch {
            $false
        }
    })
    $resolvedProcessIds = @()
    foreach ($executablePath in @($guiProcesses | ForEach-Object {
        Join-Path (Split-Path ([string]$_.Path) -Parent) "wezterm.exe"
    } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            continue
        }

        $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
            -DeadlineUtc $DeadlineUtc `
            -MaximumMilliseconds $script:CodexToastWezTermCaptureTimeoutMilliseconds
        if ($timeout -le 0) {
            break
        }
        $clients = @(Invoke-CodexToastWezTermListClients `
            -Executable $executablePath `
            -SocketPath $probe.socket_path `
            -TimeoutMilliseconds $timeout)
        $processId = Resolve-CodexToastWezTermOriginProcessId `
            -Clients $clients `
            -EnvironmentPaneId $probe.pane_id
        if ($null -eq $processId) {
            continue
        }

        $matchingProcesses = @($guiProcesses | Where-Object {
            [long]$_.Id -eq [long]$processId -and
            (Join-Path (Split-Path ([string]$_.Path) -Parent) "wezterm.exe") -ieq $executablePath
        })
        if ($matchingProcesses.Count -eq 1) {
            $resolvedProcessIds += [long]$processId
        }
    }

    $resolvedProcessIds = @($resolvedProcessIds | Select-Object -Unique)
    if ($resolvedProcessIds.Count -eq 1) {
        return [long]$resolvedProcessIds[0]
    }
    return $null
}

function Test-CodexToastWezTermActivationState {
    param(
        [Parameter(Mandatory)][object[]]$Clients,
        [Parameter(Mandatory)][object[]]$Panes,
        [Parameter(Mandatory)][string]$GuiProcessId,
        [Parameter(Mandatory)][string]$PaneId,
        [Parameter(Mandatory)][string]$MuxWindowId
    )

    $matchingClients = @($Clients | Where-Object {
        [string]$_.pid -ceq $GuiProcessId -and
        [string]$_.focused_pane_id -ceq $PaneId
    })
    $matchingPanes = @($Panes | Where-Object {
        [string]$_.pane_id -ceq $PaneId -and
        [string]$_.window_id -ceq $MuxWindowId
    })
    return $matchingClients.Count -eq 1 -and $matchingPanes.Count -eq 1
}

function Get-CodexToastWezTermCapture {
    param(
        [Parameter(Mandatory)]$Target,
        [DateTime]$DeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(1500)
    )

    if ([Environment]::GetEnvironmentVariable("TERM_PROGRAM", "Process") -ine "WezTerm") {
        return $null
    }

    $paneId = [Environment]::GetEnvironmentVariable("WEZTERM_PANE", "Process")
    $socketPath = [Environment]::GetEnvironmentVariable("WEZTERM_UNIX_SOCKET", "Process")
    try {
        $probe = ConvertFrom-CodexToastWezTermLocator -Value ([pscustomobject]@{
            pane_id = $paneId
            socket_path = $socketPath
            mux_window_id = "0"
        })
    }
    catch {
        return $null
    }

    $executable = Get-CodexToastWezTermExecutable -Target $Target
    if ($null -eq $executable) {
        return $null
    }
    $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
        -DeadlineUtc $DeadlineUtc `
        -MaximumMilliseconds $script:CodexToastWezTermCaptureTimeoutMilliseconds
    if ($timeout -le 0) {
        return $null
    }
    $clients = @(Invoke-CodexToastWezTermListClients `
        -Executable $executable `
        -SocketPath $probe.socket_path `
        -TimeoutMilliseconds $timeout)
    $matchingClients = @($clients | Where-Object {
        [string]$_.pid -ceq [string]$Target.pid -and
        [string]$_.focused_pane_id -match "^(0|[1-9][0-9]{0,19})$"
    })
    if ($matchingClients.Count -ne 1) {
        return $null
    }

    $tmuxAttached =
        -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("TMUX", "Process")) -and
        -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("TMUX_PANE", "Process"))
    $focusedPaneId = Resolve-CodexToastWezTermCapturePaneId `
        -EnvironmentPaneId $probe.pane_id `
        -FocusedPaneId ([string]$matchingClients[0].focused_pane_id) `
        -TmuxAttached $tmuxAttached
    $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
        -DeadlineUtc $DeadlineUtc `
        -MaximumMilliseconds $script:CodexToastWezTermCaptureTimeoutMilliseconds
    if ($timeout -le 0) {
        return $null
    }
    $panes = @(Invoke-CodexToastWezTermList `
        -Executable $executable `
        -SocketPath $probe.socket_path `
        -TimeoutMilliseconds $timeout)
    $matchingPanes = @($panes | Where-Object { [string]$_.pane_id -ceq $focusedPaneId })
    if ($matchingPanes.Count -ne 1) {
        return $null
    }

    try {
        $locator = ConvertFrom-CodexToastWezTermLocator -Value ([pscustomobject]@{
            pane_id = $focusedPaneId
            socket_path = $probe.socket_path
            mux_window_id = [string]$matchingPanes[0].window_id
        })
    }
    catch {
        return $null
    }

    return [pscustomobject][ordered]@{
        provider = "wezterm"
        version = 1
        locator = $locator
    }
}

function Invoke-CodexToastWezTermActivation {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Target
    )

    if ([int]$Context.version -ne 1) {
        return New-CodexToastTerminalResult -Status "unsupported" -Provider "wezterm"
    }
    try {
        $locator = ConvertFrom-CodexToastWezTermLocator -Value $Context.locator
    }
    catch {
        return New-CodexToastTerminalResult -Status "failed" -Provider "wezterm" -Detail "invalid-locator"
    }

    $executable = Get-CodexToastWezTermExecutable -Target $Target
    if ($null -eq $executable) {
        return New-CodexToastTerminalResult -Status "stale" -Provider "wezterm"
    }
    $clients = @(Invoke-CodexToastWezTermListClients `
        -Executable $executable `
        -SocketPath $locator.socket_path `
        -TimeoutMilliseconds $script:CodexToastWezTermActivationTimeoutMilliseconds)
    $matchingClients = @($clients | Where-Object { [string]$_.pid -ceq [string]$Target.pid })
    if ($matchingClients.Count -ne 1) {
        return New-CodexToastTerminalResult -Status "stale" -Provider "wezterm"
    }
    $panes = @(Invoke-CodexToastWezTermList `
        -Executable $executable `
        -SocketPath $locator.socket_path `
        -TimeoutMilliseconds $script:CodexToastWezTermActivationTimeoutMilliseconds)
    $matchingPanes = @($panes | Where-Object {
        [string]$_.pane_id -ceq $locator.pane_id -and
        [string]$_.window_id -ceq $locator.mux_window_id
    })
    if ($matchingPanes.Count -ne 1) {
        return New-CodexToastTerminalResult -Status "stale" -Provider "wezterm"
    }

    $result = Invoke-CodexToastTerminalProcess `
        -FilePath $executable `
        -Arguments "cli --no-auto-start activate-pane --pane-id $($locator.pane_id)" `
        -Environment @{ WEZTERM_UNIX_SOCKET = $locator.socket_path } `
        -TimeoutMilliseconds $script:CodexToastWezTermActivationTimeoutMilliseconds
    if ($result.TimedOut -or $result.ExitCode -ne 0) {
        return New-CodexToastTerminalResult -Status "failed" -Provider "wezterm" -Detail "cli-failed"
    }

    $verificationDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(
        $script:CodexToastWezTermActivationVerificationMilliseconds)
    while ([DateTime]::UtcNow -lt $verificationDeadlineUtc) {
        $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
            -DeadlineUtc $verificationDeadlineUtc `
            -MaximumMilliseconds 250
        if ($timeout -le 0) {
            break
        }

        $clients = @(Invoke-CodexToastWezTermListClients `
            -Executable $executable `
            -SocketPath $locator.socket_path `
            -TimeoutMilliseconds $timeout)
        if (@($clients | Where-Object {
            [string]$_.pid -ceq [string]$Target.pid -and
            [string]$_.focused_pane_id -ceq $locator.pane_id
        }).Count -eq 1) {
            $panes = @(Invoke-CodexToastWezTermList `
                -Executable $executable `
                -SocketPath $locator.socket_path `
                -TimeoutMilliseconds $timeout)
            if (Test-CodexToastWezTermActivationState `
                -Clients $clients `
                -Panes $panes `
                -GuiProcessId ([string]$Target.pid) `
                -PaneId $locator.pane_id `
                -MuxWindowId $locator.mux_window_id) {
                return New-CodexToastTerminalResult -Status "activated" -Provider "wezterm"
            }
        }

        Start-Sleep -Milliseconds 25
    }

    return New-CodexToastTerminalResult `
        -Status "failed" `
        -Provider "wezterm" `
        -Detail "activation-not-confirmed"
}
