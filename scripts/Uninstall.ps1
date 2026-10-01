[CmdletBinding()]
param(
    [switch]$KeepLogs
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$TaskName = "CampusIPv6LabHelper"
$InstallDir = Join-Path $env:ProgramData "CampusIPv6Lab"
$ConfigPath = Join-Path $InstallDir "config.json"
$StatePath = Join-Path $InstallDir "state.json"
$LogPath = Join-Path $InstallDir "helper.log"
$HelperPath = Join-Path $InstallDir "CampusNetworkHelper.ps1"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Host "需要管理员 PowerShell。" -ForegroundColor Red
    exit 1
}

Write-Host "===== Campus IPv6 Lab / Uninstall =====" -ForegroundColor Cyan
Write-Host "本卸载器只恢复本项目状态文件中记录的修改，不执行 Windows 网络重置。"
Write-Host ""

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "停止计划任务：$TaskName"
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

if (Test-Path $HelperPath) {
    Write-Host "恢复本项目管理的临时修改..."
    $powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $q = [char]34
    $args = "-NoProfile -ExecutionPolicy Bypass -File $q$HelperPath$q -ConfigPath $q$ConfigPath$q -StatePath $q$StatePath$q -LogPath $q$LogPath$q -RestoreAndExit"

    $p = Start-Process -FilePath $powerShellExe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) {
        Write-Host "恢复脚本返回失败（ExitCode=$($p.ExitCode)）。为避免丢失恢复状态，卸载已停止。" -ForegroundColor Red
        Write-Host "请保留目录：$InstallDir"
        exit 2
    }
} elseif (Test-Path $StatePath) {
    Write-Host "存在状态文件但 Helper 丢失，拒绝直接删除状态。" -ForegroundColor Red
    Write-Host "请根据 docs/08-恢复与卸载.md 人工处理。"
    exit 3
}

if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "已删除计划任务。"
}

$backupLog = $null
if ($KeepLogs -and (Test-Path $LogPath)) {
    $backupLog = Join-Path ([Environment]::GetFolderPath("Desktop")) ("CampusIPv6Lab-uninstall-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Copy-Item $LogPath $backupLog -Force
}

if (Test-Path $InstallDir) {
    Remove-Item $InstallDir -Recurse -Force
}

Write-Host ""
Write-Host "===== 卸载完成 =====" -ForegroundColor Green
Write-Host "已处理："
Write-Host "  - 本项目计划任务"
Write-Host "  - 本项目记录的热点 MTU 修改"
Write-Host "  - 本项目创建的节点 /128 路由"
Write-Host "  - 本项目记录的 SkipAsSource 修改"
Write-Host ""
Write-Host "未处理（有意保留）："
Write-Host "  - CrushCloud 本体及账号"
Write-Host "  - 其他 VPN/代理软件"
Write-Host "  - Windows IPv6"
Write-Host "  - 系统默认路由"
Write-Host "  - 物理网卡 MTU"

if ($backupLog) {
    Write-Host "卸载日志备份：$backupLog"
}
