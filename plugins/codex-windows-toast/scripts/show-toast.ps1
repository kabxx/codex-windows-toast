[CmdletBinding()]
param(
    [switch]$Test
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "activation-common.ps1")

if (-not ("CodexWindowsToast.WindowCapture" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace CodexWindowsToast {
    public static class WindowCapture {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("kernel32.dll")]
        public static extern ushort GetUserDefaultUILanguage();
    }
}
"@
}

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

function Get-WindowsUserUICultureName {
    try {
        $languageId = [CodexWindowsToast.WindowCapture]::GetUserDefaultUILanguage()
        if ($languageId -ne 0) {
            return ([Globalization.CultureInfo]::GetCultureInfo([int]$languageId)).Name
        }
    }
    catch {
    }

    try {
        $cultureName = [Globalization.CultureInfo]::CurrentCulture.Name
        if (-not [string]::IsNullOrWhiteSpace($cultureName)) {
            return $cultureName
        }
    }
    catch {
    }

    return "en"
}

function Get-ToastActionLabels {
    param(
        [string]$CultureName = (Get-WindowsUserUICultureName)
    )

    try {
        $language = ([Globalization.CultureInfo]::GetCultureInfo($CultureName)).TwoLetterISOLanguageName.ToLowerInvariant()
    }
    catch {
        $language = "en"
    }

    switch ($language) {
        "ar" { return @{ Return = "&#x0631;&#x062C;&#x0648;&#x0639;"; Dismiss = "&#x0625;&#x063A;&#x0644;&#x0627;&#x0642;" } }
        "cs" { return @{ Return = "Zp&#x011B;t"; Dismiss = "Zav&#x0159;&#x00ED;t" } }
        "da" { return @{ Return = "Tilbage"; Dismiss = "Luk" } }
        "de" { return @{ Return = "Zur&#x00FC;ck"; Dismiss = "Schlie&#x00DF;en" } }
        "es" { return @{ Return = "Volver"; Dismiss = "Cerrar" } }
        "fi" { return @{ Return = "Takaisin"; Dismiss = "Sulje" } }
        "fr" { return @{ Return = "Retour"; Dismiss = "Fermer" } }
        "he" { return @{ Return = "&#x05D7;&#x05D6;&#x05E8;&#x05D4;"; Dismiss = "&#x05E1;&#x05D2;&#x05D5;&#x05E8;" } }
        "hi" { return @{ Return = "&#x0935;&#x093E;&#x092A;&#x0938;"; Dismiss = "&#x092C;&#x0902;&#x0926;" } }
        "id" { return @{ Return = "Kembali"; Dismiss = "Tutup" } }
        "it" { return @{ Return = "Indietro"; Dismiss = "Chiudi" } }
        "ja" { return @{ Return = "&#x623B;&#x308B;"; Dismiss = "&#x9589;&#x3058;&#x308B;" } }
        "ko" { return @{ Return = "&#xB3CC;&#xC544;&#xAC00;&#xAE30;"; Dismiss = "&#xB2EB;&#xAE30;" } }
        "nb" { return @{ Return = "Tilbake"; Dismiss = "Lukk" } }
        "nl" { return @{ Return = "Terug"; Dismiss = "Sluiten" } }
        "no" { return @{ Return = "Tilbake"; Dismiss = "Lukk" } }
        "pl" { return @{ Return = "Wr&#x00F3;&#x0107;"; Dismiss = "Zamknij" } }
        "pt" { return @{ Return = "Voltar"; Dismiss = "Fechar" } }
        "ru" { return @{ Return = "&#x041D;&#x0430;&#x0437;&#x0430;&#x0434;"; Dismiss = "&#x0417;&#x0430;&#x043A;&#x0440;&#x044B;&#x0442;&#x044C;" } }
        "sv" { return @{ Return = "Tillbaka"; Dismiss = "St&#x00E4;ng" } }
        "th" { return @{ Return = "&#x0E01;&#x0E25;&#x0E31;&#x0E1A;"; Dismiss = "&#x0E1B;&#x0E34;&#x0E14;" } }
        "tr" { return @{ Return = "D&#x00F6;n"; Dismiss = "Kapat" } }
        "uk" { return @{ Return = "&#x041D;&#x0430;&#x0437;&#x0430;&#x0434;"; Dismiss = "&#x0417;&#x0430;&#x043A;&#x0440;&#x0438;&#x0442;&#x0438;" } }
        "vi" { return @{ Return = "Quay l&#x1EA1;i"; Dismiss = "B&#x1ECF; qua" } }
        "zh" { return @{ Return = "&#x8FD4;&#x56DE;"; Dismiss = "&#x5FFD;&#x7565;" } }
        default { return @{ Return = "Return"; Dismiss = "Dismiss" } }
    }
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

function Get-ForegroundWindowTarget {
    try {
        $window = [CodexWindowsToast.WindowCapture]::GetForegroundWindow()
        if ($window -eq [IntPtr]::Zero) {
            return $null
        }

        $rootWindow = [CodexWindowsToast.WindowCapture]::GetAncestor($window, 2)
        if ($rootWindow -ne [IntPtr]::Zero) {
            $window = $rootWindow
        }

        [uint32]$processId = 0
        [void][CodexWindowsToast.WindowCapture]::GetWindowThreadProcessId($window, [ref]$processId)
        if ($processId -eq 0) {
            return $null
        }

        $process = Get-Process -Id $processId -ErrorAction Stop
        return [pscustomobject]@{
            hwnd = $window.ToInt64()
            pid = [long]$processId
            started_utc_ticks = $process.StartTime.ToUniversalTime().Ticks
        }
    }
    catch {
        return $null
    }
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
        [string]$Message,
        [AllowEmptyString()]
        [string]$ActivationUri = ""
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
    $actionsXml = ""
    $toastAttributes = 'duration="long"'
    if (-not [string]::IsNullOrWhiteSpace($ActivationUri)) {
        $escapedActivationUri = [System.Security.SecurityElement]::Escape($ActivationUri)
        $ignoredUri = [System.Security.SecurityElement]::Escape("${script:CodexToastProtocol}://ignore")
        $actionLabels = Get-ToastActionLabels
        $toastAttributes += " launch=`"$ignoredUri`" activationType=`"protocol`""
        $actionsXml = @"
    <actions>
      <action content="$($actionLabels.Return)" arguments="$escapedActivationUri" activationType="protocol" />
      <action content="$($actionLabels.Dismiss)" arguments="dismiss" activationType="system" />
    </actions>
"@
    }

    $toastXml = @"
<toast $toastAttributes>
  <visual>
    <binding template="ToastGeneric">
      <text>$escapedTitle</text>
      <text>$escapedMessage</text>
      <text placement="attribution">Codex CLI</text>
    </binding>
  </visual>
$actionsXml
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
        $activationUri = ""
        $target = Get-ForegroundWindowTarget
        $activationContext = Get-CodexToastActivationContext
        if ($null -ne $target -and $activationContext.Installed) {
            try {
                $activationUri = New-CodexToastActivationUri -Target $target -Context $activationContext
            }
            catch {
                $activationUri = ""
            }
        }

        Send-CodexToast -Title "Codex is ready" -Message "Windows toast notifications are working." -ActivationUri $activationUri
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
            $target = Get-ForegroundWindowTarget
            $turnState = [ordered]@{
                turn_id = $turnId
                title = ConvertTo-ToastText -Text ([string]$hookInput.prompt) -MaxLength 120
            }
            if ($null -ne $target) {
                $turnState.hwnd = $target.hwnd
                $turnState.pid = $target.pid
                $turnState.started_utc_ticks = $target.started_utc_ticks
            }

            $turnState | ConvertTo-Json | Set-Content -LiteralPath (Get-SessionStatePath -SessionId $sessionId) -Encoding UTF8
            Write-HookStatus -EventName $eventName -SessionId $sessionId -TurnId $turnId -Result "prompt-saved"
            [Console]::Out.WriteLine('{"continue":true}')
            exit 0
        }

        if ($eventName -ne "Stop") {
            [Console]::Out.WriteLine('{"continue":true}')
            exit 0
        }

        $title = ""
        $activationUri = ""
        $statePath = Get-SessionStatePath -SessionId $sessionId
        if (Test-Path -LiteralPath $statePath) {
            $turnState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
            if ([string]$turnState.turn_id -eq $turnId -and -not [string]::IsNullOrWhiteSpace([string]$turnState.title)) {
                $title = [string]$turnState.title

                $activationContext = Get-CodexToastActivationContext
                if ($activationContext.Installed -and
                    [long]$turnState.hwnd -gt 0 -and
                    [long]$turnState.pid -gt 0 -and
                    [long]$turnState.started_utc_ticks -gt 0) {
                    $target = [pscustomobject]@{
                        hwnd = [long]$turnState.hwnd
                        pid = [long]$turnState.pid
                        started_utc_ticks = [long]$turnState.started_utc_ticks
                    }
                    try {
                        $activationUri = New-CodexToastActivationUri -Target $target -Context $activationContext
                    }
                    catch {
                        $activationUri = ""
                    }
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($title)) {
            if (Test-Path -LiteralPath $statePath -PathType Leaf) {
                Remove-Item -LiteralPath $statePath -Force
            }
            Write-HookStatus -EventName $eventName -SessionId $sessionId -TurnId $turnId -Result "skipped-no-prompt"
            [Console]::Out.WriteLine('{"continue":true}')
            exit 0
        }

        $message = ConvertTo-ToastText -Text ([string]$hookInput.last_assistant_message) -MaxLength 240
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "The current turn has finished."
        }

        Send-CodexToast -Title $title -Message $message -ActivationUri $activationUri
        Write-HookStatus -EventName $eventName -SessionId $sessionId -TurnId $turnId -Result "toast-sent"
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            Remove-Item -LiteralPath $statePath -Force
        }
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
