$script:CodexToastProtocol = "codex-windows-toast"
$script:CodexToastOwner = "codex-windows-toast"
$script:CodexToastActivationRecordSchemaVersion = 2
$script:CodexToastActivationComponentVersion = 1
$script:CodexToastActivationSourcePath = $PSScriptRoot
$script:CodexToastActivationFileNames = @(
    "activate-window.ps1",
    "launch-hidden.vbs",
    "activation-common.ps1"
)

function Get-CodexToastRuntimePath {
    return Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "CodexWindowsToast"
}

function Get-CodexToastHandlerPath {
    return Join-Path (Get-CodexToastRuntimePath) "activate-window.ps1"
}

function Get-CodexToastLauncherPath {
    return Join-Path (Get-CodexToastRuntimePath) "launch-hidden.vbs"
}

function Get-CodexToastActivationComponent {
    param(
        [Parameter(Mandatory)]
        [string]$BasePath
    )

    $fileHashes = [ordered]@{}
    foreach ($name in $script:CodexToastActivationFileNames) {
        $path = Join-Path $BasePath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Activation component file is missing: $path"
        }

        $stream = [IO.File]::Open(
            $path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $fileHasher = [Security.Cryptography.SHA256]::Create()
        try {
            $fileHashes[$name] = ([BitConverter]::ToString($fileHasher.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
        }
        finally {
            $fileHasher.Dispose()
            $stream.Dispose()
        }
    }

    $fingerprintLines = @("component_version=$script:CodexToastActivationComponentVersion")
    foreach ($name in $script:CodexToastActivationFileNames) {
        $fingerprintLines += "$name=$($fileHashes[$name])"
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $fingerprintBytes = [Text.Encoding]::UTF8.GetBytes(($fingerprintLines -join "`n"))
        $fingerprint = ([BitConverter]::ToString($sha256.ComputeHash($fingerprintBytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    return [pscustomobject]@{
        Version = $script:CodexToastActivationComponentVersion
        Fingerprint = $fingerprint
        FileHashes = $fileHashes
    }
}

function Test-CodexToastActivationComponentRecord {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)]$Component
    )

    if ([int]$Record.schema_version -ne $script:CodexToastActivationRecordSchemaVersion -or
        [int]$Record.activation_component_version -ne $Component.Version -or
        [string]$Record.activation_component_fingerprint -cne $Component.Fingerprint -or
        $null -eq $Record.file_hashes) {
        throw "The activation component is out of date. Run setup.ps1 -Install again."
    }

    foreach ($name in $script:CodexToastActivationFileNames) {
        $property = $Record.file_hashes.PSObject.Properties[$name]
        if ($null -eq $property -or [string]$property.Value -cne [string]$Component.FileHashes[$name]) {
            throw "The activation component is out of date. Run setup.ps1 -Install again."
        }
    }
}

function Get-CodexToastRegistryCommand {
    param([string]$LauncherPath = (Get-CodexToastLauncherPath))

    $wscriptPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) "wscript.exe"
    return "`"$wscriptPath`" //B //NoLogo `"$LauncherPath`" `"%1`""
}

function Get-CodexToastLegacyRegistryCommand {
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
    $launcherPath = Get-CodexToastLauncherPath
    $commonPath = Join-Path $runtimePath "activation-common.ps1"
    $secretPath = Join-Path $runtimePath "secret.dat"

    try {
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            throw "Activation component is not installed."
        }

        $record = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$record.launcher_path)) {
            throw "The activation component needs to be reinstalled."
        }

        $expectedCommand = Get-CodexToastRegistryCommand -LauncherPath $launcherPath
        if ([string]$record.owner -cne $script:CodexToastOwner -or
            [string]$record.protocol -cne $script:CodexToastProtocol -or
            [IO.Path]::GetFullPath([string]$record.handler_path) -cne [IO.Path]::GetFullPath($handlerPath) -or
            [IO.Path]::GetFullPath([string]$record.launcher_path) -cne [IO.Path]::GetFullPath($launcherPath) -or
            [string]$record.command -cne $expectedCommand) {
            throw "The activation install record is not owned by this plugin."
        }

        foreach ($path in @($handlerPath, $launcherPath, $commonPath, $secretPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Activation component file is missing: $path"
            }
        }

        if ((Get-CodexToastRegisteredCommand) -cne $expectedCommand) {
            throw "The registered protocol command does not match this installation."
        }

        try {
            $sourceComponent = Get-CodexToastActivationComponent -BasePath $script:CodexToastActivationSourcePath
            $runtimeComponent = Get-CodexToastActivationComponent -BasePath $runtimePath
            Test-CodexToastActivationComponentRecord -Record $record -Component $sourceComponent
            Test-CodexToastActivationComponentRecord -Record $record -Component $runtimeComponent
            if ($sourceComponent.Fingerprint -cne $runtimeComponent.Fingerprint) {
                throw "The activation component is out of date. Run setup.ps1 -Install again."
            }

            return [pscustomobject]@{
                Installed = $true
                Current = $true
                RuntimePath = $runtimePath
                HandlerPath = $handlerPath
                LauncherPath = $launcherPath
                SecretPath = $secretPath
                Record = $record
                Error = ""
            }
        }
        catch {
            return [pscustomobject]@{
                Installed = $true
                Current = $false
                RuntimePath = $runtimePath
                HandlerPath = $handlerPath
                LauncherPath = $launcherPath
                SecretPath = $secretPath
                Record = $record
                Error = $_.Exception.Message
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Installed = $false
            Current = $false
            RuntimePath = $runtimePath
            HandlerPath = $handlerPath
            LauncherPath = $launcherPath
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

function ConvertTo-CodexToastActivationTargets {
    param(
        [Parameter(Mandatory)][object[]]$Targets
    )

    $items = @($Targets)
    if ($items.Count -lt 1 -or $items.Count -gt 8) {
        throw "Activation targets must contain between 1 and 8 windows."
    }

    $seenWindows = @{}
    $records = foreach ($target in $items) {
        $hwndText = [string]$target.hwnd
        $processIdText = [string]$target.pid
        $startedText = [string]$target.started_utc_ticks
        [long]$window = 0
        [uint32]$processId = 0
        [long]$started = 0
        if ($hwndText -notmatch "^[1-9][0-9]{0,18}$" -or
            $processIdText -notmatch "^[1-9][0-9]{0,9}$" -or
            $startedText -notmatch "^[1-9][0-9]{0,18}$" -or
            -not [long]::TryParse($hwndText, [ref]$window) -or
            -not [uint32]::TryParse($processIdText, [ref]$processId) -or
            -not [long]::TryParse($startedText, [ref]$started) -or
            $window -le 0 -or $processId -eq 0 -or $started -le 0) {
            throw "Invalid activation target."
        }

        if ($seenWindows.ContainsKey($hwndText)) {
            throw "Duplicate activation target."
        }
        $seenWindows[$hwndText] = $true

        "$hwndText.$processIdText.$startedText"
    }

    return $records -join "~"
}

function ConvertFrom-CodexToastActivationTargets {
    param(
        [Parameter(Mandatory)][string]$Value
    )

    if ($Value -notmatch "^[1-9][0-9]{0,18}\.[1-9][0-9]{0,9}\.[1-9][0-9]{0,18}(~[1-9][0-9]{0,18}\.[1-9][0-9]{0,9}\.[1-9][0-9]{0,18}){0,7}$") {
        throw "Invalid activation targets."
    }

    $seenWindows = @{}
    $targets = foreach ($record in $Value.Split("~")) {
        $parts = $record.Split(".")
        [long]$window = 0
        [uint32]$processId = 0
        [long]$started = 0
        if ($parts.Count -ne 3 -or
            -not [long]::TryParse($parts[0], [ref]$window) -or
            -not [uint32]::TryParse($parts[1], [ref]$processId) -or
            -not [long]::TryParse($parts[2], [ref]$started) -or
            $window -le 0 -or $processId -eq 0 -or $started -le 0) {
            throw "Invalid activation target."
        }

        if ($seenWindows.ContainsKey($parts[0])) {
            throw "Duplicate activation target."
        }
        $seenWindows[$parts[0]] = $true

        [pscustomobject]@{
            hwnd = $window
            pid = [long]$processId
            started_utc_ticks = $started
        }
    }

    return $targets
}

function New-CodexToastActivationUri {
    param(
        [Parameter(Mandatory)][object[]]$Targets,
        [Parameter(Mandatory)]$Context
    )

    $serializedTargets = ConvertTo-CodexToastActivationTargets -Targets $Targets
    $payload = "v=2&targets=$serializedTargets"
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
