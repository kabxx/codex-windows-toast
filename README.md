# Codex Windows Toast

[English](README.md) | [简体中文](docs/README.zh-CN.md)

`codex-windows-toast` is a Windows-only Codex CLI plugin. It sends one native
Windows toast whenever the main agent finishes a user-submitted turn and
returns control to the user. The toast title is the current user prompt, and
its body is the final assistant message for that turn. Stops without a matching
user submission, such as automatic background continuations, are ignored.
Notifications use Windows' `long` duration
and can include two actions. Their labels follow the current Windows display
language, with concise English labels as the fallback:

- **Return** restores and activates the top-level window that was in front when
  the prompt was submitted, then restores the originating terminal target when
  an exact built-in provider is available. On Windows 11, if that window belongs
  to a Snap Group, the plugin also attempts to restore and bring forward all
  currently visible members of that group before focusing the original window.
- **Dismiss** dismisses the notification.

It does not notify for mid-turn approval requests. Disabling the plugin disables
the notification hooks. The plugin uses Windows' built-in toast APIs and does
not require an additional PowerShell module.

Commands registered for the same `Stop` event run concurrently. If another
`Stop` hook blocks completion and makes Codex continue, this plugin can notify
before that continuation. Codex does not currently expose a plugin hook after
all `Stop` decisions are aggregated, so avoid combining it with a `Stop` hook
that continues the turn when exact notification timing is required.

## Requirements

- Windows 10 or Windows 11
- Codex CLI with plugin support

## Install

Add the GitHub repository as a Codex plugin marketplace, then install the
plugin:

```powershell
codex plugin marketplace add kabxx/codex-windows-toast
codex plugin add codex-windows-toast@codex-windows-toast
```

For development from a local checkout, run this from the repository root
instead:

```powershell
codex plugin marketplace add .
codex plugin add codex-windows-toast@codex-windows-toast
```

Start a new Codex CLI session, run `/hooks`, then review and trust the plugin's
`UserPromptSubmit` and `Stop` hooks. Codex requires this review before local or
third-party hooks can run.

## Avoid Duplicate Notifications

Codex TUI notifications are enabled by default. In terminals that support
desktop notifications, such as WezTerm, a completed turn can therefore produce
a second terminal-sourced toast without the plugin's **Return** and **Dismiss**
actions.

To let this plugin handle turn-complete notifications while retaining Codex's
approval and Plan mode prompts, set `notifications` in the existing `[tui]`
table in `%USERPROFILE%\.codex\config.toml`, or create the table if it is not
present:

```toml
[tui]
notifications = ["approval-requested", "plan-mode-prompt"]
```

Do not remove the `[tui]` section to disable these notifications: when the
setting is omitted, `notifications` defaults to `true`. Start a new Codex CLI
session after changing the configuration.

## Enable Window Return

The notification hook works without system registration. The **Return** button is
opt-in because Windows requires a per-user URI protocol handler for a toast
button to launch code. Review the script, preview its changes, then install it:

```powershell
$pluginId = "codex-windows-toast@codex-windows-toast"
$plugin = (codex plugin list --json | ConvertFrom-Json).installed |
    Where-Object pluginId -EQ $pluginId | Select-Object -First 1
if ($null -eq $plugin) { throw "$pluginId is not installed." }
$setup = Join-Path $plugin.source.path "scripts\setup.ps1"
if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw "setup.ps1 was not found at $setup" }
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Install -WhatIf
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Install
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Status
```

Installation creates only these user-scoped artifacts:

- `HKCU\Software\Classes\codex-windows-toast`
- `%LOCALAPPDATA%\CodexWindowsToast`

It does not install a service, scheduled task, startup item, or background
process. The protocol starts through Windows' built-in `wscript.exe`, which
launches the PowerShell activation handler without opening a console window.
The URI contains only an opaque activation-record ID and a signature. The
short-lived local record contains validated window identities and, when
supported, a terminal locator; it never contains prompt or response text. A
record expires after seven days and is deleted after successful authentication.
If the activation component is absent or invalid, notifications continue
without action buttons.

