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
$launcherPath = Get-CodexToastLauncherPath
$commonPath = Join-Path $runtimePath "activation-common.ps1"
$secretPath = Join-Path $runtimePath "secret.dat"
$recordPath = Join-Path $runtimePath "install.json"
$protocolKey = "Software\Classes\$script:CodexToastProtocol"
$sourceHandler = Join-Path $PSScriptRoot "activate-window.ps1"
$sourceLauncher = Join-Path $PSScriptRoot "launch-hidden.vbs"
$sourceCommon = Join-Path $PSScriptRoot "activation-common.ps1"
$pluginManifest = Join-Path (Split-Path $PSScriptRoot -Parent) ".codex-plugin\plugin.json"
$ownedRuntimeNames = @(
    "activate-window.ps1",
    "launch-hidden.vbs",
    "activation-common.ps1",
    "secret.dat",
    "install.json",
    "last-activation-status.json"
)

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
        Current = $context.Current
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

    $unknownEntries = @($entries | Where-Object { $_.Name -notin $ownedRuntimeNames })
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
    param(
        [switch]$AllowIncomplete,
        [string[]]$AdditionalOwnedCommands = @()
    )

    $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($protocolKey)
    if ($null -eq $root) {
        return $false
    }

    try {
        $ownedCommands = @(
            Get-CodexToastRegistryCommand -LauncherPath $launcherPath
            Get-CodexToastLegacyRegistryCommand -HandlerPath $handlerPath
        ) + @($AdditionalOwnedCommands)
        $rootSubKeys = @($root.GetSubKeyNames())
        $rootValueNames = @($root.GetValueNames())
        if (@($rootSubKeys | Where-Object { $_ -cne "shell" }).Count -ne 0 -or
            @($rootValueNames | Where-Object { $_ -cne "" -and $_ -cne "URL Protocol" }).Count -ne 0 -or
            (($rootValueNames -ccontains "") -and [string]$root.GetValue("") -cne "URL:Codex Windows Toast") -or
            (($rootValueNames -ccontains "URL Protocol") -and [string]$root.GetValue("URL Protocol") -cne "")) {
            throw "The protocol key contains unknown values or subkeys."
        }
        if (-not $AllowIncomplete -and
            (-not ($rootSubKeys -ccontains "shell") -or
             -not ($rootValueNames -ccontains "") -or
             -not ($rootValueNames -ccontains "URL Protocol"))) {
            throw "The protocol registration is incomplete."
        }

        foreach ($relativePath in @("shell", "shell\open")) {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$protocolKey\$relativePath")
            if ($null -eq $key) {
                if ($AllowIncomplete) {
                    return $true
                }
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
            if ($null -eq $commandKey) {
                if ($AllowIncomplete) {
                    return $true
                }
                throw "The protocol registration is incomplete."
            }

            $commandValueNames = @($commandKey.GetValueNames())
            if ($commandKey.GetSubKeyNames().Count -ne 0 -or
                @($commandValueNames | Where-Object { $_ -cne "" }).Count -ne 0) {
                throw "The protocol command key contains unknown content."
            }
            if ($commandValueNames -ccontains "") {
                $command = [string]$commandKey.GetValue("")
                if ($command -cnotin $ownedCommands) {
                    throw "The existing $script:CodexToastProtocol protocol is not owned by this installation."
                }
            }
            elseif (-not $AllowIncomplete) {
                throw "The protocol registration is incomplete."
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

function Set-CodexToastProtocolRegistration {
    param([Parameter(Mandatory)][string]$Command)

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
        $commandKey.SetValue("", $Command, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        $commandKey.Dispose()
    }
}

function Remove-CodexToastProtocolRegistration {
    param(
        [switch]$AllowIncomplete,
        [string[]]$AdditionalOwnedCommands = @()
    )

    if (-not (Test-ProtocolKeyExists)) {
        return
    }

    [void](Test-OwnedRegistryLayout -AllowIncomplete:$AllowIncomplete -AdditionalOwnedCommands $AdditionalOwnedCommands)
    foreach ($relativePath in @("shell\open\command", "shell\open", "shell", "")) {
        $path = if ($relativePath) { "$protocolKey\$relativePath" } else { $protocolKey }
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
        if ($null -eq $key) {
            continue
        }
        $key.Dispose()
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($path, $false)
    }
}

function New-CodexToastSecretFile {
    param([Parameter(Mandatory)][string]$Path)

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
        [Convert]::ToBase64String($protected) | Set-Content -LiteralPath $Path -Encoding ASCII
    }
    finally {
        $generator.Dispose()
        [Array]::Clear($secret, 0, $secret.Length)
    }
}

function Remove-CodexToastTransactionDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $directory = Get-Item -Force -LiteralPath $Path
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Path is a reparse point and will not be removed."
    }

    $entries = @(Get-ChildItem -Force -LiteralPath $Path)
    $unknownEntries = @($entries | Where-Object { $_.Name -notin $ownedRuntimeNames -or $_.PSIsContainer })
    if ($unknownEntries.Count -ne 0) {
        throw "$Path contains unknown transaction files: $($unknownEntries.Name -join ', ')"
    }

    foreach ($entry in $entries) {
        Remove-Item -LiteralPath $entry.FullName -Force
    }
    Remove-Item -LiteralPath $Path -Force
}

function Install-ActivationComponent {
    foreach ($sourcePath in @($sourceHandler, $sourceLauncher, $sourceCommon, $pluginManifest)) {
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required source file is missing: $sourcePath"
        }
    }

    $sourceComponent = Get-CodexToastActivationComponent -BasePath $PSScriptRoot
    $registryExisted = Test-ProtocolKeyExists
    Test-OwnedRuntimeDirectory
    if ($registryExisted) {
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            throw "The $script:CodexToastProtocol protocol already exists without this plugin's install record."
        }
        [void](Test-OwnedRegistryLayout)
    }

    $command = Get-CodexToastRegistryCommand -LauncherPath $launcherPath
    $filesApproved = $PSCmdlet.ShouldProcess($runtimePath, "Install window activation files transactionally")
    $registryApproved = $PSCmdlet.ShouldProcess("HKCU\$protocolKey", "Register the $script:CodexToastProtocol URI protocol")
    if (-not ($filesApproved -and $registryApproved)) {
        return Get-SetupStatus
    }

    $transactionId = [Guid]::NewGuid().ToString("N")
    $runtimeParent = Split-Path $runtimePath -Parent
    $stagePath = Join-Path $runtimeParent "CodexWindowsToast.stage-$transactionId"
    $backupPath = Join-Path $runtimeParent "CodexWindowsToast.backup-$transactionId"
    $previousCommand = if ($registryExisted) { Get-CodexToastRegisteredCommand } else { $null }
    $oldRuntimeMoved = $false
    $newRuntimeMoved = $false
    $registryAttempted = $false
    $preserveTransactionDirectories = $false

    try {
        New-Item -ItemType Directory -Path $stagePath | Out-Null
        Copy-Item -LiteralPath $sourceHandler -Destination (Join-Path $stagePath "activate-window.ps1")
        Copy-Item -LiteralPath $sourceLauncher -Destination (Join-Path $stagePath "launch-hidden.vbs")
        Copy-Item -LiteralPath $sourceCommon -Destination (Join-Path $stagePath "activation-common.ps1")

        $stagedSecretPath = Join-Path $stagePath "secret.dat"
        if (Test-Path -LiteralPath $secretPath -PathType Leaf) {
            Copy-Item -LiteralPath $secretPath -Destination $stagedSecretPath
        }
        else {
            New-CodexToastSecretFile -Path $stagedSecretPath
        }

        $lastStatusPath = Join-Path $runtimePath "last-activation-status.json"
        if (Test-Path -LiteralPath $lastStatusPath -PathType Leaf) {
            Copy-Item -LiteralPath $lastStatusPath -Destination (Join-Path $stagePath "last-activation-status.json")
        }

        $stagedComponent = Get-CodexToastActivationComponent -BasePath $stagePath
        if ($stagedComponent.Fingerprint -cne $sourceComponent.Fingerprint) {
            throw "The staged activation component does not match the plugin source."
        }

        $manifest = Get-Content -Raw -LiteralPath $pluginManifest | ConvertFrom-Json
        $installRecord = [ordered]@{
            schema_version = $script:CodexToastActivationRecordSchemaVersion
            owner = $script:CodexToastOwner
            protocol = $script:CodexToastProtocol
            plugin_version = [string]$manifest.version
            activation_component_version = $stagedComponent.Version
            activation_component_fingerprint = $stagedComponent.Fingerprint
            file_hashes = $stagedComponent.FileHashes
            handler_path = $handlerPath
            launcher_path = $launcherPath
            common_path = $commonPath
            command = $command
            installed_at = [DateTimeOffset]::Now.ToString("o")
        }
        $stagedRecordPath = Join-Path $stagePath "install.json"
        $installRecord | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stagedRecordPath -Encoding UTF8
        $verifiedRecord = Get-Content -Raw -LiteralPath $stagedRecordPath | ConvertFrom-Json
        Test-CodexToastActivationComponentRecord -Record $verifiedRecord -Component $stagedComponent

        if (Test-Path -LiteralPath $runtimePath -PathType Container) {
            Move-Item -LiteralPath $runtimePath -Destination $backupPath
            $oldRuntimeMoved = $true
        }
        Move-Item -LiteralPath $stagePath -Destination $runtimePath
        $newRuntimeMoved = $true

        $registryAttempted = $true
        Set-CodexToastProtocolRegistration -Command $command

        $context = Get-CodexToastActivationContext
        if (-not $context.Installed -or -not $context.Current) {
            throw "Activation component validation failed: $($context.Error)"
        }
    }
    catch {
        $installError = $_.Exception
        $rollbackErrors = New-Object Collections.Generic.List[string]

        if ($registryAttempted) {
            try {
                if ($registryExisted) {
                    Set-CodexToastProtocolRegistration -Command $previousCommand
                }
                else {
                    Remove-CodexToastProtocolRegistration -AllowIncomplete -AdditionalOwnedCommands @($command)
                }
            }
            catch {
                $rollbackErrors.Add("registry: $($_.Exception.Message)")
            }
        }

        try {
            if ($newRuntimeMoved -and (Test-Path -LiteralPath $runtimePath -PathType Container)) {
                Move-Item -LiteralPath $runtimePath -Destination $stagePath
                $newRuntimeMoved = $false
            }
            if ($oldRuntimeMoved -and (Test-Path -LiteralPath $backupPath -PathType Container)) {
                Move-Item -LiteralPath $backupPath -Destination $runtimePath
                $oldRuntimeMoved = $false
            }
        }
        catch {
            $rollbackErrors.Add("runtime: $($_.Exception.Message)")
        }

        if ($rollbackErrors.Count -ne 0) {
            $preserveTransactionDirectories = $true
            throw "Activation installation failed: $($installError.Message) Rollback also failed: $($rollbackErrors -join '; '). Transaction paths were preserved: $stagePath, $backupPath"
        }
        throw $installError
    }
    finally {
        if (-not $preserveTransactionDirectories) {
            foreach ($path in @($stagePath, $backupPath)) {
                try {
                    Remove-CodexToastTransactionDirectory -Path $path
                }
                catch {
                    Write-Warning $_.Exception.Message
                }
            }
        }
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
        Remove-CodexToastProtocolRegistration
    }

    Remove-PluginState

    foreach ($name in $ownedRuntimeNames) {
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
