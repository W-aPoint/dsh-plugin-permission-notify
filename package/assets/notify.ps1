<#
.SYNOPSIS
    DeepSeek Harness 通知助手（Windows 原生 Toast，点击回到 DSH）。

.DESCRIPTION
    接收 dsh-plugin-permission-notify 传来的 base64(JSON)，用 Windows 原生
    Toast 显示标题 / 状态 / 内容片段，并按 payload.sound 决定是否带提示音。

    通知身份用 DSH 桌面端自己的 AppUserModelID（com.deepseek.dsh，来自开始菜单
    快捷方式的 System.AppUserModel.ID），因此通知以「DeepSeek Harness」的身份显示。

    点击处理：payload.clickToFocus 为真时，Toast 用 protocol 激活
    （launch="dshnotify:activate"）；该协议在安装时注册到 HKCU，指向
    assets/activate.ps1，由它把 DSH 主窗口切到前台。这样不需要常驻监听进程。

    任何失败都只写日志，绝不影响宿主。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Data
)

$ErrorActionPreference = 'Continue'

$payload = $null
try {
    $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Data))
    $payload = $json | ConvertFrom-Json
} catch {
    exit 0
}

function Write-NotifyLog {
    param([string] $Message)
    $target = $payload.logFile
    if ([string]::IsNullOrWhiteSpace($target)) { return }
    try {
        $dir = Split-Path -Parent $target
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = '{0} [helper] {1}' -f (Get-Date).ToString('o'), $Message
        Add-Content -LiteralPath $target -Value $line -Encoding UTF8
    } catch { }
}

$title = [string] $payload.title
$body = [string] $payload.body
$detail = [string] $payload.detail
$appId = [string] $payload.appId
if ([string]::IsNullOrWhiteSpace($appId)) { $appId = 'com.deepseek.dsh' }

if ($payload.sound) {
    $audioXml = '<audio src="ms-winsoundevent:Notification.Default" />'
} else {
    $audioXml = '<audio silent="true" />'
}

# ToastGeneric 支持最多 3 行文本：标题 / 状态 / 内容片段。
$escapedTitle = [System.Security.SecurityElement]::Escape($title)
$escapedBody = [System.Security.SecurityElement]::Escape($body)
if ([string]::IsNullOrWhiteSpace($detail)) {
    $textXml = "<text>$escapedTitle</text><text>$escapedBody</text>"
} else {
    $escapedDetail = [System.Security.SecurityElement]::Escape($detail)
    $textXml = "<text>$escapedTitle</text><text>$escapedBody</text><text>$escapedDetail</text>"
}

# 点击 toast → 走 dshnotify: 协议 → activate.ps1 把 DSH 拉到前台。
if ($payload.clickToFocus) {
    $activationXml = 'activationType="protocol" launch="dshnotify:activate"'
} else {
    $activationXml = 'activationType="foreground"'
}

$xml = @"
<toast $activationXml>
  <visual>
    <binding template="ToastGeneric">
      $textXml
    </binding>
  </visual>
  $audioXml
</toast>
"@

try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $document = New-Object Windows.Data.Xml.Dom.XmlDocument
    $document.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $document
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
    $setting = [string] $notifier.Setting
    if ($setting -eq 'Disabled' -or $setting -eq 'Unsupported') {
        throw "appId '$appId' 的通知被系统关闭或不受支持（setting=$setting）"
    }
    $notifier.Show($toast)
    Write-NotifyLog "toast shown via appId '$appId' (setting=$setting, click=$($payload.clickToFocus))"
} catch {
    Write-NotifyLog "toast failed: $($_.Exception.Message)"
    if ($payload.sound) {
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    }
}

exit 0
