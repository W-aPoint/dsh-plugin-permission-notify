<#
.SYNOPSIS
    安装 / 卸载 dsh-plugin-permission-notify 到某个 DSH profile。

.DESCRIPTION
    1. 把 package/ 复制到 $DSH_HOME\plugins\dsh-plugin-permission-notify
    2. 在 profile 的 node_modules 下建立目录联接（junction），使插件可被解析
    3. 在 profile 的 cordis.patch.yml 末尾写入一段带标记的 insert 补丁
       （幂等：重复运行会整体替换这一段，并自动备份原文件）

    通知走 Windows 原生 Toast + 系统提示音，不需要额外编译。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DefaultPreset off
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -SkipExistingSessions
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string] $Profile = 'desktop',
    [string] $DefaultPreset = 'auto',
    [switch] $NoSound,
    [switch] $SkipExistingSessions,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$PackageName = 'dsh-plugin-permission-notify'
$EntryId = 'permission-notify'
$BeginMarker = '# >>> dsh-plugin-permission-notify >>>'
$EndMarker = '# <<< dsh-plugin-permission-notify <<<'
$SourceDir = Join-Path $PSScriptRoot 'package'
$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$ProfileDir = Join-Path $DshHome (Join-Path 'profiles' $Profile)
$InstallDir = Join-Path (Join-Path $DshHome 'plugins') $PackageName
$NodeModules = Join-Path $ProfileDir 'node_modules'
$LinkPath = Join-Path $NodeModules $PackageName
$PatchPath = Join-Path $ProfileDir 'cordis.patch.yml'

function Write-Utf8NoBom {
    param([string] $Path, [string] $Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-LinkOrDir {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        # junction / symlink：只删链接，不动目标目录
        [System.IO.Directory]::Delete($Path, $false)
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Remove-ManagedBlock {
    <#
      只删除「包含 id: permission-notify 的那个 - insert: 条目」以及我们自己的标记注释。
      不能按 `# >>> ... # <<<` 区间整段删除：dsh 的插件管理器之后可能把别的条目写进
      这两行标记之间，整段删会把用户的插件配置一起删掉。
    #>
    param([string] $Text)

    $lines = $Text -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]

        if ($line -match '^\s*#\s*(>>>|<{3})\s*dsh-plugin-permission-notify') { $i++; continue }

        if ($line -match '^-\s+insert:\s*$') {
            $block = New-Object System.Collections.Generic.List[string]
            $block.Add($line)
            $j = $i + 1
            while ($j -lt $lines.Count) {
                $next = $lines[$j]
                if ($next -match '^\S') { break }          # 下一个顶层条目 / 标记
                $block.Add($next)
                $j++
            }
            $blockText = ($block -join "`n")
            if ($blockText -match 'id:\s*permission-notify') { $i = $j; continue }   # 丢掉我们自己的条目
            foreach ($kept in $block) { $out.Add($kept) }
            $i = $j
            continue
        }

        $out.Add($line)
        $i++
    }

    return (($out -join "`n").TrimEnd() + "`n")
}

if (-not (Test-Path -LiteralPath $ProfileDir)) {
    throw "找不到 profile 目录：$ProfileDir（用 -Profile 指定其他 profile，或先启动一次 DSH）"
}
if (-not (Test-Path -LiteralPath $PatchPath)) {
    Write-Utf8NoBom -Path $PatchPath -Text "[]`n"
}

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    Copy-Item -LiteralPath $PatchPath -Destination "$PatchPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
    $text = Get-Content -LiteralPath $PatchPath -Raw -Encoding UTF8
    if ($text -match [regex]::Escape($BeginMarker)) {
        Write-Utf8NoBom -Path $PatchPath -Text ((Remove-ManagedBlock $text).TrimEnd() + "`n")
        Write-Host "[OK] 已从 patch 中移除插件条目。" -ForegroundColor Green
    } else {
        Write-Host "[--] patch 中没有本插件的条目。" -ForegroundColor DarkGray
    }
    Remove-LinkOrDir -Path $LinkPath
    Write-Host "[OK] 已删除 node_modules 链接：$LinkPath" -ForegroundColor Green
    try {
        Remove-Item -LiteralPath 'HKCU:\Software\Classes\dshnotify' -Recurse -Force -ErrorAction Stop
        Write-Host "[OK] 已注销 dshnotify: 协议（点击通知跳转用）。" -ForegroundColor Green
    } catch {
        Write-Host "[--] 没有需要注销的 dshnotify: 协议。" -ForegroundColor DarkGray
    }
    Write-Host "     插件文件仍保留在：$InstallDir（可手动删除）。" -ForegroundColor DarkGray
    Write-Host "     重启 DeepSeek Harness 后生效。"
    return
}

