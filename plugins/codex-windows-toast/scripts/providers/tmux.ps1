$script:CodexToastTmuxCaptureTimeoutMilliseconds = 750
$script:CodexToastTmuxActivationTimeoutMilliseconds = 1000
$script:CodexToastTmuxMaximumOutputBytes = 262144
$script:CodexToastTmuxExecutable = "/usr/bin/tmux"
$script:CodexToastTmuxPaneFormat = "#{pid}|#{start_time}|#{session_id}|#{session_created}|#{window_id}|#{pane_id}"
$script:CodexToastTmuxClientFormat = "#{pid}|#{start_time}|#{client_name}|#{client_pid}|#{client_created}|#{session_id}|#{session_created}|#{window_id}|#{pane_id}|#{client_control_mode}|#{client_tty}"

function ConvertTo-CodexToastTmuxPositiveInteger {
    param([Parameter(Mandatory)]$Value)

    $text = [string]$Value
    [uint64]$parsed = 0
    if ($text -notmatch "^[1-9][0-9]{0,19}$" -or
        -not [uint64]::TryParse($text, [ref]$parsed)) {
        throw "Invalid tmux locator."
    }
    return $text
}

function ConvertTo-CodexToastTmuxId {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][ValidateSet("$", "@", "%")][string]$Prefix
    )

    $text = [string]$Value
    if ($text -notmatch "^$([regex]::Escape($Prefix))(0|[1-9][0-9]{0,9})$") {
        throw "Invalid tmux locator."
    }
    return $text
}

function ConvertTo-CodexToastTmuxPath {
    param(
        [Parameter(Mandatory)]$Value,
        [ValidateRange(1, 1024)][int]$MaximumLength = 1024
    )

    $text = [string]$Value
    if ($text.Length -gt $MaximumLength -or
        $text -notmatch "^/[A-Za-z0-9._/@%+=,:-]+$") {
        throw "Invalid tmux locator."
    }
    return $text
}

function ConvertFrom-CodexToastTmuxLocator {
    param([Parameter(Mandatory)]$Value)

    $properties = @(
        "transport", "wsl_distro", "socket_path", "server_pid", "server_started",
        "session_id", "session_created", "window_id", "pane_id", "client_name",
        "client_pid", "client_created", "client_tty"
    )
    if (-not (Test-CodexToastObjectShape -Value $Value -PropertyNames $properties) -or
        [string]$Value.transport -cne "wsl" -or
        [string]$Value.wsl_distro -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") {
        throw "Invalid tmux locator."
    }

    return [pscustomobject][ordered]@{
        transport = "wsl"
        wsl_distro = [string]$Value.wsl_distro
        socket_path = ConvertTo-CodexToastTmuxPath -Value $Value.socket_path
        server_pid = ConvertTo-CodexToastTmuxPositiveInteger -Value $Value.server_pid
        server_started = ConvertTo-CodexToastTmuxPositiveInteger -Value $Value.server_started
        session_id = ConvertTo-CodexToastTmuxId -Value $Value.session_id -Prefix '$'
        session_created = ConvertTo-CodexToastTmuxPositiveInteger -Value $Value.session_created
        window_id = ConvertTo-CodexToastTmuxId -Value $Value.window_id -Prefix '@'
        pane_id = ConvertTo-CodexToastTmuxId -Value $Value.pane_id -Prefix '%'
        client_name = ConvertTo-CodexToastTmuxPath -Value $Value.client_name -MaximumLength 256
        client_pid = ConvertTo-CodexToastTmuxPositiveInteger -Value $Value.client_pid
        client_created = ConvertTo-CodexToastTmuxPositiveInteger -Value $Value.client_created
        client_tty = ConvertTo-CodexToastTmuxPath -Value $Value.client_tty -MaximumLength 256
    }
}

function Get-CodexToastWslExecutable {
    $systemPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    if ([string]::IsNullOrWhiteSpace($systemPath)) {
        return $null
    }
    $executable = Join-Path $systemPath "wsl.exe"
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        return $null
    }
    return $executable
}

