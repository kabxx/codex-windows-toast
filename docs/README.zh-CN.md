# Codex Windows Toast

[English](../README.md) | [简体中文](README.zh-CN.md)

`codex-windows-toast` 是一个仅适用于 Windows 的 Codex CLI 插件。主 Agent
完成由用户提交的一轮并等待用户回复时，它会发送一条 Windows 原生 Toast 通知。
通知标题是本轮用户消息，正文是本轮最后一条助手回复。没有匹配用户提交的 Stop
（例如自动后台续跑）会被忽略。通知使用 Windows 的 `long`
显示时长，并可包含两个操作按钮。按钮会跟随当前 Windows 显示语言，未支持
的语言回退为简短英文：

- **返回**：恢复并激活提交本轮消息时位于前台的顶层窗口；如果存在可精确匹配
  的内置 Provider，再恢复本轮所属的终端目标。在 Windows 11 上，如果该窗口
  属于贴靠组，插件还会尝试恢复并前置组内所有当前可见窗口，最后让原窗口获得
  焦点。
- **忽略**：关闭通知。

插件不会为执行过程中的审批请求发送通知。禁用插件会同时禁用通知 Hook。
插件使用 Windows 内置的 Toast API，无需安装额外的 PowerShell 模块。

同一个 `Stop` 事件中的命令会并发运行。如果另一个 `Stop` Hook 阻止结束并让
Codex 继续工作，本插件可能会在续跑前提前通知。目前 Codex 没有提供在所有
`Stop` 决策汇总后触发的插件 Hook；如果要求通知时机完全准确，请不要与会让
当前回合继续的 `Stop` Hook 同时使用。

## 系统要求

- Windows 10 或 Windows 11
- 支持插件的 Codex CLI

## 安装

将 GitHub 仓库添加为 Codex 插件市场，然后安装插件：

```powershell
codex plugin marketplace add kabxx/codex-windows-toast
codex plugin add codex-windows-toast@codex-windows-toast
```

如需从本地检出的仓库进行开发，请在仓库根目录改用：

```powershell
codex plugin marketplace add .
codex plugin add codex-windows-toast@codex-windows-toast
```

启动新的 Codex CLI 会话，运行 `/hooks`，然后审核并信任插件的
`UserPromptSubmit` 和 `Stop` Hook。Codex 要求用户在本地或第三方 Hook 首次
运行前完成审核。

## 避免重复通知

Codex TUI 通知默认处于启用状态。在 WezTerm 等支持桌面通知的终端中，一轮
任务完成时可能因此额外出现一条由终端发送的 Toast，且不包含本插件的
**返回**和**忽略**按钮。

要让本插件负责任务完成通知，同时保留 Codex 的审批和 Plan 模式提醒，请在
`%USERPROFILE%\.codex\config.toml` 现有的 `[tui]` 配置块中设置
`notifications`；如果该配置块不存在，再创建它：

```toml
[tui]
notifications = ["approval-requested", "plan-mode-prompt"]
```

不要通过删除 `[tui]` 配置块来关闭这些通知：省略该设置时，`notifications`
会使用默认值 `true`。修改配置后，请启动新的 Codex CLI 会话。

## 启用窗口返回

通知 Hook 无需系统注册即可工作。**返回**按钮需要用户主动启用，因为
Windows 要求 Toast 按钮通过当前用户级 URI 协议处理器启动代码。请先审核
脚本、预览变更，再执行安装：

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

安装只会创建以下当前用户级内容：

- `HKCU\Software\Classes\codex-windows-toast`
- `%LOCALAPPDATA%\CodexWindowsToast`

它不会安装服务、计划任务、启动项或后台常驻进程。协议通过 Windows 内置的
`wscript.exe` 启动，后者会隐藏运行 PowerShell 激活处理器，不会弹出控制台
窗口。URI 只包含不透明的激活记录 ID 和签名。短期本地记录包含经过校验的窗口
身份，以及受支持时的终端定位信息；它不包含用户消息或助手回复。记录会在七天
后过期，并在成功认证后删除。如果激活组件缺失或无效，普通通知仍会继续显示，
但不包含操作按钮。

