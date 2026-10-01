[CmdletBinding()]
param(
    [string]$CampusPrefixText = "2001:da8:a012:",
    [string]$NodeIPv6PrefixText = "2406:da18:",
    [int]$HotspotMTU = 1400,
    [int]$IntervalSeconds = 5,
    [int]$NonCampusMissThreshold = 3,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$TaskName = "CampusIPv6LabHelper"
$LegacyTaskName = "CampusIPv6AutoFix"
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

function Get-CandidateCampusRoute {
    param([string]$PrefixText)

    $physical = @(
        Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq "Up" }
    )

    $physicalIndexes = @($physical | ForEach-Object { [int]$_.ifIndex })
    if ($physicalIndexes.Count -eq 0) { return $null }

    $routes = @(
        Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Where-Object { $physicalIndexes -contains [int]$_.InterfaceIndex }
    )

    $candidates = @()

    foreach ($route in $routes) {
        $addresses = @(
            Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.AddressState -ne "Invalid" -and
                ([string]$_.IPAddress).ToLowerInvariant().StartsWith($PrefixText.ToLowerInvariant())
            }
        )

        if ($addresses.Count -eq 0) { continue }
        if (-not ([string]$route.NextHop).ToLowerInvariant().StartsWith("fe80:")) { continue }

        $ipIf = Get-NetIPInterface -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | Select-Object -First 1
        $metric = [int]$route.RouteMetric
        if ($ipIf) { $metric += [int]$ipIf.InterfaceMetric }

        $adapter = $physical | Where-Object { [int]$_.ifIndex -eq [int]$route.InterfaceIndex } | Select-Object -First 1
        $guid = ""
        if ($adapter) { $guid = [string]$adapter.InterfaceGuid }

        $candidates += [pscustomobject]@{
            InterfaceIndex = [int]$route.InterfaceIndex
            InterfaceAlias = [string]$route.InterfaceAlias
            InterfaceGuid = $guid
            InterfaceDescription = if ($adapter) { [string]$adapter.InterfaceDescription } else { "" }
            NextHop = [string]$route.NextHop
            Metric = $metric
            Addresses = $addresses
        }
    }

    return @($candidates | Sort-Object Metric | Select-Object -First 1)
}

if (-not (Test-Administrator)) {
    Write-Host "需要管理员 PowerShell。请右键 PowerShell -> 以管理员身份运行。" -ForegroundColor Red
    exit 1
}

if ($HotspotMTU -lt 1200 -or $HotspotMTU -gt 1500) {
    throw "HotspotMTU must be between 1200 and 1500."
}

if ($IntervalSeconds -lt 3) {
    throw "IntervalSeconds must be at least 3."
}

Write-Host "===== Campus IPv6 Lab / 安装前检查 =====" -ForegroundColor Cyan
Write-Host "本脚本只在检测到指定校园 IPv6 前缀 + 物理 IPv6 默认路由时安装。"
Write-Host "CampusPrefixText : $CampusPrefixText"
Write-Host "NodeIPv6Prefix   : $NodeIPv6PrefixText"
Write-Host ""

$legacyTask = Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue
if ($legacyTask) {
    Write-Host "检测到旧任务 '$LegacyTaskName'。" -ForegroundColor Yellow
    Write-Host "为避免两个自动修复任务同时改路由/MTU，本通用安装器拒绝继续。"
    Write-Host "参考机请继续使用原稳定版；后续单独提供迁移流程。"
    exit 2
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask -and -not $Force) {
    Write-Host "已存在任务 '$TaskName'。如确认需要覆盖，请重新运行并加 -Force。" -ForegroundColor Yellow
    exit 3
}

$candidate = Get-CandidateCampusRoute -PrefixText $CampusPrefixText
if (-not $candidate) {
    Write-Host "未检测到强校园 IPv6 特征，停止安装，不修改系统。" -ForegroundColor Red
    Write-Host "请确认：当前连接校园有线网络、IPv6 已启用、并且已正常认证。"
    exit 4
}

Write-Host "检测到候选校园上行：" -ForegroundColor Green
Write-Host ("  接口       : {0} (ifIndex={1})" -f $candidate.InterfaceAlias, $candidate.InterfaceIndex)
Write-Host ("  描述       : {0}" -f $candidate.InterfaceDescription)
Write-Host ("  IPv6 网关  : {0}" -f $candidate.NextHop)
Write-Host "  校园 IPv6  :"
foreach ($addr in @($candidate.Addresses)) {
    Write-Host ("    {0}  PrefixOrigin={1} SkipAsSource={2}" -f $addr.IPAddress, $addr.PrefixOrigin, $addr.SkipAsSource)
}

if (-not $Force) {
    Write-Host ""
    $answer = Read-Host "确认这是你当前要配置的校园网络吗？输入 YES 继续"
    if ($answer -ne "YES") {
        Write-Host "用户取消。未修改系统。"
        exit 5
    }
}

$sourceHelper = Join-Path $PSScriptRoot "CampusNetworkHelper.ps1"
$sourceCheck = Join-Path $PSScriptRoot "Check.ps1"
$sourceUninstall = Join-Path $PSScriptRoot "Uninstall.ps1"
$sourceDiagnostics = Join-Path $PSScriptRoot "Collect-Diagnostics.ps1"

if (-not (Test-Path $sourceHelper)) {
    throw "Missing file: $sourceHelper"
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

Copy-Item $sourceHelper $HelperPath -Force
if (Test-Path $sourceCheck) { Copy-Item $sourceCheck (Join-Path $InstallDir "Check.ps1") -Force }
if (Test-Path $sourceUninstall) { Copy-Item $sourceUninstall (Join-Path $InstallDir "Uninstall.ps1") -Force }
if (Test-Path $sourceDiagnostics) { Copy-Item $sourceDiagnostics (Join-Path $InstallDir "Collect-Diagnostics.ps1") -Force }

$config = [pscustomobject]@{
    Version = 1
    Purpose = "Campus IPv6 configuration experiment"
    InstalledAt = (Get-Date).ToString("o")
    CampusPrefixText = $CampusPrefixText
    NodeIPv6PrefixText = $NodeIPv6PrefixText
    HotspotIPv4 = "192.168.137.1"
    HotspotMTU = $HotspotMTU
    IntervalSeconds = $IntervalSeconds
    NonCampusMissThreshold = $NonCampusMissThreshold
    InstallObservation = [pscustomobject]@{
        InterfaceGuid = $candidate.InterfaceGuid
        InterfaceAlias = $candidate.InterfaceAlias
        InterfaceIndex = $candidate.InterfaceIndex
        GatewayAtInstall = $candidate.NextHop
    }
}

$config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8

if ($existingTask) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$q = [char]34
$arguments = "-NoProfile -ExecutionPolicy Bypass -File $q$HelperPath$q -ConfigPath $q$ConfigPath$q -StatePath $q$StatePath$q -LogPath $q$LogPath$q"

$action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Campus IPv6 configuration experiment helper. Fail-closed outside the configured campus IPv6 prefix." -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2

Write-Host ""
Write-Host "===== 安装完成 =====" -ForegroundColor Green
Write-Host "任务名称 : $TaskName"
Write-Host "配置文件 : $ConfigPath"
Write-Host "状态文件 : $StatePath"
Write-Host "日志文件 : $LogPath"
Write-Host ""
Write-Host "下一步请运行：" -ForegroundColor Cyan
Write-Host "  powershell -ExecutionPolicy Bypass -File .\Check.ps1"
Write-Host ""
Write-Host "注意：如果 Check 出现 FAIL，不要继续做大流量测试，先按 docs/07-故障排查.md 处理。"
