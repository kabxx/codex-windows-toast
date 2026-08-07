[CmdletBinding()]
param(
    [switch]$Integration
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptRoot = Join-Path $repoRoot "plugins\codex-windows-toast\scripts"
$showToastPath = Join-Path $scriptRoot "show-toast.ps1"
$commonPath = Join-Path $scriptRoot "activation-common.ps1"
$activatorPath = Join-Path $scriptRoot "activate-window.ps1"
$launcherPath = Join-Path $scriptRoot "launch-hidden.vbs"
$terminalProvidersPath = Join-Path $scriptRoot "terminal-providers.ps1"
$windowsTerminalUiaPath = Join-Path $scriptRoot "providers\windows-terminal-uia.ps1"
$setupPath = Join-Path $scriptRoot "setup.ps1"
$hooksPath = Join-Path $repoRoot "plugins\codex-windows-toast\hooks\hooks.json"

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Expected -cne $Actual) {
        throw "$Name failed. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        & $Action
    }
    catch {
        return
    }
    throw "$Name failed. The operation did not throw."
}

function Start-HookScript {
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string]$PluginData
    )

    $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath
    $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$showToastPath`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables["PLUGIN_DATA"] = $PluginData

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $process.StandardInput.WriteLine($Json)
        $process.StandardInput.Close()
        return [pscustomobject]@{ Process = $process }
    }
    catch {
        $process.Dispose()
        throw
    }
}

function Receive-HookScript {
    param([Parameter(Mandatory)]$Invocation)

    $process = $Invocation.Process
    try {
        $output = $process.StandardOutput.ReadToEnd().Trim()
        $errorOutput = $process.StandardError.ReadToEnd().Trim()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $output
            Error = $errorOutput
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-HookScript {
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string]$PluginData
    )

    return Receive-HookScript -Invocation (Start-HookScript -Json $Json -PluginData $PluginData)
}

$tokens = $null
$parseErrors = $null
$showToastAst = [Management.Automation.Language.Parser]::ParseFile(
    $showToastPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw "show-toast.ps1 has parse errors: $($parseErrors.Message -join '; ')"
}

$textFunction = $showToastAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "ConvertTo-ToastText"
}, $true)
if ($null -eq $textFunction) {
    throw "ConvertTo-ToastText was not found."
}
Invoke-Expression $textFunction.Extent.Text

$hookConfiguration = Get-Content -Raw -LiteralPath $hooksPath | ConvertFrom-Json
foreach ($eventName in @("SessionStart", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "SessionEnd")) {
    Assert-Equal `
        -Expected $true `
        -Actual ([bool]($hookConfiguration.hooks.PSObject.Properties.Name -ccontains $eventName)) `
        -Name "$eventName hook registration"
}
Assert-Equal `
    -Expected "startup|resume|clear" `
    -Actual ([string]$hookConfiguration.hooks.SessionStart[0].matcher) `
    -Name "SessionStart excludes compact lifecycle events"

$emoji = [char]::ConvertFromUtf32(0x1F642)
$emojiInput = ("a" * 236) + $emoji + "tail"
$emojiExpected = ("a" * 236) + $emoji + "..."
Assert-Equal -Expected $emojiExpected -Actual (ConvertTo-ToastText -Text $emojiInput -MaxLength 240) -Name "emoji boundary"

$combiningMark = [string][char]0x0301
$combiningInput = ("a" * 236) + "e" + $combiningMark + "tail"
$combiningExpected = ("a" * 236) + "e" + $combiningMark + "..."
Assert-Equal -Expected $combiningExpected -Actual (ConvertTo-ToastText -Text $combiningInput -MaxLength 240) -Name "combining character boundary"

$invalidControls = "left" + [string][char]0x0 + [string][char]0x1 + [string][char]0xB + " right"
Assert-Equal -Expected "left right" -Actual (ConvertTo-ToastText -Text $invalidControls -MaxLength 40) -Name "XML control filtering"

$unpairedSurrogates = [string][char]0xD83D + "ok" + [string][char]0xDC00
Assert-Equal -Expected "ok" -Actual (ConvertTo-ToastText -Text $unpairedSurrogates -MaxLength 40) -Name "unpaired surrogate filtering"

$xmlSafeText = ConvertTo-ToastText -Text ($emojiInput + $invalidControls) -MaxLength 240
$xmlDocument = New-Object Xml.XmlDocument
$xmlDocument.LoadXml("<toast><text>$([Security.SecurityElement]::Escape($xmlSafeText))</text></toast>")
Assert-Throws -Action { ConvertTo-ToastText -Text "test" -MaxLength 3 } -Name "minimum length validation"

. $commonPath
. $terminalProvidersPath
$component = Get-CodexToastActivationComponent -BasePath $scriptRoot
Assert-Equal `
    -Expected $true `
    -Actual $component.FileHashes.Contains("providers\windows-terminal-uia.ps1") `
    -Name "Windows Terminal worker participates in component fingerprint"
