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

function Invoke-HookScript {
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
$component = Get-CodexToastActivationComponent -BasePath $scriptRoot
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

$secretPath = [IO.Path]::GetTempFileName()
$secret = [Text.Encoding]::UTF8.GetBytes("codex-window-target-test-secret-32")
try {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $protectedSecret = [Security.Cryptography.ProtectedData]::Protect(
        $secret,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [Convert]::ToBase64String($protectedSecret) | Set-Content -LiteralPath $secretPath -Encoding ASCII
    $activationUri = New-CodexToastActivationUri -Targets $activationTargets -Context ([pscustomobject]@{
        SecretPath = $secretPath
    })
    Assert-Equal -Expected $true -Actual ([bool]($activationUri -cmatch '^codex-windows-toast://activate\?v=2&targets=101\.201\.301~102\.202\.302&sig=[0-9a-f]{64}$')) -Name "v2 activation URI"
}
finally {
    [Array]::Clear($secret, 0, $secret.Length)
    Remove-Item -LiteralPath $secretPath -Force -ErrorAction SilentlyContinue
}

$launcherText = Get-Content -Raw -LiteralPath $launcherPath
Assert-Equal -Expected $true -Actual ([bool]($launcherText -cmatch 'v=2&targets=')) -Name "launcher accepts v2 targets"
Assert-Equal -Expected $false -Actual ([bool]($launcherText -cmatch 'v=1&hwnd=')) -Name "launcher rejects legacy v1 URI"
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

if ($Integration) {
    $testData = Join-Path ([IO.Path]::GetTempPath()) "codex-windows-toast-$([Guid]::NewGuid().ToString('N'))"
    [void][IO.Directory]::CreateDirectory($testData)
    $sessionId = "unicode-integration"
    $statePath = Join-Path $testData "turn-$sessionId.json"
    $mismatchStatePath = Join-Path $testData "turn-mismatch-integration.json"
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
        Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $mismatchStatePath) -Name "mismatch state cleanup"

        $turnId = "turn-1"
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
        foreach ($path in @($statePath, $mismatchStatePath, $statusPath)) {
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