function Test-CodexToastWslDistributionRunning {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $result = Invoke-CodexToastTerminalProcess `
        -FilePath $Executable `
        -Arguments "--list --running --quiet" `
        -TimeoutMilliseconds $TimeoutMilliseconds
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or
        [Text.Encoding]::UTF8.GetByteCount($result.StandardOutput) -gt 65536) {
        return $false
    }

    $output = $result.StandardOutput.Replace([string][char]0, "")
    $matches = @($output -split "`r?`n" | Where-Object { $_.Trim() -ceq $Distribution })
    return $matches.Count -eq 1
}

function Invoke-CodexToastTmuxCommand {
    param(
        [Parameter(Mandatory)][string]$WslExecutable,
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][string]$SocketPath,
        [Parameter(Mandatory)][string[]]$Command,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $arguments = @("--distribution", $Distribution, "--exec", $script:CodexToastTmuxExecutable, "-N", "-S", $SocketPath) + $Command
    foreach ($argument in $arguments) {
        if ([string]$argument -notmatch "^[A-Za-z0-9._/@%+=,:#{}|$-]+$") {
            throw "Invalid tmux command argument."
        }
    }

    return Invoke-CodexToastTerminalProcess `
        -FilePath $WslExecutable `
        -Arguments ($arguments -join " ") `
        -TimeoutMilliseconds $TimeoutMilliseconds
}

function ConvertFrom-CodexToastTmuxRows {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][ValidateRange(1, 16)][int]$FieldCount
    )

    if ([Text.Encoding]::UTF8.GetByteCount($Value) -gt $script:CodexToastTmuxMaximumOutputBytes) {
        throw "tmux output is too large."
    }
    $lines = @($Value -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -gt 1024) {
        throw "tmux output has too many rows."
    }

    $rows = @()
    foreach ($line in $lines) {
        $fields = @($line.Split([char]'|'))
        if ($fields.Count -ne $FieldCount) {
            throw "Invalid tmux output."
        }
        $rows += ,$fields
    }
    return $rows
}

function Get-CodexToastTmuxState {
    param(
        [Parameter(Mandatory)][string]$WslExecutable,
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][string]$SocketPath,
        [Parameter(Mandatory)][DateTime]$DeadlineUtc,
        [Parameter(Mandatory)][ValidateRange(1, 5000)][int]$MaximumTimeoutMilliseconds
    )

    $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
        -DeadlineUtc $DeadlineUtc `
        -MaximumMilliseconds $MaximumTimeoutMilliseconds
    if ($timeout -le 0) {
        return $null
    }
    $paneResult = Invoke-CodexToastTmuxCommand `
        -WslExecutable $WslExecutable `
        -Distribution $Distribution `
        -SocketPath $SocketPath `
        -Command @("list-panes", "-a", "-F", $script:CodexToastTmuxPaneFormat) `
        -TimeoutMilliseconds $timeout
    if ($paneResult.TimedOut -or $paneResult.ExitCode -ne 0) {
        return $null
    }

    $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
        -DeadlineUtc $DeadlineUtc `
        -MaximumMilliseconds $MaximumTimeoutMilliseconds
    if ($timeout -le 0) {
        return $null
    }
    $clientResult = Invoke-CodexToastTmuxCommand `
        -WslExecutable $WslExecutable `
        -Distribution $Distribution `
        -SocketPath $SocketPath `
        -Command @("list-clients", "-F", $script:CodexToastTmuxClientFormat) `
        -TimeoutMilliseconds $timeout
    if ($clientResult.TimedOut -or $clientResult.ExitCode -ne 0) {
        return $null
    }

    try {
        $panes = @(ConvertFrom-CodexToastTmuxRows `
            -Value $paneResult.StandardOutput `
            -FieldCount 6 | ForEach-Object {
                [pscustomobject]@{
                    ServerPid = $_[0]
                    ServerStarted = $_[1]
                    SessionId = $_[2]
                    SessionCreated = $_[3]
                    WindowId = $_[4]
                    PaneId = $_[5]
                }
            })
        $clients = @(ConvertFrom-CodexToastTmuxRows `
            -Value $clientResult.StandardOutput `
            -FieldCount 11 | ForEach-Object {
                [pscustomobject]@{
                    ServerPid = $_[0]
                    ServerStarted = $_[1]
                    Name = $_[2]
                    Pid = $_[3]
                    Created = $_[4]
                    SessionId = $_[5]
                    SessionCreated = $_[6]
                    WindowId = $_[7]
                    PaneId = $_[8]
                    ControlMode = $_[9]
                    Tty = $_[10]
                }
            })
        return [pscustomobject]@{
            Panes = $panes
            Clients = $clients
        }
    }
    catch {
        return $null
    }
}

