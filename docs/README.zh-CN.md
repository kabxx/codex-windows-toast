# Codex Windows Toast

[English](../README.md) | [简体中文](README.zh-CN.md)

`codex-windows-toast` 是一个仅适用于 Windows 的 Codex CLI 插件。主 Agent
完成由用户提交的一轮并等待用户回复时，它会发送一条 Windows 原生 Toast 通知。
通知标题是本轮用户消息，正文是本轮最后一条助手回复。没有匹配用户提交的 Stop
（例如自动后台续跑）会被忽略。通知使用 Windows 的 `long`
显示时长，并可包含两个操作按钮。按钮会跟随当前 Windows 显示语言，未支持
的语言回退为简短英文：

- **返回**：恢复并激活提交本轮消息时位于前台的顶层窗口。
- **忽略**：关闭通知。

插件不会为执行过程中的审批请求发送通知。禁用插件会同时禁用通知 Hook。
插件使用 Windows 内置的 Toast API，无需安装额外的 PowerShell 模块。

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

## 启用窗口返回

通知 Hook 无需系统注册即可工作。**返回**按钮需要用户主动启用，因为
Windows 要求 Toast 按钮通过当前用户级 URI 协议处理器启动代码。请先审核
脚本、预览变更，再执行安装：

```powershell
$setup = ".\plugins\codex-windows-toast\scripts\setup.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Install -WhatIf
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Install
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Status
```

安装只会创建以下当前用户级内容：

- `HKCU\Software\Classes\codex-windows-toast`
- `%LOCALAPPDATA%\CodexWindowsToast`

它不会安装服务、计划任务、启动项或后台常驻进程。协议通过 Windows 内置的
`wscript.exe` 启动，后者会隐藏运行 PowerShell 激活处理器，不会弹出控制台
窗口。URI 只包含经过签名的窗口句柄、进程 ID 和进程启动时间，不包含用户
消息或助手回复。如果激活组件缺失或无效，普通通知仍会继续显示，但不包含
操作按钮。

返回按钮面向捕获到的顶层窗口，例如 Windows Terminal 或 VS Code；它不会
选择具体的终端标签页或编辑器终端。同一虚拟桌面内支持窗口激活。Windows
可能拒绝激活另一个虚拟桌面上的窗口，因此跨桌面激活仅为尽力尝试。

如需删除激活组件创建的全部内容，请运行：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Uninstall -WhatIf
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Uninstall
```

卸载程序会先验证安装记录和注册表命令，再执行删除。它只删除自身拥有的已知
注册表项、运行时文件和插件状态文件。如果注册表或运行时目录中存在未知内容，
卸载程序会保留这些内容并报告错误。

## 启用或禁用

在 Codex CLI 中运行 `/plugins`，打开已安装插件，然后按空格键切换启用状态。
更改状态后请启动新的会话。

## 测试 Windows Toast

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\plugins\codex-windows-toast\scripts\show-toast.ps1" -Test
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
