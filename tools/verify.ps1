<#
.SYNOPSIS
    离线自测：把插件放进一个能解析 @deepseek-ai/schemastery 的沙盒目录，
    再用假 cordis ctx 驱动它，验证事件接线与配置解析（不需要重启 dsh）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify.ps1
#>
[CmdletBinding()]
param(
    [string] $Profile = 'desktop'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'package'
$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$profileModules = Join-Path $DshHome "profiles\$Profile\node_modules"
if (-not (Test-Path -LiteralPath $profileModules)) { throw "找不到 profile 的 node_modules：$profileModules" }

$sandbox = Join-Path $env:TEMP 'dsh-pn-verify'
if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $sandbox '.scratch') -Force | Out-Null

# node_modules 联接：让插件能解析 @deepseek-ai/schemastery
cmd /c mklink /J "`"$(Join-Path $sandbox 'node_modules')`"" "`"$profileModules`"" | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $sandbox 'pkg') -Recurse -Force

Push-Location $sandbox
try {
    & node (Join-Path $root 'tools\harness.mjs') (Join-Path $sandbox 'pkg\index.js')
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($code -eq 0) { Write-Host "`n[OK] 插件逻辑自测通过。" -ForegroundColor Green }
else { Write-Host "`n[FAIL] 插件逻辑自测失败（exit=$code）。" -ForegroundColor Red }
exit $code
