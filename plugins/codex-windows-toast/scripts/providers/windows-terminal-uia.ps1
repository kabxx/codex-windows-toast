[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet("capture", "activate")][string]$Mode,
    [Parameter(Mandatory)][long]$Hwnd,
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][long]$StartedUtcTicks,
    [string]$TabRuntimeId = "",
    [string]$PaneRuntimeId = ""
)

$ErrorActionPreference = "Stop"

function Write-WorkerResult {
    param(
        [Parameter(Mandatory)][string]$Status,
        [AllowEmptyString()][string]$Detail = "",
        [AllowEmptyString()][string]$Tab = "",
        [AllowEmptyString()][string]$Pane = ""
    )

    $tabValues = ConvertFrom-WorkerRuntimeId -Value $Tab -AllowEmpty
    $paneValues = ConvertFrom-WorkerRuntimeId -Value $Pane -AllowEmpty
    [ordered]@{
        status = $Status
        detail = $Detail
        tab_runtime_id = $tabValues.ToArray()
        pane_runtime_id = $paneValues.ToArray()
    } | ConvertTo-Json -Compress | Write-Output
}

function ConvertFrom-WorkerRuntimeId {
    param(
        [AllowEmptyString()][string]$Value,
        [switch]$AllowEmpty
    )

    $result = New-Object Collections.Generic.List[int]
    if ([string]::IsNullOrEmpty($Value)) {
        if ($AllowEmpty) {
            return ,$result
        }
        throw "Runtime ID is required."
    }

    [Array]$items = $Value.Split([char]',')
    if ($items.Count -gt 64) {
        throw "Runtime ID is invalid."
    }
    for ($index = 0; $index -lt $items.Length; $index++) {
        $item = [string]$items.GetValue($index)
        [int]$parsed = 0
        if ($item -notmatch "^(0|[1-9][0-9]{0,9}|-[1-9][0-9]{0,9})$" -or
            -not [int]::TryParse($item, [ref]$parsed)) {
            throw "Runtime ID is invalid."
        }
        $result.Add($parsed)
    }
    return ,$result
}

function Test-WorkerRuntimeIdEqual {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    return $Left -ceq $Right
}

function Get-WorkerRuntimeId {
    param([Parameter(Mandatory)]$Element)

    [Array]$runtimeId = $Element.GetRuntimeId()
    $pending = New-Object Collections.Generic.Stack[object]
    for ($index = $runtimeId.Length - 1; $index -ge 0; $index--) {
        $pending.Push($runtimeId.GetValue($index))
    }

    $values = New-Object Collections.Generic.List[string]
    while ($pending.Count -gt 0) {
        $value = $pending.Pop()
        if ($value -is [Array]) {
            [Array]$nested = $value
            for ($index = $nested.Length - 1; $index -ge 0; $index--) {
                $pending.Push($nested.GetValue($index))
            }
            continue
        }

        [int]$parsed = [Convert]::ToInt32($value)
        $values.Add($parsed.ToString([Globalization.CultureInfo]::InvariantCulture))
        if ($values.Count -gt 64) {
            throw "Runtime ID is invalid."
        }
    }
    if ($values.Count -eq 0) {
        throw "Runtime ID is invalid."
    }
    return $values -join ","
}

function Get-WorkerTabElements {
    param([Parameter(Mandatory)]$Root)

    $condition = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem
    )
    return @($Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition))
}

function Get-WorkerSelectionPattern {
    param([Parameter(Mandatory)]$Element)

    $pattern = $null
    if ($Element.TryGetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern,
        [ref]$pattern
    )) {
        return $pattern
    }
    return $null
}

function Test-WorkerDescendant {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)]$Element
    )

    $rootRuntimeId = Get-WorkerRuntimeId -Element $Root
    $current = $Element
    for ($depth = 0; $null -ne $current -and $depth -lt 64; $depth++) {
        $currentRuntimeId = Get-WorkerRuntimeId -Element $current
        if (Test-WorkerRuntimeIdEqual -Left $rootRuntimeId -Right $currentRuntimeId) {
            return $true
        }
        $current = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($current)
    }
    return $false
}

function Test-WorkerTerminalPane {
    param(
        [Parameter(Mandatory)]$Element,
        [Parameter(Mandatory)][int]$ExpectedProcessId
    )

    return $Element.Current.ProcessId -eq $ExpectedProcessId -and
        $Element.Current.IsKeyboardFocusable -and
        $Element.Current.ClassName -ceq "TermControl" -and
        $Element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text
}