function Get-CodexToastTmuxCapture {
    param(
        [Parameter(Mandatory)]$Target,
        [DateTime]$DeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(2500)
    )

    $distribution = [Environment]::GetEnvironmentVariable("WSL_DISTRO_NAME", "Process")
    $tmuxEnvironment = [Environment]::GetEnvironmentVariable("TMUX", "Process")
    $paneId = [Environment]::GetEnvironmentVariable("TMUX_PANE", "Process")
    if ([string]$distribution -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$" -or
        ([string]$tmuxEnvironment).Length -gt 1200 -or
        [string]$paneId -notmatch "^%(0|[1-9][0-9]{0,9})$") {
        return $null
    }

    $tmuxMatch = [regex]::Match([string]$tmuxEnvironment, "^(?<socket>/[A-Za-z0-9._/@%+=,:-]+),(?<pid>[1-9][0-9]{0,19}),(?<session>0|[1-9][0-9]{0,9})$")
    if (-not $tmuxMatch.Success) {
        return $null
    }

    $wslExecutable = Get-CodexToastWslExecutable
    $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
        -DeadlineUtc $DeadlineUtc `
        -MaximumMilliseconds $script:CodexToastTmuxCaptureTimeoutMilliseconds
    if ($null -eq $wslExecutable -or $timeout -le 0 -or
        -not (Test-CodexToastWslDistributionRunning `
        -Executable $wslExecutable `
        -Distribution $distribution `
        -TimeoutMilliseconds $timeout)) {
        return $null
    }
    $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
        -DeadlineUtc $DeadlineUtc `
        -MaximumMilliseconds $script:CodexToastTmuxCaptureTimeoutMilliseconds
    if ($timeout -le 0) {
        return $null
    }
    $state = Get-CodexToastTmuxState `
        -WslExecutable $wslExecutable `
        -Distribution $distribution `
        -SocketPath $tmuxMatch.Groups["socket"].Value `
        -DeadlineUtc $DeadlineUtc `
        -MaximumTimeoutMilliseconds $script:CodexToastTmuxCaptureTimeoutMilliseconds
    if ($null -eq $state) {
        return $null
    }

    $clients = @($state.Clients | Where-Object {
        $_.ServerPid -ceq $tmuxMatch.Groups["pid"].Value -and
        $_.PaneId -ceq $paneId -and
        $_.ControlMode -ceq "0"
    })
    if ($clients.Count -ne 1) {
        return $null
    }
    $client = $clients[0]
    $panes = @($state.Panes | Where-Object {
        $_.ServerPid -ceq $client.ServerPid -and
        $_.SessionId -ceq $client.SessionId -and
        $_.WindowId -ceq $client.WindowId -and
        $_.PaneId -ceq $client.PaneId
    })
    if ($panes.Count -ne 1) {
        return $null
    }
    $pane = $panes[0]

    try {
        $locator = ConvertFrom-CodexToastTmuxLocator -Value ([pscustomobject]@{
            transport = "wsl"
            wsl_distro = $distribution
            socket_path = $tmuxMatch.Groups["socket"].Value
            server_pid = $pane.ServerPid
            server_started = $pane.ServerStarted
            session_id = $pane.SessionId
            session_created = $pane.SessionCreated
            window_id = $pane.WindowId
            pane_id = $pane.PaneId
            client_name = $client.Name
            client_pid = $client.Pid
            client_created = $client.Created
            client_tty = $client.Tty
        })
    }
    catch {
        return $null
    }

    return [pscustomobject][ordered]@{
        provider = "tmux"
        version = 1
        locator = $locator
    }
}