$record = [ordered]@{
    schema_version = $script:CodexToastActivationRecordSchemaVersion
    activation_component_version = $component.Version
    activation_component_fingerprint = $component.Fingerprint
    file_hashes = $component.FileHashes
} | ConvertTo-Json -Depth 4 | ConvertFrom-Json
Test-CodexToastActivationComponentRecord -Record $record -Component $component
$record.activation_component_fingerprint = "invalid"
Assert-Throws -Action {
    Test-CodexToastActivationComponentRecord -Record $record -Component $component
} -Name "activation fingerprint validation"

$activationTargets = @(
    [pscustomobject]@{ hwnd = 101; pid = 201; started_utc_ticks = 301 }
    [pscustomobject]@{ hwnd = 102; pid = 202; started_utc_ticks = 302 }
)
$encodedTargets = ConvertTo-CodexToastActivationTargets -Targets $activationTargets
Assert-Equal -Expected "101.201.301~102.202.302" -Actual $encodedTargets -Name "activation targets serialization"
$decodedTargets = @(ConvertFrom-CodexToastActivationTargets -Value $encodedTargets)
Assert-Equal -Expected 2 -Actual $decodedTargets.Count -Name "activation targets count"
Assert-Equal -Expected 101 -Actual ([long]$decodedTargets[0].hwnd) -Name "primary target hwnd"
Assert-Equal -Expected 202 -Actual ([long]$decodedTargets[1].pid) -Name "secondary target pid"
Assert-Equal -Expected 302 -Actual ([long]$decodedTargets[1].started_utc_ticks) -Name "secondary target start time"

$duplicateTargets = @(
    [pscustomobject]@{ hwnd = 101; pid = 201; started_utc_ticks = 301 }
    [pscustomobject]@{ hwnd = 101; pid = 202; started_utc_ticks = 302 }
)
$tooManyTargets = 1..9 | ForEach-Object {
    [pscustomobject]@{ hwnd = $_; pid = 200 + $_; started_utc_ticks = 300 + $_ }
}
Assert-Throws -Action {
    ConvertTo-CodexToastActivationTargets -Targets @()
} -Name "empty activation targets"
Assert-Throws -Action {
    ConvertTo-CodexToastActivationTargets -Targets @([pscustomobject]@{ hwnd = 0; pid = 1; started_utc_ticks = 1 })
} -Name "non-positive activation target hwnd"
Assert-Throws -Action {
    ConvertTo-CodexToastActivationTargets -Targets @([pscustomobject]@{ hwnd = 1; pid = 0; started_utc_ticks = 1 })
} -Name "non-positive activation target pid"
Assert-Throws -Action {
    ConvertTo-CodexToastActivationTargets -Targets @([pscustomobject]@{ hwnd = 1; pid = 1; started_utc_ticks = 0 })
} -Name "non-positive activation target start time"
Assert-Throws -Action {
    ConvertTo-CodexToastActivationTargets -Targets $duplicateTargets
} -Name "duplicate activation target hwnd"
Assert-Throws -Action {
    ConvertTo-CodexToastActivationTargets -Targets $tooManyTargets
} -Name "activation target count limit"
foreach ($invalidTargets in @(
    "",
    "0.2.3",
    "01.2.3",
    "1.2.3~1.4.5",
    "1.2.3~4.5.6&extra=7",
    "999999999999999999999.2.3",
    "1.2.3~4.5.6~7.8.9~10.11.12~13.14.15~16.17.18~19.20.21~22.23.24~25.26.27"
)) {
    Assert-Throws -Action {
        ConvertFrom-CodexToastActivationTargets -Value $invalidTargets
    } -Name "invalid activation targets '$invalidTargets'"
}

