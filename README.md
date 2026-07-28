# Codex Windows Toast

`codex-windows-toast` is a Windows-only Codex CLI plugin. It sends one native
Windows toast whenever the main agent finishes a turn and returns control to
the user. The toast title is the current user prompt, and its body is the final
assistant message for that turn. Notifications use Windows' `long` duration
and can include two actions:

- **跳转** restores and activates the top-level window that was in front when
  the prompt was submitted.
- **忽略** dismisses the notification.

It does not notify for mid-turn approval requests. Disabling the plugin disables
the notification hooks. The plugin uses Windows' built-in toast APIs and does
not require an additional PowerShell module.

## Requirements

- Windows 10 or Windows 11
- Codex CLI with plugin support

## Install From A Local Checkout

Run these commands from the repository root:

```powershell
codex plugin marketplace add .
codex plugin add codex-windows-toast@codex-windows-toast
```

After this repository is published on GitHub, it can also be added directly:

```powershell
codex plugin marketplace add <owner>/codex-windows-toast
codex plugin add codex-windows-toast@codex-windows-toast
```

Start a new Codex CLI session, run `/hooks`, then review and trust the plugin's
`UserPromptSubmit` and `Stop` hooks. Codex requires this review before local or
third-party hooks can run.

## Enable The Jump Button

The notification hook works without system registration. The **跳转** button is
opt-in because Windows requires a per-user URI protocol handler for a toast
button to launch code. Review the script, preview its changes, then install it:

```powershell
$setup = ".\plugins\codex-windows-toast\scripts\setup.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Install -WhatIf
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Install
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Status
```

Installation creates only these user-scoped artifacts:

- `HKCU\Software\Classes\codex-windows-toast`
- `%LOCALAPPDATA%\CodexWindowsToast`

It does not install a service, scheduled task, startup item, or background
process. The URI contains only a signed window handle, process ID, and process
start time; it never contains prompt or response text. If the activation
component is absent or invalid, notifications continue without action buttons.

The button targets the captured top-level window, such as Windows Terminal or
VS Code; it does not select a terminal tab or editor terminal. Activation on the
current virtual desktop is supported. Windows may reject or decline to switch
to a window on another virtual desktop, so cross-desktop activation is best
effort.

To remove every artifact created by the activation setup, run:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Uninstall -WhatIf
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Uninstall
```

Uninstall verifies the install record and registry command before removing
anything. It deletes only the known registry keys, runtime files, and plugin
state files it owns. Unknown content in the registry or runtime directory is
left untouched and reported as an error.

## Enable Or Disable

Run `/plugins` in Codex CLI, open the installed plugin, and toggle it with
Space. Start a new session after changing plugin state.

## Test The Windows Toast

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\plugins\codex-windows-toast\scripts\show-toast.ps1" -Test
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
