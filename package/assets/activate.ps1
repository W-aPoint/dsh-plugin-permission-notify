<#
.SYNOPSIS
    把 DeepSeek Harness 主窗口切到前台（供 Toast 点击协议 dshnotify:activate 调用）。

.DESCRIPTION
    背景进程直接 SetForegroundWindow 会被 Windows 的前台锁挡住。实测可用的组合是：
    先发一次 ALT 键（解除前台锁），再 SetForegroundWindow；必要时再 AttachThreadInput
    重试。每一步都写日志，便于排查。
#>
[CmdletBinding()]
param(
    [string] $Title = 'DeepSeek Harness',
    [string] $LogFile = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]] $ProtocolArgument = @()
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $home_ = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
    $LogFile = Join-Path $home_ 'logs\permission-notify.log'
}

function Write-ActivateLog {
    param([string] $Message)
    try {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ('{0} [activate] {1}' -f (Get-Date).ToString('o'), $Message) -Encoding UTF8
    } catch { }
}

if (-not ([System.Management.Automation.PSTypeName]'DshActivateWin32').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DshActivateWin32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
"@
}

function Get-ForegroundTitle {
    $hwnd = [DshActivateWin32]::GetForegroundWindow()
    $sb = New-Object System.Text.StringBuilder 512
    [DshActivateWin32]::GetWindowText($hwnd, $sb, 512) | Out-Null
    return $sb.ToString()
}

# 带 -Title 参数时用于手工测试；协议调用时按标题子串找主窗口。
$target = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$Title*" } | Select-Object -First 1
if (-not $target) {
    Write-ActivateLog "no window matching '$Title' (arg='$ProtocolArgument')"
    exit 0
}
$hwnd = $target.MainWindowHandle
Write-ActivateLog "target pid=$($target.Id) hwnd=$hwnd title='$($target.MainWindowTitle)'"

[void] [DshActivateWin32]::ShowWindowAsync($hwnd, 9)   # SW_RESTORE

# 1) ALT 解前台锁 + SetForegroundWindow（实测有效）
[DshActivateWin32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[DshActivateWin32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
[void] [DshActivateWin32]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 250
$fg = Get-ForegroundTitle
if ($fg -like "*$Title*") {
    Write-ActivateLog "ok via ALT+SetForegroundWindow (foreground='$fg')"
    exit 0
}
Write-ActivateLog "ALT+SetForegroundWindow landed on '$fg', retrying with AttachThreadInput"

# 2) AttachThreadInput + SetForegroundWindow
try {
    $fgHwnd = [DshActivateWin32]::GetForegroundWindow()
    $fgPid = 0
    $fgThread = [DshActivateWin32]::GetWindowThreadProcessId($fgHwnd, [ref] $fgPid)
    $targetPid_ = 0
    $targetThread = [DshActivateWin32]::GetWindowThreadProcessId($hwnd, [ref] $targetPid_)
    $myThread = [DshActivateWin32]::GetCurrentThreadId()
    if ($fgThread -ne 0) { [void] [DshActivateWin32]::AttachThreadInput($myThread, $fgThread, $true) }
    if ($targetThread -ne 0) { [void] [DshActivateWin32]::AttachThreadInput($myThread, $targetThread, $true) }
    [void] [DshActivateWin32]::BringWindowToTop($hwnd)
    [void] [DshActivateWin32]::SetForegroundWindow($hwnd)
    if ($fgThread -ne 0) { [void] [DshActivateWin32]::AttachThreadInput($myThread, $fgThread, $false) }
    if ($targetThread -ne 0) { [void] [DshActivateWin32]::AttachThreadInput($myThread, $targetThread, $false) }
    Start-Sleep -Milliseconds 250
    $fg2 = Get-ForegroundTitle
    if ($fg2 -like "*$Title*") {
        Write-ActivateLog "ok via AttachThreadInput+SetForegroundWindow (foreground='$fg2')"
        exit 0
    }
    Write-ActivateLog "AttachThreadInput attempt landed on '$fg2'"
} catch {
    Write-ActivateLog "AttachThreadInput failed: $($_.Exception.Message)"
}

exit 0