$activationRuntime = Join-Path ([IO.Path]::GetTempPath()) "codex-windows-toast-activation-$([Guid]::NewGuid().ToString('N'))"
[void][IO.Directory]::CreateDirectory($activationRuntime)
$secretPath = Join-Path $activationRuntime "secret.dat"
$secret = [Text.Encoding]::UTF8.GetBytes("codex-window-target-test-secret-32")
try {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $protectedSecret = [Security.Cryptography.ProtectedData]::Protect(
        $secret,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [Convert]::ToBase64String($protectedSecret) | Set-Content -LiteralPath $secretPath -Encoding ASCII
    $activationContext = [pscustomobject]@{
        RuntimePath = $activationRuntime
        SecretPath = $secretPath
    }
    $terminalContext = [pscustomobject]@{
        outer = [pscustomobject]@{
            provider = "test"
            version = 1
            locator = [pscustomobject]@{ value = "target" }
        }
        inner = @()
    }
    $activationUri = New-CodexToastActivationUri -Targets $activationTargets -Context $activationContext -Terminal $terminalContext
    Assert-Equal -Expected $true -Actual ([bool]($activationUri -cmatch '^codex-windows-toast://activate\?v=3&id=[0-9a-f]{32}&sig=[0-9a-f]{64}$')) -Name "v3 activation URI"

    $activationMatch = [regex]::Match($activationUri, 'id=([0-9a-f]{32})&sig=([0-9a-f]{64})$')
    $activationId = $activationMatch.Groups[1].Value
    $activationSignature = $activationMatch.Groups[2].Value
    $activationRecordPath = Join-Path (Get-CodexToastActivationRecordDirectory -RuntimePath $activationRuntime) "$activationId.json"
    Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $activationRecordPath -PathType Leaf) -Name "v3 activation record exists"
    $loadedActivation = Read-CodexToastActivationRecord -Id $activationId -Signature $activationSignature -Context $activationContext
    Assert-Equal -Expected 2 -Actual @($loadedActivation.targets).Count -Name "v3 activation target count"
    Assert-Equal -Expected "test" -Actual ([string]$loadedActivation.terminal.outer.provider) -Name "v3 terminal context"
    Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $activationRecordPath) -Name "v3 activation record remains before claim"
    $activationClaim = Enter-CodexToastActivationClaim `
        -Id $activationId `
        -Signature $activationSignature `
        -Context $activationContext
    Release-CodexToastActivationClaim -Claim $activationClaim
    Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $activationRecordPath) -Name "failed activation claim keeps record"
    $activationClaim = Enter-CodexToastActivationClaim `
        -Id $activationId `
        -Signature $activationSignature `
        -Context $activationContext
    Complete-CodexToastActivationClaim `
        -Id $activationId `
        -Context $activationContext `
        -Claim $activationClaim
    Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $activationRecordPath) -Name "successful activation claim consumes record"
    Assert-Throws -Action {
        Read-CodexToastActivationRecord -Id $activationId -Signature $activationSignature -Context $activationContext
    } -Name "consumed activation record"

    $tamperedUri = New-CodexToastActivationUri -Targets $activationTargets -Context $activationContext
    $tamperedMatch = [regex]::Match($tamperedUri, 'id=([0-9a-f]{32})&sig=([0-9a-f]{64})$')
    $tamperedPath = Join-Path (Get-CodexToastActivationRecordDirectory -RuntimePath $activationRuntime) "$($tamperedMatch.Groups[1].Value).json"
    [IO.File]::AppendAllText($tamperedPath, " ")
    Assert-Throws -Action {
        Read-CodexToastActivationRecord -Id $tamperedMatch.Groups[1].Value -Signature $tamperedMatch.Groups[2].Value -Context $activationContext
    } -Name "tampered activation record"
    Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $tamperedPath -PathType Leaf) -Name "unauthenticated record is not consumed"

    $bomUri = New-CodexToastActivationUri -Targets $activationTargets -Context $activationContext
    $bomMatch = [regex]::Match($bomUri, 'id=([0-9a-f]{32})&sig=([0-9a-f]{64})$')
    $bomPath = Join-Path (Get-CodexToastActivationRecordDirectory -RuntimePath $activationRuntime) "$($bomMatch.Groups[1].Value).json"
    $originalBytes = [IO.File]::ReadAllBytes($bomPath)
    $bomBytes = New-Object byte[] ($originalBytes.Length + 3)
    $bomBytes[0] = 0xEF
    $bomBytes[1] = 0xBB
    $bomBytes[2] = 0xBF
    [Array]::Copy($originalBytes, 0, $bomBytes, 3, $originalBytes.Length)
    [IO.File]::WriteAllBytes($bomPath, $bomBytes)
    Assert-Throws -Action {
        Read-CodexToastActivationRecord -Id $bomMatch.Groups[1].Value -Signature $bomMatch.Groups[2].Value -Context $activationContext
    } -Name "activation record rejects BOM"
    Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $bomPath -PathType Leaf) -Name "BOM record is not consumed"

    $expiredUri = New-CodexToastActivationUri -Targets $activationTargets -Context $activationContext -NowUtc ([DateTime]::UtcNow.AddDays(-8))
    $expiredMatch = [regex]::Match($expiredUri, 'id=([0-9a-f]{32})&sig=([0-9a-f]{64})$')
    $expiredPath = Join-Path (Get-CodexToastActivationRecordDirectory -RuntimePath $activationRuntime) "$($expiredMatch.Groups[1].Value).json"
    Assert-Throws -Action {
        Read-CodexToastActivationRecord -Id $expiredMatch.Groups[1].Value -Signature $expiredMatch.Groups[2].Value -Context $activationContext
    } -Name "expired activation record"
    Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $expiredPath) -Name "authenticated expired record is consumed"
}
finally {
    [Array]::Clear($secret, 0, $secret.Length)
    Remove-Item -LiteralPath $activationRuntime -Recurse -Force -ErrorAction SilentlyContinue
}

$launcherText = Get-Content -Raw -LiteralPath $launcherPath
Assert-Equal -Expected $true -Actual ([bool]($launcherText -cmatch 'v=2&targets=')) -Name "launcher accepts v2 targets"
Assert-Equal -Expected $true -Actual ([bool]($launcherText -cmatch 'v=3&id=')) -Name "launcher accepts v3 record IDs"
Assert-Equal -Expected $false -Actual ([bool]($launcherText -cmatch 'v=1&hwnd=')) -Name "launcher rejects legacy v1 URI"
$providerIds = @((Get-CodexToastTerminalProviders).Id)
Assert-Equal -Expected 3 -Actual $providerIds.Count -Name "terminal provider registry count"
Assert-Equal -Expected "wezterm" -Actual $providerIds[0] -Name "WezTerm provider registration"
Assert-Equal -Expected "windows-terminal" -Actual $providerIds[1] -Name "Windows Terminal provider registration"
Assert-Equal -Expected "tmux" -Actual $providerIds[2] -Name "tmux provider registration"
$wezTermLocator = ConvertFrom-CodexToastWezTermLocator -Value ([pscustomobject]@{
    pane_id = "18"
    socket_path = "C:\Users\test\wezterm.sock"
    mux_window_id = "2"
})
Assert-Equal -Expected "18" -Actual $wezTermLocator.pane_id -Name "WezTerm pane locator"
$wezTermJsonRows = @(ConvertFrom-CodexToastWezTermJsonList -Json '[{"pane_id":1},{"pane_id":16}]')
Assert-Equal -Expected 2 -Actual $wezTermJsonRows.Count -Name "WezTerm JSON list is flat in Windows PowerShell 5.1"
Assert-Equal -Expected "16" -Actual ([string]$wezTermJsonRows[1].pane_id) -Name "WezTerm JSON list preserves pane rows"
Assert-Equal `
    -Expected "18" `
    -Actual (Resolve-CodexToastWezTermCapturePaneId -EnvironmentPaneId "18" -FocusedPaneId "16" -TmuxAttached $false) `
    -Name "WezTerm capture uses process pane outside tmux"
