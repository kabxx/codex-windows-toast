# Codex Windows Toast

`codex-windows-toast` is a Windows-only Codex CLI plugin. It sends one native
Windows toast whenever the main agent finishes a turn and returns control to
the user. The toast title is the current user prompt, and its body is the final
assistant message for that turn.

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

## Enable Or Disable

Run `/plugins` in Codex CLI, open the installed plugin, and toggle it with
Space. Start a new session after changing plugin state.

## Test The Windows Toast

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\plugins\codex-windows-toast\scripts\show-toast.ps1" -Test
```

The script uses Windows' built-in toast APIs and does not require a PowerShell
module. Windows notification and Focus Assist settings still apply.

## Privacy

The hook processes the current prompt and final assistant message locally. It
does not make network requests. Per-turn state and a small diagnostic status
file are stored in the plugin data directory managed by Codex.

## License

[MIT](LICENSE)
