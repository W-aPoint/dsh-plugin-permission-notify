<#
.SYNOPSIS
    通知助手自检：直接调用 assets/notify.ps1，不经过 DSH。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-notify.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-notify.ps1 -NoSound
#>
[CmdletBinding()]
param(
    [string] $Title = 'DeepSeek Harness · 自检',
    [string] $Body = '原生通知已就绪（回答完成 / 需要你选择时会这样提示）',
    [string] $AppId = 'com.deepseek.dsh',
    [switch] $NoSound
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $root 'package\assets\notify.ps1'
if (-not (Test-Path -LiteralPath $helper)) { $helper = Join-Path $root 'assets\notify.ps1' }
if (-not (Test-Path -LiteralPath $helper)) { throw "找不到 notify.ps1" }

$log = Join-Path $env:TEMP 'permission-notify-selftest.log'
$payload = @{
    title   = $Title
    body    = $Body
    kind    = 'done'
    sound   = (-not $NoSound)
    appId   = $AppId
    detail  = '点击这条通知，DSH 窗口应该会被切到前台'
    clickToFocus = $true
    logFile = $log
} | ConvertTo-Json -Compress

$data = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
Write-Host "helper : $helper"
Write-Host "appId  : $AppId    sound: $(-not $NoSound)"
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Data $data
Write-Host "exit   : $LASTEXITCODE"
Write-Host "--- 日志 ---"
Get-Content -LiteralPath $log -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 5