Assert-Equal `
    -Expected "16" `
    -Actual (Resolve-CodexToastWezTermCapturePaneId -EnvironmentPaneId "18" -FocusedPaneId "16" -TmuxAttached $true) `
    -Name "WezTerm capture uses focused client for tmux"
$uniqueWezTermClient = @([pscustomobject]@{ pid = 27564; focused_pane_id = 16 })
Assert-Equal `
    -Expected 27564 `
    -Actual (Resolve-CodexToastWezTermOriginProcessId -Clients $uniqueWezTermClient -EnvironmentPaneId "18") `
    -Name "WezTerm origin resolves a unique GUI client"
$multipleWezTermClients = @(
    [pscustomobject]@{ pid = 27564; focused_pane_id = 16 },
    [pscustomobject]@{ pid = 38116; focused_pane_id = 18 }
)
Assert-Equal `
    -Expected 38116 `
    -Actual (Resolve-CodexToastWezTermOriginProcessId -Clients $multipleWezTermClients -EnvironmentPaneId "18") `
    -Name "WezTerm origin resolves the client focused on the environment pane"
Assert-Equal `
    -Expected $true `
    -Actual ($null -eq (Resolve-CodexToastWezTermOriginProcessId `
        -Clients $multipleWezTermClients `
        -EnvironmentPaneId "19")) `
    -Name "WezTerm origin rejects ambiguous clients"
