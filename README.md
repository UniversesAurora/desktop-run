# desktop-run

从 SSH 或终端启动 Windows 桌面上的程序。适合远程连上自己的 Windows 电脑后，打开 Obsidian、编辑器，或者在桌面会话里执行命令。

```powershell
desktop-run /e notepad.exe
desktop-run /b cmd.exe /k
```

电脑必须已经有人登录，且 Explorer 正在运行。它不会创建登录会话，也不会解锁桌面。

## 安装

需要 Windows 10/11 和 PowerShell 7.4 或更新版本。先在终端运行 `pwsh --version`，确认 PowerShell 已安装并在 PATH 中。

下载仓库 ZIP 并解压，或使用 Git：

```powershell
git clone https://github.com/UniversesAurora/desktop-run.git
cd desktop-run
pwsh -NoProfile -File .\install.ps1
```

安装脚本只复制两个文件到当前用户的 `%USERPROFILE%\.local\bin`，并把这个目录加入用户 PATH。不需要管理员权限。重新打开终端或 SSH 连接后运行：

```powershell
desktop-run /h
```

换电脑时重新执行这些步骤即可。脚本不依赖固定用户名、盘符、Python 或 PsExec。可以用 `-InstallDirectory` 指定其他安装目录。

更新时拉取代码，再运行 `install.ps1`。安装会覆盖目录里的两个同名文件。

## 两种启动方式

| 命令 | 谁启动目标 | 使用的环境 |
| --- | --- | --- |
| `desktop-run 程序` 或 `/b` | 桌面会话中的临时 PowerShell | 桥接进程的环境 |
| `desktop-run /e 程序` | 当前桌面 Explorer | Explorer 的环境 |

Bridge 是默认模式，可以启动命令行或图形程序。Explorer 模式适合 GUI、文档、网址和快捷方式；它通过桌面 Shell 的 COM 对象委托执行，不读取 PEB，也不伪造父进程。单实例应用可能直接复用现有进程。

```powershell
# GUI、网址和快捷方式
desktop-run /e notepad.exe
desktop-run /e "https://example.com"
desktop-run /e ".\My App.lnk"

# 命令行：内置命令、管道需要指定解释器
desktop-run /b cmd.exe /k dir
desktop-run /b pwsh.exe -NoExit -Command "Get-Date"
```

命令运行在桌面会话。终端里的输出不会传回 SSH，返回值也只表示启动请求的结果，不是目标程序最终的退出码。

## 路径、权限和错误

目标进入桌面桥接进程后才解析，使用该用户的 PATH 和 App Paths。相对路径以调用命令时的目录为基准；程序解析成完整路径后再启动。网址和 Shell URI 保持原样。

Bridge 的环境不保证与 Explorer 一致。Explorer 模式也先经过桥接进程解析，所以裸命令名仍可能受到两者 PATH 差异的影响。遇到这种情况，用完整路径或快捷方式。

临时任务使用桌面用户的 Interactive 登录和 Limited 运行级别。它不会主动请求管理员权限。要求提升的程序仍可能显示 UAC。SSH 用户需要有权创建这个任务，并且桌面用户需要能读取安装目录和临时载荷；跨用户启动不作为受支持用法。

找不到的目标会在终端报错，通常不会出现“找不到文件”的弹窗。文件关联损坏、缺少 DLL 等错误仍可能由 Windows 或程序显示对话框。

## 清理

每次调用会短暂创建一个没有触发器的 `DesktopRun_<随机 ID>` 任务。正常结束和普通错误路径会清理任务、桥接进程及载荷文件；Ctrl+C 能执行到 `finally` 时也会清理。

断电、强制结束调用进程等情况可能留下文件或任务。下次调用会尝试清理超过 10 分钟的旧文件、未运行的旧任务，以及超过两分钟且任务已不存在的桥接进程。没有常驻清理服务，也没有永久清理任务。Windows 自身的事件日志不会被删除。

如果有多个桌面会话，先指定 Session ID：

```powershell
$env:DESKTOP_RUN_SESSION_ID = '1'
desktop-run /e notepad.exe
```

设置 `$env:DESKTOP_RUN_DEBUG = '1'` 可以查看解析后的参数、目录和环境来源。

## 卸载

默认安装只需删除这两个文件：

```powershell
Remove-Item -LiteralPath "$env:USERPROFILE\.local\bin\desktop-run.cmd"
Remove-Item -LiteralPath "$env:USERPROFILE\.local\bin\desktop-run-core.ps1"
```

如果 `.local\bin` 还放着其他工具，保留该目录及 PATH 项。自定义安装目录时请使用对应路径。

## 验证

```powershell
pwsh -NoProfile -File .\tests\check.ps1
```

默认检查语法、帮助和参数引用。加 `-Desktop` 会在当前桌面会话中实际启动短命令，并验证错误路径和残留，要求 Explorer 已运行。