`-Status` 会同时显示 `Installed` 和 `Current`。插件升级后，如果 `Current`
为 `False`，请重新运行 `-Install`。在运行时组件与已安装插件一致之前，普通
通知仍会显示，但不包含操作按钮。涉及激活行为的更新都需要重新运行
`setup.ps1 -Install`；`-Status` 会将这种情况报告为 `Current: False`。

### 终端目标恢复

恢复并校验顶层窗口后，激活处理器无需配套插件即可处理以下内置目标：

- **WezTerm**：通过 WezTerm 自身的 socket 和 CLI 恢复捕获到的 pane 及其 tab。
  如果 pane 已关闭、mux 已重启或窗口不匹配，则只恢复外层窗口。
- **Windows Terminal**：选择仍可通过 UI Automation 精确识别的原 tab，并在
  pane 仍可精确识别时聚焦它。插件不会根据标题或 tab 索引猜测，也不会调用
  `wt.exe` 新建或搜索窗口。
- **WSL 中的 tmux**：仅在嵌套于已捕获的 WezTerm 或 Windows Terminal 目标时，
  严格校验 server 和进程并恢复既有 client、session、window 和 pane。它要求
  `/usr/bin/tmux`，不会创建或扫描 tmux server。Hook 进程必须能收到 `TMUX`、
  `TMUX_PANE` 和 `WSL_DISTRO_NAME`。从 WSL 启动 Windows Codex 时，请在启动
  Codex 前配置 `WSLENV`，例如：

  ```sh
  export WSLENV="${WSLENV:+$WSLENV:}TMUX/w:TMUX_PANE/w:WSL_DISTRO_NAME/w"
  ```

VS Code、Zed 和没有精确内置 Provider 的终端只恢复窗口。终端目标不受支持、
已经失效、存在歧义或激活失败时，也会停在已经恢复的窗口，不会切换、新建或
关闭 terminal panel。

不属于贴靠组的窗口保持原有单窗口行为。贴靠组成员会根据公开 Win32 的窗口
贴靠状态、位置和可见性尽力推断，因此在非典型布局或窗口被部分遮挡时，可能
只恢复部分窗口。同一虚拟桌面内支持窗口激活。Windows 可能拒绝激活另一个
虚拟桌面上的窗口，因此跨桌面激活同样仅为尽力尝试。

## 完整卸载

请先卸载激活组件，再移除 Codex 插件，确保 setup 脚本仍然可用。以下顺序会
依次清理 URI 协议、LocalAppData 运行时、插件状态，最后移除 Codex 插件：

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

卸载程序会先验证安装记录和注册表命令，再执行删除。它只删除自身拥有的已知
注册表项、运行时文件和插件状态文件。如果注册表或运行时目录中存在未知内容，
卸载程序会保留这些内容并报告错误。

如果没有其他已安装插件使用这个 marketplace，还可以继续移除它：

```powershell
codex plugin marketplace remove codex-windows-toast
```

## 启用或禁用

在 Codex CLI 中运行 `/plugins`，打开已安装插件，然后按空格键切换启用状态。
更改状态后请启动新的会话。

## 测试 Windows Toast

```powershell
$pluginId = "codex-windows-toast@codex-windows-toast"
$plugin = (codex plugin list --json | ConvertFrom-Json).installed |
    Where-Object pluginId -EQ $pluginId | Select-Object -First 1
if ($null -eq $plugin) { throw "$pluginId is not installed." }
$testScript = Join-Path $plugin.source.path "scripts\show-toast.ps1"
if (-not (Test-Path -LiteralPath $testScript -PathType Leaf)) { throw "show-toast.ps1 was not found at $testScript" }
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $testScript -Test
```

脚本使用 Windows 内置的 Toast API，不需要额外的 PowerShell 模块。启用返回
按钮后，测试通知会包含两个操作按钮。Windows 通知权限和专注模式仍会影响
通知显示。

## 隐私

Hook 只在本机处理当前用户消息和最后一条助手回复，不会发起网络请求。每轮
状态和少量诊断状态文件保存在本机。窗口激活密钥使用 DPAPI 进行当前用户级
保护。

## 许可证

[MIT](../LICENSE)