$wezTermClients = @([pscustomobject]@{ pid = 27564; focused_pane_id = 18 })
$wezTermPanes = @([pscustomobject]@{ pane_id = 18; window_id = 2 })
Assert-Equal `
    -Expected $true `
    -Actual (Test-CodexToastWezTermActivationState `
        -Clients $wezTermClients `
        -Panes $wezTermPanes `
        -GuiProcessId "27564" `
        -PaneId "18" `
        -MuxWindowId "2") `
    -Name "WezTerm activation confirms pane and mux window"
Assert-Equal `
    -Expected $false `
    -Actual (Test-CodexToastWezTermActivationState `
        -Clients $wezTermClients `
        -Panes @([pscustomobject]@{ pane_id = 18; window_id = 3 }) `
        -GuiProcessId "27564" `
        -PaneId "18" `
        -MuxWindowId "2") `
    -Name "WezTerm activation rejects moved pane"
Assert-Throws -Action {
    ConvertFrom-CodexToastWezTermLocator -Value ([pscustomobject]@{
        pane_id = "18 --config-file bad"
        socket_path = "C:\Users\test\wezterm.sock"
        mux_window_id = "2"
    })
} -Name "WezTerm locator rejects argument injection"
Assert-Throws -Action {
    ConvertFrom-CodexToastWezTermLocator -Value ([pscustomobject]@{
        pane_id = "18"
        socket_path = "relative.sock"
        mux_window_id = "2"
    })
} -Name "WezTerm locator rejects relative socket"
$windowsTerminalLocator = ConvertFrom-CodexToastWindowsTerminalLocator -Value ([pscustomobject]@{
    session_guid = "12345678-1234-1234-1234-1234567890ab"
    tab_runtime_id = @(42, -7, 9)
    pane_runtime_id = @(42, -8, 10)
})
Assert-Equal -Expected "12345678-1234-1234-1234-1234567890ab" -Actual $windowsTerminalLocator.session_guid -Name "Windows Terminal session locator"
Assert-Equal -Expected -7 -Actual ([int]$windowsTerminalLocator.tab_runtime_id[1]) -Name "Windows Terminal tab runtime ID"
Assert-Throws -Action {
    ConvertFrom-CodexToastWindowsTerminalLocator -Value ([pscustomobject]@{
        session_guid = "not-a-guid"
        tab_runtime_id = @(42, 7)
        pane_runtime_id = @()
    })
} -Name "Windows Terminal locator rejects invalid session"
Assert-Throws -Action {
    ConvertFrom-CodexToastWindowsTerminalLocator -Value ([pscustomobject]@{
        session_guid = "12345678-1234-1234-1234-1234567890ab"
        tab_runtime_id = @("7; focus-tab")
        pane_runtime_id = @()
    })
} -Name "Windows Terminal locator rejects invalid runtime ID"
$staleWindowsTerminalResult = Invoke-CodexToastWindowsTerminalActivation -Context ([pscustomobject]@{
    provider = "windows-terminal"
    version = 1
    locator = $windowsTerminalLocator
}) -Target $activationTargets[0]
Assert-Equal -Expected "stale" -Actual $staleWindowsTerminalResult.Status -Name "Windows Terminal stale target fallback"
$tmuxLocator = ConvertFrom-CodexToastTmuxLocator -Value ([pscustomobject]@{
    transport = "wsl"
    wsl_distro = "Ubuntu-24.04"
    socket_path = "/tmp/tmux-1000/default"
    server_pid = "123"
    server_started = "1700000000"
    session_id = '$2'
    session_created = "1700000001"
    window_id = '@4'
    pane_id = '%7'
    client_name = "/dev/pts/1"
    client_pid = "456"
    client_created = "1700000002"
    client_tty = "/dev/pts/1"
})
Assert-Equal -Expected '%7' -Actual $tmuxLocator.pane_id -Name "tmux pane locator"
Assert-Throws -Action {
    ConvertFrom-CodexToastTmuxLocator -Value ([pscustomobject]@{
        transport = "wsl"
        wsl_distro = "Ubuntu --exec bad"
        socket_path = "/tmp/tmux-1000/default"
        server_pid = "123"
        server_started = "1700000000"
        session_id = '$2'
        session_created = "1700000001"
        window_id = '@4'
        pane_id = '%7'
        client_name = "/dev/pts/1"
        client_pid = "456"
        client_created = "1700000002"
        client_tty = "/dev/pts/1"
    })
} -Name "tmux locator rejects argument injection"
$staleTmuxLocator = $tmuxLocator.PSObject.Copy()
$staleTmuxLocator.wsl_distro = "CodexMissingDistro"
$staleTmuxResult = Invoke-CodexToastTmuxActivation -Context ([pscustomobject]@{
    provider = "tmux"
    version = 1
    locator = $staleTmuxLocator
}) -Target $activationTargets[0]
Assert-Equal -Expected "stale" -Actual $staleTmuxResult.Status -Name "tmux stale distro fallback"
$unknownTerminalResult = Invoke-CodexToastTerminalActivation -Terminal ([pscustomobject]@{
    outer = [pscustomobject]@{ provider = "unknown"; version = 1; locator = [pscustomobject]@{} }
    inner = @()
}) -Target $activationTargets[0]
Assert-Equal -Expected "unsupported" -Actual $unknownTerminalResult.Status -Name "unknown provider fallback"
$innerWithoutOuterResult = Invoke-CodexToastTerminalActivation -Terminal ([pscustomobject]@{
    outer = $null
    inner = @([pscustomobject]@{ provider = "tmux"; version = 1; locator = $tmuxLocator })
}) -Target $activationTargets[0]
Assert-Equal -Expected "unsupported" -Actual $innerWithoutOuterResult.Status -Name "inner provider requires supported outer"
$providerText = Get-Content -Raw -LiteralPath $terminalProvidersPath
Assert-Equal -Expected $false -Actual ([bool]($providerText -cmatch 'Invoke-Expression')) -Name "provider registry avoids dynamic evaluation"
$activatorText = Get-Content -Raw -LiteralPath $activatorPath
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch 'IsWindowArranged')) -Name "activator checks arranged windows"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch 'SetWindowPos')) -Name "activator raises group members"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch '\[IntPtr\]\(-1\)')) -Name "activator temporarily marks group members topmost"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch '\[IntPtr\]\(-2\)')) -Name "activator clears temporary topmost state"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch 'group-activated')) -Name "activator records group activation"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch '(?s)while \(\$restoreTimer\.ElapsedMilliseconds.*?IsIconic.*?Start-Sleep')) -Name "activator waits for restored windows"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch '(?s)while \(-not \$activated.*?SetForegroundWindow.*?GetForegroundWindow')) -Name "activator retries foreground activation"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch '\$retryIntervalMilliseconds = 50')) -Name "activator uses bounded retry interval"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch '\$restoreTimeoutMilliseconds = 500')) -Name "activator bounds restore wait"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch '\$activationTimeoutMilliseconds = 1000')) -Name "activator bounds activation retries"
Assert-Equal -Expected $false -Actual ([bool]($activatorText -cmatch 'Start-Sleep -Milliseconds (75|150)')) -Name "activator avoids fixed restore and verification delays"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch 'Invoke-CodexToastTerminalActivation')) -Name "activator dispatches terminal providers"
Assert-Equal -Expected $true -Actual ([bool]($activatorText -cmatch 'Installed -or -not \$context\.Current')) -Name "activator requires current component"
$windowsTerminalUiaText = Get-Content -Raw -LiteralPath $windowsTerminalUiaPath
Assert-Equal `
    -Expected $true `
    -Actual ([bool]($windowsTerminalUiaText -cmatch 'Test-WorkerDescendant -Root \$RequiredAncestor -Element \$_')) `
    -Name "Windows Terminal pane must belong to selected tab"

$setupTokens = $null
$setupParseErrors = $null
$setupText = Get-Content -Raw -LiteralPath $setupPath
Assert-Equal `
    -Expected $true `
    -Actual ([bool]($setupText -cmatch 'subagent-\*\.json')) `
    -Name "setup removes subagent lifecycle state"