function Invoke-CodexToastTmuxActivation {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Target
    )

    if ([int]$Context.version -ne 1) {
        return New-CodexToastTerminalResult -Status "unsupported" -Provider "tmux"
    }
    try {
        $locator = ConvertFrom-CodexToastTmuxLocator -Value $Context.locator
    }
    catch {
        return New-CodexToastTerminalResult -Status "failed" -Provider "tmux" -Detail "invalid-locator"
    }

    $deadlineUtc = [DateTime]::UtcNow.AddMilliseconds(4000)
    $wslExecutable = Get-CodexToastWslExecutable
    $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
        -DeadlineUtc $deadlineUtc `
        -MaximumMilliseconds $script:CodexToastTmuxActivationTimeoutMilliseconds
    if ($null -eq $wslExecutable -or $timeout -le 0 -or
        -not (Test-CodexToastWslDistributionRunning `
        -Executable $wslExecutable `
        -Distribution $locator.wsl_distro `
        -TimeoutMilliseconds $timeout)) {
        return New-CodexToastTerminalResult -Status "stale" -Provider "tmux"
    }
    $state = Get-CodexToastTmuxState `
        -WslExecutable $wslExecutable `
        -Distribution $locator.wsl_distro `
        -SocketPath $locator.socket_path `
        -DeadlineUtc $deadlineUtc `
        -MaximumTimeoutMilliseconds $script:CodexToastTmuxActivationTimeoutMilliseconds
    if ($null -eq $state) {
        return New-CodexToastTerminalResult -Status "stale" -Provider "tmux"
    }

    $clients = @($state.Clients | Where-Object {
        $_.ServerPid -ceq $locator.server_pid -and
        $_.ServerStarted -ceq $locator.server_started -and
        $_.Name -ceq $locator.client_name -and
        $_.Pid -ceq $locator.client_pid -and
        $_.Created -ceq $locator.client_created -and
        $_.ControlMode -ceq "0" -and
        $_.Tty -ceq $locator.client_tty
    })
    $panes = @($state.Panes | Where-Object {
        $_.ServerPid -ceq $locator.server_pid -and
        $_.ServerStarted -ceq $locator.server_started -and
        $_.SessionId -ceq $locator.session_id -and
        $_.SessionCreated -ceq $locator.session_created -and
        $_.WindowId -ceq $locator.window_id -and
        $_.PaneId -ceq $locator.pane_id
    })
    if ($clients.Count -ne 1 -or $panes.Count -ne 1) {
        return New-CodexToastTerminalResult -Status "stale" -Provider "tmux"
    }

    $targetPane = "$($locator.session_id):$($locator.window_id).$($locator.pane_id)"
    $timeout = Get-CodexToastTerminalTimeoutMilliseconds `
        -DeadlineUtc $deadlineUtc `
        -MaximumMilliseconds $script:CodexToastTmuxActivationTimeoutMilliseconds
    if ($timeout -le 0) {
        return New-CodexToastTerminalResult -Status "failed" -Provider "tmux" -Detail "deadline-exceeded"
    }
    $result = Invoke-CodexToastTmuxCommand `
        -WslExecutable $wslExecutable `
        -Distribution $locator.wsl_distro `
        -SocketPath $locator.socket_path `
        -Command @("switch-client", "-c", $locator.client_name, "-t", $targetPane) `
        -TimeoutMilliseconds $timeout
    if (-not $result.TimedOut -and $result.ExitCode -ne 0) {
        return New-CodexToastTerminalResult -Status "failed" -Provider "tmux" -Detail "switch-failed"
    }

    $verifiedState = Get-CodexToastTmuxState `
        -WslExecutable $wslExecutable `
        -Distribution $locator.wsl_distro `
        -SocketPath $locator.socket_path `
        -DeadlineUtc $deadlineUtc `
        -MaximumTimeoutMilliseconds $script:CodexToastTmuxActivationTimeoutMilliseconds
    $verifiedClients = @()
    $verifiedPanes = @()
    if ($null -ne $verifiedState) {
        $verifiedClients = @($verifiedState.Clients | Where-Object {
            $_.ServerPid -ceq $locator.server_pid -and
            $_.ServerStarted -ceq $locator.server_started -and
            $_.Name -ceq $locator.client_name -and
            $_.Pid -ceq $locator.client_pid -and
            $_.Created -ceq $locator.client_created -and
            $_.SessionId -ceq $locator.session_id -and
            $_.SessionCreated -ceq $locator.session_created -and
            $_.WindowId -ceq $locator.window_id -and
            $_.PaneId -ceq $locator.pane_id -and
            $_.ControlMode -ceq "0" -and
            $_.Tty -ceq $locator.client_tty
        })
        $verifiedPanes = @($verifiedState.Panes | Where-Object {
            $_.ServerPid -ceq $locator.server_pid -and
            $_.ServerStarted -ceq $locator.server_started -and
            $_.SessionId -ceq $locator.session_id -and
            $_.SessionCreated -ceq $locator.session_created -and
            $_.WindowId -ceq $locator.window_id -and
            $_.PaneId -ceq $locator.pane_id
        })
    }
    if ($verifiedClients.Count -ne 1 -or $verifiedPanes.Count -ne 1) {
        $detail = if ($result.TimedOut) { "switch-timeout-unverified" } else { "switch-not-verified" }
        return New-CodexToastTerminalResult -Status "failed" -Provider "tmux" -Detail $detail
    }
    return New-CodexToastTerminalResult -Status "activated" -Provider "tmux"
}