`-Status` reports both `Installed` and `Current`. After a plugin update, rerun
`-Install` when `Current` is `False`; the notification hook continues without
action buttons until the runtime component matches the installed plugin.
Updates that change activation behavior require a fresh `setup.ps1 -Install`;
`-Status` reports this as `Current: False`.

### Terminal target restoration

After restoring the validated top-level window, the activation handler supports
these built-in targets without companion plugins:

- **WezTerm:** restores the exact captured pane and its tab through WezTerm's
  own socket and CLI. A closed pane, restarted mux, or mismatched window falls
  back to the outer window.
- **Windows Terminal:** selects the exact captured live UI Automation tab and,
  when it remains identifiable, its pane. It never guesses by title or tab
  index and never invokes `wt.exe` to create or find a window.
- **tmux in WSL:** when nested in a captured WezTerm or Windows Terminal target,
  restores the exact existing client, session, window, and pane after strict
  server and process checks. It requires `/usr/bin/tmux` and never creates or
  scans for a tmux server. The hook process must receive `TMUX`, `TMUX_PANE`,
  and `WSL_DISTRO_NAME`; when launching Windows Codex from WSL, configure
  `WSLENV` before starting Codex, for example:

  ```sh
  export WSLENV="${WSLENV:+$WSLENV:}TMUX/w:TMUX_PANE/w:WSL_DISTRO_NAME/w"
  ```

VS Code, Zed, and terminals without an exact built-in provider use window-only
activation. Unsupported, stale, ambiguous, or failed terminal targets also stop
at the restored window without changing, opening, or closing a terminal panel.

A window outside a Snap Group keeps the existing single-window behavior. Snap
Group membership is inferred on a best-effort basis from public Win32
arranged-window state, window geometry, and visibility. Nonstandard or partially
obscured layouts may therefore fall back to fewer windows. Activation on the
current virtual desktop is supported. Windows may reject or decline to switch
to a window on another virtual desktop, so cross-desktop activation is also best
effort.

## Uninstall

Remove the activation component before removing the plugin so the setup script
is still available. This order removes the URI protocol, LocalAppData runtime,
plugin state, and finally the Codex plugin:

```powershell
$pluginId = "codex-windows-toast@codex-windows-toast"
$plugin = (codex plugin list --json | ConvertFrom-Json).installed |
    Where-Object pluginId -EQ $pluginId | Select-Object -First 1
if ($null -eq $plugin) { throw "$pluginId is not installed." }
$setup = Join-Path $plugin.source.path "scripts\setup.ps1"
if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw "setup.ps1 was not found at $setup" }
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Uninstall -WhatIf
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Uninstall
codex plugin remove $pluginId
```

Uninstall verifies the install record and registry command before removing
anything. It deletes only the known registry keys, runtime files, and plugin
state files it owns. Unknown content in the registry or runtime directory is
left untouched and reported as an error.

If no other installed plugin uses this marketplace, it can then be removed:

```powershell
codex plugin marketplace remove codex-windows-toast
```

## Enable Or Disable

Run `/plugins` in Codex CLI, open the installed plugin, and toggle it with
Space. Start a new session after changing plugin state.

## Test The Windows Toast

```powershell
$pluginId = "codex-windows-toast@codex-windows-toast"
$plugin = (codex plugin list --json | ConvertFrom-Json).installed |
    Where-Object pluginId -EQ $pluginId | Select-Object -First 1
if ($null -eq $plugin) { throw "$pluginId is not installed." }
$testScript = Join-Path $plugin.source.path "scripts\show-toast.ps1"
if (-not (Test-Path -LiteralPath $testScript -PathType Leaf)) { throw "show-toast.ps1 was not found at $testScript" }
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $testScript -Test
```

The script uses Windows' built-in toast APIs and does not require a PowerShell
module. After enabling the jump button, the test toast includes both actions.
Windows notification and Focus Assist settings still apply.

## Privacy

The hook processes the current prompt and final assistant message locally. It
does not make network requests. Per-turn state and small diagnostic status
files are stored locally. The window activation secret is protected for the
current Windows user with DPAPI.

## License

[MIT](LICENSE)
