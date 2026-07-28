[CmdletBinding()]
param(
    [switch]$Test
)

$ErrorActionPreference = "Stop"

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

    $singleLine = [regex]::Replace($Text, "\s+", " ").Trim()
    if ($singleLine.Length -le $MaxLength) {
        return $singleLine
    }

    return $singleLine.Substring(0, $MaxLength - 3) + "..."
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
        [string]$Message
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
    $toastXml = @"
<toast duration="short">
  <visual>
    <binding template="ToastGeneric">
      <text>$escapedTitle</text>
      <text>$escapedMessage</text>
      <text placement="attribution">Codex CLI</text>
    </binding>
  </visual>
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
        Send-CodexToast -Title "Codex is ready" -Message "Windows toast notifications are working."
    }
    else {
        $rawInput = [Console]::In.ReadToEnd()
        $hookInput = $rawInput | ConvertFrom-Json
        $eventName = [string]$hookInput.hook_event_name
        $sessionId = [string]$hookInput.session_id
        $turnId = [string]$hookInput.turn_id

        if ($eventName -eq "UserPromptSubmit") {
            $pluginData = Get-PluginDataPath
            New-Item -ItemType Directory -Path $pluginData -Force | Out-Null
            [ordered]@{
                turn_id = $turnId
                title = ConvertTo-ToastText -Text ([string]$hookInput.prompt) -MaxLength 120
            } | ConvertTo-Json | Set-Content -LiteralPath (Get-SessionStatePath -SessionId $sessionId) -Encoding UTF8
            Write-HookStatus -EventName $eventName -SessionId $sessionId -TurnId $turnId -Result "prompt-saved"
            [Console]::Out.WriteLine('{"continue":true}')
            exit 0
        }

        if ($eventName -ne "Stop") {
            [Console]::Out.WriteLine('{"continue":true}')
            exit 0
        }

        $title = "Codex is ready"
        $statePath = Get-SessionStatePath -SessionId $sessionId
        if (Test-Path -LiteralPath $statePath) {
            $turnState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
            if ([string]$turnState.turn_id -eq $turnId -and -not [string]::IsNullOrWhiteSpace([string]$turnState.title)) {
                $title = [string]$turnState.title
            }
        }

        $message = ConvertTo-ToastText -Text ([string]$hookInput.last_assistant_message) -MaxLength 240
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "The current turn has finished."
        }

        Send-CodexToast -Title $title -Message $message
        Write-HookStatus -EventName $eventName -SessionId $sessionId -TurnId $turnId -Result "toast-sent"
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