$setupAst = [Management.Automation.Language.Parser]::ParseFile(
    $setupPath,
    [ref]$setupTokens,
    [ref]$setupParseErrors
)
if ($setupParseErrors.Count -ne 0) {
    throw "setup.ps1 has parse errors: $($setupParseErrors.Message -join '; ')"
}
$providerFileNames = @($script:CodexToastActivationFileNames | Where-Object {
    (Split-Path $_ -Parent) -ceq "providers"
} | ForEach-Object {
    [IO.Path]::GetFileName($_)
})
$ownedRuntimeFileNames = @($script:CodexToastActivationFileNames | Where-Object {
    [string]::IsNullOrEmpty((Split-Path $_ -Parent))
}) + @("secret.dat", "install.json", "last-activation-status.json")
$ownedRuntimeDirectoryNames = @("providers", "activations")
$ownedRuntimeNames = @($ownedRuntimeFileNames) + @($ownedRuntimeDirectoryNames)
foreach ($functionName in @(
    "Get-OwnedRuntimeChildEntries",
    "Test-OwnedRuntimeLayout",
    "Copy-OwnedActivationRecords",
    "Remove-CodexToastTransactionDirectory"
)) {
    $definition = $setupAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $functionName
    }, $true)
    if ($null -eq $definition) {
        throw "$functionName was not found in setup.ps1."
    }
    Invoke-Expression $definition.Extent.Text
}

$setupRuntime = Join-Path ([IO.Path]::GetTempPath()) "codex-windows-toast-setup-$([Guid]::NewGuid().ToString('N'))"
try {
    $providersDirectory = Join-Path $setupRuntime "providers"
    $activationsDirectory = Join-Path $setupRuntime "activations"
    [void][IO.Directory]::CreateDirectory($providersDirectory)
    [void][IO.Directory]::CreateDirectory($activationsDirectory)
    foreach ($name in $providerFileNames) {
        [IO.File]::WriteAllText((Join-Path $providersDirectory $name), "test")
    }
    $ownedRecordPath = Join-Path $activationsDirectory "$(('a' * 32)).json"
    $ownedRecordContent = '{"version":3}'
    [IO.File]::WriteAllText($ownedRecordPath, $ownedRecordContent)
    $temporaryRecordPath = Join-Path $activationsDirectory "$(('b' * 32)).tmp"
    [IO.File]::WriteAllText($temporaryRecordPath, "temporary")
    [void]@(Test-OwnedRuntimeLayout -Path $setupRuntime)

    $copiedActivationsDirectory = Join-Path $setupRuntime "copied-activations"
    [void][IO.Directory]::CreateDirectory($copiedActivationsDirectory)
    Copy-OwnedActivationRecords -SourcePath $activationsDirectory -DestinationPath $copiedActivationsDirectory
    $copiedRecordPath = Join-Path $copiedActivationsDirectory ([IO.Path]::GetFileName($ownedRecordPath))
    $copiedTemporaryRecordPath = Join-Path $copiedActivationsDirectory ([IO.Path]::GetFileName($temporaryRecordPath))
    Assert-Equal `
        -Expected $ownedRecordContent `
        -Actual ([IO.File]::ReadAllText($copiedRecordPath)) `
        -Name "setup preserves activation records during upgrade"
    Assert-Equal `
        -Expected $false `
        -Actual (Test-Path -LiteralPath $copiedTemporaryRecordPath) `
        -Name "setup does not preserve temporary activation records"
    Remove-Item -LiteralPath $copiedActivationsDirectory -Recurse -Force

    $unknownProviderPath = Join-Path $providersDirectory "unknown.ps1"
    [IO.File]::WriteAllText($unknownProviderPath, "test")
    Assert-Throws -Action {
        [void]@(Test-OwnedRuntimeLayout -Path $setupRuntime)
    } -Name "setup rejects unknown provider file"
    Remove-Item -LiteralPath $unknownProviderPath -Force

    [IO.File]::WriteAllBytes($ownedRecordPath, (New-Object byte[] ($script:CodexToastActivationRecordMaxBytes + 1)))
    Assert-Throws -Action {
        [void]@(Test-OwnedRuntimeLayout -Path $setupRuntime)
    } -Name "setup rejects oversized activation record"
    [IO.File]::WriteAllText($ownedRecordPath, $ownedRecordContent)

    Remove-CodexToastTransactionDirectory -Path $setupRuntime
    Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $setupRuntime) -Name "setup removes owned transaction layout"
}
finally {
    if (Test-Path -LiteralPath $setupRuntime) {
        Remove-Item -LiteralPath $setupRuntime -Recurse -Force
    }
}

