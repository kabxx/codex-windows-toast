[CmdletBinding()]
param(
    [switch]$Integration
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptRoot = Join-Path $repoRoot "plugins\codex-windows-toast\scripts"
$showToastPath = Join-Path $scriptRoot "show-toast.ps1"
$commonPath = Join-Path $scriptRoot "activation-common.ps1"

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
