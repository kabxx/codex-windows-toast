[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = "Status")]
param(
    [Parameter(Mandatory, ParameterSetName = "Install")]
    [switch]$Install,

    [Parameter(Mandatory, ParameterSetName = "Uninstall")]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = "Status")]
    [switch]$Status
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "activation-common.ps1")

$runtimePath = Get-CodexToastRuntimePath
$handlerPath = Get-CodexToastHandlerPath
$commonPath = Join-Path $runtimePath "activation-common.ps1"
$secretPath = Join-Path $runtimePath "secret.dat"
$recordPath = Join-Path $runtimePath "install.json"
$protocolKey = "Software\Classes\$script:CodexToastProtocol"
$sourceHandler = Join-Path $PSScriptRoot "activate-window.ps1"
$sourceCommon = Join-Path $PSScriptRoot "activation-common.ps1"
$pluginManifest = Join-Path (Split-Path $PSScriptRoot -Parent) ".codex-plugin\plugin.json"

function Get-SetupStatus {
    $context = Get-CodexToastActivationContext
    $lastResult = ""
    $lastStatusPath = Join-Path $runtimePath "last-activation-status.json"
    if (Test-Path -LiteralPath $lastStatusPath -PathType Leaf) {
        try {
            $lastResult = [string](Get-Content -Raw -LiteralPath $lastStatusPath | ConvertFrom-Json).result
        }
        catch {
            $lastResult = "unreadable"
        }
    }

    return [pscustomobject]@{
        Installed = $context.Installed
        Protocol = $script:CodexToastProtocol
        RuntimePath = $runtimePath
        LastActivation = $lastResult
        Detail = $context.Error
    }
}

function Test-OwnedRuntimeDirectory {
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Container)) {
        return
    }

    $runtimeDirectory = Get-Item -Force -LiteralPath $runtimePath
    if (($runtimeDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$runtimePath is a reparse point and will not be modified."
    }

    $entries = @(Get-ChildItem -Force -LiteralPath $runtimePath)
    if ($entries.Count -eq 0) {
        return
    }

    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        throw "$runtimePath contains files but has no plugin install record."
    }

    $record = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
    if ([string]$record.owner -cne $script:CodexToastOwner -or
        [string]$record.protocol -cne $script:CodexToastProtocol) {
        throw "$runtimePath is not owned by this plugin."
    }

    $ownedNames = @(
        "activate-window.ps1",
        "activation-common.ps1",
        "secret.dat",
        "install.json",
        "last-activation-status.json"
    )
    $unknownEntries = @($entries | Where-Object { $_.Name -notin $ownedNames })
    if ($unknownEntries.Count -ne 0) {
        throw "$runtimePath contains files not owned by this plugin: $($unknownEntries.Name -join ', ')"
    }
}

function Test-ProtocolKeyExists {
    $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($protocolKey)
    if ($null -eq $root) {
        return $false
    }

    $root.Dispose()
    return $true
}

function Test-OwnedRegistryLayout {
    $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($protocolKey)
    if ($null -eq $root) {
        return $false
    }

    try {
        $command = Get-CodexToastRegisteredCommand
        if ($command -cne (Get-CodexToastRegistryCommand -HandlerPath $handlerPath)) {
            throw "The existing $script:CodexToastProtocol protocol is not owned by this installation."
        }

        if (@($root.GetSubKeyNames() | Where-Object { $_ -cne "shell" }).Count -ne 0 -or
            @($root.GetValueNames() | Where-Object { $_ -cne "" -and $_ -cne "URL Protocol" }).Count -ne 0 -or
            [string]$root.GetValue("") -cne "URL:Codex Windows Toast" -or
            [string]$root.GetValue("URL Protocol") -cne "") {
            throw "The protocol key contains unknown values or subkeys."
        }

        foreach ($relativePath in @("shell", "shell\open")) {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$protocolKey\$relativePath")
            if ($null -eq $key) {
                throw "The protocol registration is incomplete."
            }
            try {
                $expectedChild = if ($relativePath -eq "shell") { "open" } else { "command" }
                if (@($key.GetSubKeyNames() | Where-Object { $_ -cne $expectedChild }).Count -ne 0 -or $key.GetValueNames().Count -ne 0) {
                    throw "The protocol key contains unknown values or subkeys."
                }
            }
            finally {
                $key.Dispose()
            }
        }

        $commandKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$protocolKey\shell\open\command")
        try {
            if ($null -eq $commandKey -or
                $commandKey.GetSubKeyNames().Count -ne 0 -or
                @($commandKey.GetValueNames() | Where-Object { $_ -cne "" }).Count -ne 0) {
                throw "The protocol command key contains unknown content."
            }
        }
        finally {
            if ($null -ne $commandKey) {
                $commandKey.Dispose()
            }
        }

        return $true
    }
    finally {
        $root.Dispose()
    }
}