function Find-WorkerElementByRuntimeId {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)]$RuntimeId,
        [switch]$TabOnly,
        [switch]$TerminalPane,
        [AllowNull()]$RequiredAncestor
    )

    $elements = if ($TabOnly) {
        @(Get-WorkerTabElements -Root $Root)
    }
    else {
        @($Root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        ))
    }
    $matches = @($elements | Where-Object {
        $elementRuntimeId = Get-WorkerRuntimeId -Element $_
        (Test-WorkerRuntimeIdEqual -Left $elementRuntimeId -Right $RuntimeId) -and
            (-not $TerminalPane -or (
                (Test-WorkerTerminalPane -Element $_ -ExpectedProcessId $ProcessId) -and
                $null -ne $RequiredAncestor -and
                (Test-WorkerDescendant -Root $RequiredAncestor -Element $_)
            ))
    })
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}

$stage = "target"
try {
    if ($Hwnd -le 0 -or $ProcessId -le 0 -or $StartedUtcTicks -le 0) {
        throw "Invalid target."
    }
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    if ($process.StartTime.ToUniversalTime().Ticks -ne $StartedUtcTicks -or
        [IO.Path]::GetFileName([string]$process.Path) -cne "WindowsTerminal.exe") {
        Write-WorkerResult -Status "stale"
        exit 0
    }

    $stage = "automation"
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
    if ($null -eq $root -or $root.Current.ProcessId -ne $ProcessId) {
        Write-WorkerResult -Status "stale"
        exit 0
    }

    $stage = $Mode
    if ($Mode -ceq "capture") {
        $selectedTabs = @()
        foreach ($tab in @(Get-WorkerTabElements -Root $root)) {
            $pattern = Get-WorkerSelectionPattern -Element $tab
            if ($null -ne $pattern -and $pattern.Current.IsSelected) {
                $selectedTabs += $tab
            }
        }
        if ($selectedTabs.Count -ne 1) {
            Write-WorkerResult -Status "failed" -Detail "selected-tab-not-found"
            exit 0
        }

        $paneRuntimeId = ""
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and
            (Test-WorkerTerminalPane -Element $focused -ExpectedProcessId $ProcessId) -and
            (Test-WorkerDescendant -Root $root -Element $focused)) {
            $paneRuntimeId = Get-WorkerRuntimeId -Element $focused
        }
        $tabRuntimeId = Get-WorkerRuntimeId -Element $selectedTabs[0]
        if (-not [string]::IsNullOrEmpty($paneRuntimeId)) {
            Write-WorkerResult `
                -Status "captured" `
                -Tab $tabRuntimeId `
                -Pane $paneRuntimeId
        }
        else {
            Write-WorkerResult `
                -Status "captured" `
                -Tab $tabRuntimeId
        }
        exit 0
    }

    [void](ConvertFrom-WorkerRuntimeId -Value $TabRuntimeId)
    [void](ConvertFrom-WorkerRuntimeId -Value $PaneRuntimeId -AllowEmpty)
    $tab = Find-WorkerElementByRuntimeId -Root $root -RuntimeId $TabRuntimeId -TabOnly
    if ($null -eq $tab) {
        Write-WorkerResult -Status "stale"
        exit 0
    }
    $pattern = Get-WorkerSelectionPattern -Element $tab
    if ($null -eq $pattern) {
        Write-WorkerResult -Status "failed" -Detail "tab-not-selectable"
        exit 0
    }
    if (-not $pattern.Current.IsSelected) {
        $pattern.Select()
    }
    if (-not $pattern.Current.IsSelected) {
        Write-WorkerResult -Status "failed" -Detail "tab-not-selected"
        exit 0
    }

    if (-not [string]::IsNullOrEmpty($PaneRuntimeId)) {
        $pane = Find-WorkerElementByRuntimeId `
            -Root $root `
            -RuntimeId $PaneRuntimeId `
            -TerminalPane `
            -RequiredAncestor $tab
        if ($null -ne $pane) {
            try {
                $pane.SetFocus()
                $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
                $focusedRuntimeId = if ($null -ne $focused) { Get-WorkerRuntimeId -Element $focused } else { "" }
                if ($null -ne $focused -and
                    (Test-WorkerRuntimeIdEqual -Left $focusedRuntimeId -Right $PaneRuntimeId)) {
                    Write-WorkerResult -Status "activated" -Detail "tab-pane"
                    exit 0
                }
            }
            catch {
            }
        }
    }

    Write-WorkerResult -Status "activated" -Detail "tab-only"
}
catch {
    Write-WorkerResult `
        -Status "failed" `
        -Detail "${stage}-error"
}
