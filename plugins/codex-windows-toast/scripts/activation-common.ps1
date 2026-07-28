$script:CodexToastProtocol = "codex-windows-toast"
$script:CodexToastOwner = "codex-windows-toast"

function Get-CodexToastRuntimePath {
    return Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "CodexWindowsToast"
}

function Get-CodexToastHandlerPath {
    return Join-Path (Get-CodexToastRuntimePath) "activate-window.ps1"
}

function Get-CodexToastRegistryCommand {
    param([string]$HandlerPath = (Get-CodexToastHandlerPath))

    return "powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$HandlerPath`" `"%1`""
}

function Get-CodexToastRegisteredCommand {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        "Software\Classes\$script:CodexToastProtocol\shell\open\command"
    )
    if ($null -eq $key) {
        return $null
    }

    try {
        return [string]$key.GetValue("")
    }
    finally {
        $key.Dispose()
    }
}

function Get-CodexToastActivationContext {
    $runtimePath = Get-CodexToastRuntimePath
    $recordPath = Join-Path $runtimePath "install.json"
    $handlerPath = Get-CodexToastHandlerPath
    $commonPath = Join-Path $runtimePath "activation-common.ps1"
    $secretPath = Join-Path $runtimePath "secret.dat"

    try {
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            throw "Activation component is not installed."
        }

        $record = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
        $expectedCommand = Get-CodexToastRegistryCommand -HandlerPath $handlerPath
        if ([string]$record.owner -cne $script:CodexToastOwner -or
            [string]$record.protocol -cne $script:CodexToastProtocol -or
            [IO.Path]::GetFullPath([string]$record.handler_path) -cne [IO.Path]::GetFullPath($handlerPath) -or
            [string]$record.command -cne $expectedCommand) {
            throw "The activation install record is not owned by this plugin."
        }

        foreach ($path in @($handlerPath, $commonPath, $secretPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Activation component file is missing: $path"
            }
        }

        if ((Get-CodexToastRegisteredCommand) -cne $expectedCommand) {
            throw "The registered protocol command does not match this installation."
        }

        return [pscustomobject]@{
            Installed = $true
            RuntimePath = $runtimePath
            HandlerPath = $handlerPath
            SecretPath = $secretPath
            Record = $record
            Error = ""
        }
    }
    catch {
        return [pscustomobject]@{
            Installed = $false
            RuntimePath = $runtimePath
            HandlerPath = $handlerPath
            SecretPath = $secretPath
            Record = $null
            Error = $_.Exception.Message
        }
    }
}

function Get-CodexToastSecret {
    param([Parameter(Mandatory)][string]$Path)

    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $protectedBytes = [Convert]::FromBase64String((Get-Content -Raw -LiteralPath $Path).Trim())
    return [Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
}

function Get-CodexToastHmacHex {
    param(
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][string]$Payload
    )

    $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (,$Key)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Payload)
        return ([BitConverter]::ToString($hmac.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $hmac.Dispose()
    }
}

function Test-CodexToastSignature {
    param(
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Actual
    )

    if ($Expected.Length -ne $Actual.Length) {
        return $false
    }

    $difference = 0
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        $difference = $difference -bor ([int][char]$Expected[$index] -bxor [int][char]$Actual[$index])
    }

    return $difference -eq 0
}

function New-CodexToastActivationUri {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Context
    )

    $payload = "v=1&hwnd=$($Target.hwnd)&pid=$($Target.pid)&started=$($Target.started_utc_ticks)"
    $secret = Get-CodexToastSecret -Path $Context.SecretPath
    try {
        $signature = Get-CodexToastHmacHex -Key $secret -Payload $payload
    }
    finally {
        [Array]::Clear($secret, 0, $secret.Length)
    }

    return "${script:CodexToastProtocol}://activate?$payload&sig=$signature"
}

function Write-CodexToastActivationStatus {
    param(
        [Parameter(Mandatory)][string]$Result,
        [AllowEmptyString()][string]$Detail = ""
    )

    try {
        [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString("o")
            result = $Result
            detail = $Detail
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Get-CodexToastRuntimePath) "last-activation-status.json") -Encoding UTF8
    }
    catch {
        # Activation diagnostics must not surface a second error.
    }
}