function Install-ActivationComponent {
    foreach ($sourcePath in @($sourceHandler, $sourceCommon, $pluginManifest)) {
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required source file is missing: $sourcePath"
        }
    }

    Test-OwnedRuntimeDirectory
    if (Test-ProtocolKeyExists) {
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            throw "The $script:CodexToastProtocol protocol already exists without this plugin's install record."
        }
        [void](Test-OwnedRegistryLayout)
    }

    if ($PSCmdlet.ShouldProcess($runtimePath, "Install window activation files")) {
        New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
        Copy-Item -LiteralPath $sourceHandler -Destination $handlerPath -Force
        Copy-Item -LiteralPath $sourceCommon -Destination $commonPath -Force

        if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $secret = New-Object byte[] 32
            $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
            try {
                $generator.GetBytes($secret)
                $protected = [Security.Cryptography.ProtectedData]::Protect(
                    $secret,
                    $null,
                    [Security.Cryptography.DataProtectionScope]::CurrentUser
                )
                [Convert]::ToBase64String($protected) | Set-Content -LiteralPath $secretPath -Encoding ASCII
            }
            finally {
                $generator.Dispose()
                [Array]::Clear($secret, 0, $secret.Length)
            }
        }
    }

    $command = Get-CodexToastRegistryCommand -HandlerPath $handlerPath
    if ($PSCmdlet.ShouldProcess("HKCU\$protocolKey", "Register the $script:CodexToastProtocol URI protocol")) {
        $root = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($protocolKey)
        try {
            $root.SetValue("", "URL:Codex Windows Toast", [Microsoft.Win32.RegistryValueKind]::String)
            $root.SetValue("URL Protocol", "", [Microsoft.Win32.RegistryValueKind]::String)
        }
        finally {
            $root.Dispose()
        }

        $commandKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$protocolKey\shell\open\command")
        try {
            $commandKey.SetValue("", $command, [Microsoft.Win32.RegistryValueKind]::String)
        }
        finally {
            $commandKey.Dispose()
        }
    }

    if ($PSCmdlet.ShouldProcess($recordPath, "Write the activation install record")) {
        $manifest = Get-Content -Raw -LiteralPath $pluginManifest | ConvertFrom-Json
        [ordered]@{
            schema_version = 1
            owner = $script:CodexToastOwner
            protocol = $script:CodexToastProtocol
            plugin_version = [string]$manifest.version
            handler_path = $handlerPath
            command = $command
            installed_at = [DateTimeOffset]::Now.ToString("o")
        } | ConvertTo-Json | Set-Content -LiteralPath $recordPath -Encoding UTF8
    }

    Get-SetupStatus
}

function Remove-PluginState {
    $codexHomes = @()
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $codexHomes += [IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    $codexHomes += [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex"))

    foreach ($codexHome in @($codexHomes | Select-Object -Unique)) {
        $dataRoot = Join-Path $codexHome "plugins\data"
        if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
            continue
        }

        foreach ($directory in @(Get-ChildItem -LiteralPath $dataRoot -Directory -Filter "codex-windows-toast-*")) {
            if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Write-Warning "Skipping reparse point: $($directory.FullName)"
                continue
            }

            foreach ($file in @(Get-ChildItem -LiteralPath $directory.FullName -File)) {
                if ($file.Name -eq "last-hook-status.json" -or $file.Name -like "turn-*.json") {
                    if ($PSCmdlet.ShouldProcess($file.FullName, "Remove plugin state file")) {
                        Remove-Item -LiteralPath $file.FullName -Force
                    }
                }
            }

            if (@(Get-ChildItem -Force -LiteralPath $directory.FullName).Count -eq 0 -and
                $PSCmdlet.ShouldProcess($directory.FullName, "Remove empty plugin state directory")) {
                Remove-Item -LiteralPath $directory.FullName -Force
            }
        }
    }
}

function Uninstall-ActivationComponent {
    Test-OwnedRuntimeDirectory
    if ((Test-ProtocolKeyExists) -and -not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        throw "The $script:CodexToastProtocol protocol exists without this plugin's install record and will not be removed."
    }
    $registryExists = Test-OwnedRegistryLayout

    if ($registryExists -and $PSCmdlet.ShouldProcess("HKCU\$protocolKey", "Remove the owned URI protocol registration")) {
        foreach ($relativePath in @("shell\open\command", "shell\open", "shell", "")) {
            $path = if ($relativePath) { "$protocolKey\$relativePath" } else { $protocolKey }
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($path, $false)
        }
    }

    Remove-PluginState

    $ownedFiles = @(
        "activate-window.ps1",
        "activation-common.ps1",
        "secret.dat",
        "install.json",
        "last-activation-status.json"
    )
    foreach ($name in $ownedFiles) {
        $path = Join-Path $runtimePath $name
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and
            $PSCmdlet.ShouldProcess($path, "Remove activation component file")) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    if ((Test-Path -LiteralPath $runtimePath -PathType Container) -and
        $PSCmdlet.ShouldProcess($runtimePath, "Remove the empty activation directory")) {
        if (@(Get-ChildItem -Force -LiteralPath $runtimePath).Count -ne 0) {
            throw "$runtimePath still contains files and will not be removed."
        }
        Remove-Item -LiteralPath $runtimePath -Force
    }

    Get-SetupStatus
}

switch ($PSCmdlet.ParameterSetName) {
    "Install" { Install-ActivationComponent }
    "Uninstall" { Uninstall-ActivationComponent }
    default { Get-SetupStatus }
}