# ---------------------------------------------------------------- install
if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'index.js'))) {
    throw "找不到插件源目录：$SourceDir"
}

Write-Host "==> 安装插件文件到 $InstallDir"
if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
New-Item -ItemType Directory -Path (Split-Path -Parent $InstallDir) -Force | Out-Null
# 注意：Copy-Item -Path "<dir>\*" -Recurse 会把子目录内容拍平（PS 5.1 的老毛病），
# 这里整目录拷贝，保证 assets/notify.ps1 的层级不变。
Copy-Item -LiteralPath $SourceDir -Destination $InstallDir -Recurse -Force

Write-Host "==> 建立 node_modules 链接"
Remove-LinkOrDir -Path $LinkPath
if (-not (Test-Path -LiteralPath $NodeModules)) { New-Item -ItemType Directory -Path $NodeModules -Force | Out-Null }
cmd /c mklink /J "`"$LinkPath`"" "`"$InstallDir`"" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "    junction 建立失败，退化为复制包目录。" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $LinkPath -Force | Out-Null
    Copy-Item -LiteralPath $SourceDir -Destination $LinkPath -Recurse -Force
}

$sound = if ($NoSound) { 'false' } else { 'true' }
$sweep = if ($SkipExistingSessions) { 'false' } else { 'true' }

# 注册 dshnotify: 协议 → assets/activate.vbs（无窗口启动 activate.ps1，把 DSH 拉到前台）
Write-Host "==> 注册 dshnotify: 协议"
$activateScript = Join-Path $InstallDir 'assets\activate.ps1'
$activateLauncher = Join-Path $InstallDir 'assets\activate.vbs'
$protocolRoot = 'HKCU:\Software\Classes\dshnotify'
New-Item -Path $protocolRoot -Force | Out-Null
New-ItemProperty -Path $protocolRoot -Name '(default)' -Value 'URL:DeepSeek Harness Notify' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $protocolRoot -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
New-Item -Path "$protocolRoot\shell\open\command" -Force | Out-Null
$activateCommand = '"{0}" //nologo "{1}" "%1"' -f (Join-Path $env:SystemRoot 'System32\wscript.exe'), $activateLauncher
New-ItemProperty -Path "$protocolRoot\shell\open\command" -Name '(default)' -Value $activateCommand -PropertyType String -Force | Out-Null
Write-Host "    已注册：$activateCommand" -ForegroundColor Green

$block = @"
$BeginMarker
# 由 install.ps1 管理：重复运行会整块替换，卸载会整块删除。
- insert:
    - id: $EntryId
      name: $PackageName
      config:
        defaultPreset: $DefaultPreset
        applyToExistingSessions: $sweep
        notifyTurnEnd: true
        notifyApproval: true
        notifyQuestion: true
        sound: $sound
        appId: com.deepseek.dsh
        includeSnippet: true
        clickToFocus: true
$EndMarker
"@

Write-Host "==> 写入 profile patch：$PatchPath"
Copy-Item -LiteralPath $PatchPath -Destination "$PatchPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
$text = Get-Content -LiteralPath $PatchPath -Raw -Encoding UTF8
$text = Remove-ManagedBlock $text
if ($text.Trim() -eq '') { $text = '' }
Write-Utf8NoBom -Path $PatchPath -Text ($text.TrimEnd() + "`n" + $block + "`n")

# 提示 Auto review 是否随安装启用
$bundles = Join-Path $ProfileDir 'package.json'
$hasAutoReview = $false
if (Test-Path -LiteralPath $bundles) {
    $hasAutoReview = (Get-Content -LiteralPath $bundles -Raw -Encoding UTF8) -match 'dsh-experimental-auto-review'
}
if ($DefaultPreset -eq 'auto' -and -not $hasAutoReview) {
    Write-Host "[!] profile 未声明 @deepseek-ai/dsh-experimental-auto-review，'auto' 预设不可用。" -ForegroundColor Yellow
    Write-Host "    请先在 Web 侧栏「插件」页启用自动审查，或把 defaultPreset 改成 workspace-write / danger-full-access。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[OK] 安装完成。" -ForegroundColor Green
Write-Host "  插件目录 : $InstallDir"
Write-Host "  链接     : $LinkPath"
Write-Host "  patch    : $PatchPath"
Write-Host "  默认预设 : $DefaultPreset    声音: $sound    覆盖已有会话: $sweep"
Write-Host "  通知形态 : Windows 原生 Toast（AppUserModelID com.deepseek.dsh）"
Write-Host ""
Write-Host "重启 DeepSeek Harness 后生效。通知投递日志：~\.dsh\logs\permission-notify.log" -ForegroundColor Cyan