if ($Integration) {
    $testData = Join-Path ([IO.Path]::GetTempPath()) "codex-windows-toast-$([Guid]::NewGuid().ToString('N'))"
    [void][IO.Directory]::CreateDirectory($testData)
    $sessionId = "unicode-integration"
    $turnId = "turn-1"
    $statePath = Join-Path $testData "turn-$sessionId-$turnId.json"
    $mismatchStatePath = Join-Path $testData "turn-mismatch-integration-turn-1.json"
    $subagentStatePath = Join-Path $testData "subagent-$sessionId-agent-1.json"
    $childStatePath1 = Join-Path $testData "turn-$sessionId-child-turn-1.json"
    $childStatePath2 = Join-Path $testData "turn-$sessionId-child-turn-2.json"
    $statusPath = Join-Path $testData "last-hook-status.json"
    try {
        $noStateJson = [ordered]@{
            hook_event_name = "Stop"
            session_id = "no-state-integration"
            turn_id = "turn-1"
            last_assistant_message = "No state"
        } | ConvertTo-Json -Compress
        $noStateResult = Invoke-HookScript -Json $noStateJson -PluginData $testData
        Assert-Equal -Expected 0 -Actual $noStateResult.ExitCode -Name "no-state Stop exit code"
        Assert-Equal -Expected '{"continue":true}' -Actual $noStateResult.Output -Name "no-state Stop output"
        $noStateStatus = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
        Assert-Equal -Expected "skipped-no-prompt" -Actual ([string]$noStateStatus.result) -Name "no-state Stop status"

        $mismatchPromptJson = [ordered]@{
            hook_event_name = "UserPromptSubmit"
            session_id = "mismatch-integration"
            turn_id = "turn-1"
            prompt = "Mismatched turn"
        } | ConvertTo-Json -Compress
        $mismatchPromptResult = Invoke-HookScript -Json $mismatchPromptJson -PluginData $testData
        Assert-Equal -Expected 0 -Actual $mismatchPromptResult.ExitCode -Name "mismatch prompt exit code"
        $mismatchStopJson = [ordered]@{
            hook_event_name = "Stop"
            session_id = "mismatch-integration"
            turn_id = "turn-2"
            last_assistant_message = "Mismatched turn"
        } | ConvertTo-Json -Compress
        $mismatchStopResult = Invoke-HookScript -Json $mismatchStopJson -PluginData $testData
        Assert-Equal -Expected 0 -Actual $mismatchStopResult.ExitCode -Name "mismatch Stop exit code"
        $mismatchStatus = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
        Assert-Equal -Expected "skipped-no-prompt" -Actual ([string]$mismatchStatus.result) -Name "mismatch Stop status"
        Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $mismatchStatePath) -Name "mismatch preserves other turn state"
        $compactSessionStartJson = [ordered]@{
            hook_event_name = "SessionStart"
            session_id = "mismatch-integration"
            source = "compact"
        } | ConvertTo-Json -Compress
        $compactSessionStartResult = Invoke-HookScript -Json $compactSessionStartJson -PluginData $testData
        Assert-Equal -Expected 0 -Actual $compactSessionStartResult.ExitCode -Name "compact SessionStart exit code"
        Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $mismatchStatePath) -Name "compact preserves turn state"
        $mismatchSessionEndJson = [ordered]@{
            hook_event_name = "SessionEnd"
            session_id = "mismatch-integration"
            reason = "test-complete"
        } | ConvertTo-Json -Compress
        $mismatchSessionEndResult = Invoke-HookScript -Json $mismatchSessionEndJson -PluginData $testData
        Assert-Equal -Expected 0 -Actual $mismatchSessionEndResult.ExitCode -Name "mismatch SessionEnd exit code"
        Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $mismatchStatePath) -Name "SessionEnd state cleanup"

        $promptJson = [ordered]@{
            hook_event_name = "UserPromptSubmit"
            session_id = $sessionId
            turn_id = $turnId
            prompt = "Unicode XML integration test"
        } | ConvertTo-Json -Compress
        $promptResult = Invoke-HookScript -Json $promptJson -PluginData $testData
        Assert-Equal -Expected 0 -Actual $promptResult.ExitCode -Name "prompt hook exit code"
        Assert-Equal -Expected '{"continue":true}' -Actual $promptResult.Output -Name "prompt hook output"
        $promptStatus = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
        Assert-Equal -Expected "prompt-saved" -Actual ([string]$promptStatus.result) -Name "prompt hook status"
        $mainTurnState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        Assert-Equal -Expected $false -Actual ([bool]$mainTurnState.suppress_notification) -Name "main prompt notification"
        $installedActivationContext = Get-CodexToastActivationContext
        if ($installedActivationContext.Installed -and $installedActivationContext.Current -and
            [Environment]::GetEnvironmentVariable("TERM_PROGRAM", "Process") -ieq "WezTerm") {
            $originProcessId = Get-CodexToastTerminalOriginProcessId
            Assert-Equal `
                -Expected $originProcessId `
                -Actual ([long]$mainTurnState.targets[0].pid) `
                -Name "main prompt uses WezTerm origin process"
            Assert-Equal `
                -Expected ([Environment]::GetEnvironmentVariable("WEZTERM_PANE", "Process")) `
                -Actual ([string]$mainTurnState.terminal.outer.locator.pane_id) `
                -Name "main prompt uses WezTerm environment pane"
        }

        $subagentStartJson = [ordered]@{
            hook_event_name = "SubagentStart"
            session_id = $sessionId
            turn_id = $turnId
            agent_id = "agent-1"
            agent_type = "default"
        } | ConvertTo-Json -Compress
        $subagentStartResult = Invoke-HookScript -Json $subagentStartJson -PluginData $testData
        Assert-Equal -Expected 0 -Actual $subagentStartResult.ExitCode -Name "SubagentStart exit code"
        Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $subagentStatePath) -Name "SubagentStart lifecycle state"

        $childPromptInvocations = @()
        foreach ($childTurnId in @("child-turn-1", "child-turn-2")) {
            $childPromptJson = [ordered]@{
                hook_event_name = "UserPromptSubmit"
                session_id = $sessionId
                turn_id = $childTurnId
                prompt = "Spawned branch $childTurnId"
            } | ConvertTo-Json -Compress
            $childPromptInvocations += [pscustomobject]@{
                TurnId = $childTurnId
                Invocation = Start-HookScript -Json $childPromptJson -PluginData $testData
            }
        }
        foreach ($childPromptInvocation in $childPromptInvocations) {
            $childPromptResult = Receive-HookScript -Invocation $childPromptInvocation.Invocation
            Assert-Equal `
                -Expected 0 `
                -Actual $childPromptResult.ExitCode `
                -Name "$($childPromptInvocation.TurnId) prompt exit code"
        }
        Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $childStatePath1) -Name "first concurrent turn state"
        Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $childStatePath2) -Name "second concurrent turn state"
        $childState1 = Get-Content -Raw -LiteralPath $childStatePath1 | ConvertFrom-Json
        $childState2 = Get-Content -Raw -LiteralPath $childStatePath2 | ConvertFrom-Json
        Assert-Equal -Expected $true -Actual ([bool]$childState1.suppress_notification) -Name "first subagent prompt suppression"
        Assert-Equal -Expected $true -Actual ([bool]$childState2.suppress_notification) -Name "second subagent prompt suppression"

        $childStopJson1 = [ordered]@{
            hook_event_name = "Stop"
            session_id = $sessionId
            turn_id = "child-turn-1"
            last_assistant_message = "First branch finished"
        } | ConvertTo-Json -Compress
        $childStopResult1 = Invoke-HookScript -Json $childStopJson1 -PluginData $testData
        Assert-Equal -Expected 0 -Actual $childStopResult1.ExitCode -Name "first subagent Stop exit code"
        $childStopStatus1 = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
        Assert-Equal -Expected "skipped-subagent" -Actual ([string]$childStopStatus1.result) -Name "first subagent Stop status"
        Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $childStatePath1) -Name "first subagent state cleanup"
        Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $childStatePath2) -Name "first Stop preserves concurrent turn"
        Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $statePath) -Name "first Stop preserves main turn"

        $childStopJson2 = [ordered]@{
            hook_event_name = "Stop"
            session_id = $sessionId
            turn_id = "child-turn-2"
            last_assistant_message = "Second branch finished"
        } | ConvertTo-Json -Compress
        $childStopResult2 = Invoke-HookScript -Json $childStopJson2 -PluginData $testData
        Assert-Equal -Expected 0 -Actual $childStopResult2.ExitCode -Name "second subagent Stop exit code"
        $childStopStatus2 = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
        Assert-Equal -Expected "skipped-subagent" -Actual ([string]$childStopStatus2.result) -Name "second subagent Stop status"
        Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $childStatePath2) -Name "second subagent state cleanup"
        Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $statePath) -Name "second Stop preserves main turn"

        $subagentStopJson = [ordered]@{
            hook_event_name = "SubagentStop"
            session_id = $sessionId
            turn_id = $turnId
            agent_id = "agent-1"
            agent_type = "default"
            last_assistant_message = "Branches complete"
        } | ConvertTo-Json -Compress
        $subagentStopResult = Invoke-HookScript -Json $subagentStopJson -PluginData $testData
        Assert-Equal -Expected 0 -Actual $subagentStopResult.ExitCode -Name "SubagentStop exit code"
        Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $subagentStatePath) -Name "SubagentStop lifecycle cleanup"

        $message = ("a" * 236) + $emoji + [string][char]0x1 + "tail"
        $stopJson = [ordered]@{
            hook_event_name = "Stop"
            session_id = $sessionId
            turn_id = $turnId
            last_assistant_message = $message
        } | ConvertTo-Json -Compress
        $stopResult = Invoke-HookScript -Json $stopJson -PluginData $testData
        Assert-Equal -Expected 0 -Actual $stopResult.ExitCode -Name "Stop hook exit code"
        Assert-Equal -Expected '{"continue":true}' -Actual $stopResult.Output -Name "Stop hook output"

        $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
        if ([string]$status.result -cne "toast-sent") {
            throw "Stop hook status failed. Event: $($status.event). Session: $($status.session_id). Turn: $($status.turn_id). Result: $($status.result). Error: $($status.error)"
        }
        Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $statePath) -Name "turn state cleanup"
    }
    finally {
        foreach ($path in @(
            $statePath,
            $mismatchStatePath,
            $subagentStatePath,
            $childStatePath1,
            $childStatePath2,
            $statusPath
        )) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        if ((Test-Path -LiteralPath $testData -PathType Container) -and
            @(Get-ChildItem -Force -LiteralPath $testData).Count -eq 0) {
            [IO.Directory]::Delete($testData)
        }
    }
}

Write-Output "All tests passed."
