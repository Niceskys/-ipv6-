[CmdletBinding()]
param(
    [string]$CampusAnchorPrefix = "2001:da8:a012::/48",
    [string]$NodeIPv6Prefix = "2406:da18::/32",
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

function Test-IPv6InPrefix {
    param(
        [string]$Address,
        [string]$Prefix
    )

    try {
        $parts = $Prefix.Split("/")
        if ($parts.Count -ne 2) { return $false }

        $prefixLength = [int]$parts[1]
        if ($prefixLength -lt 0 -or $prefixLength -gt 128) { return $false }

        $addrIp = [System.Net.IPAddress]::Parse($Address)
        $netIp = [System.Net.IPAddress]::Parse($parts[0])

        if ($addrIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return $false }
        if ($netIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return $false }

        $addrBytes = $addrIp.GetAddressBytes()
        $netBytes = $netIp.GetAddressBytes()

        $fullBytes = [math]::Floor($prefixLength / 8)
        $remainingBits = $prefixLength % 8

        for ($i = 0; $i -lt $fullBytes; $i++) {
            if ($addrBytes[$i] -ne $netBytes[$i]) { return $false }
        }

        if ($remainingBits -gt 0) {
            $mask = (0xFF -shl (8 - $remainingBits)) -band 0xFF
            if (($addrBytes[$fullBytes] -band $mask) -ne ($netBytes[$fullBytes] -band $mask)) {
                return $false
            }
        }

        return $true
    } catch {
        return $false
    }
}

function Get-IPv6Prefix64 {
    param([string]$Address)

    $ip = [System.Net.IPAddress]::Parse($Address)
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        throw "Not an IPv6 address: $Address"
    }

    $b = $ip.GetAddressBytes()

    $h0 = (($b[0] -shl 8) -bor $b[1])
    $h1 = (($b[2] -shl 8) -bor $b[3])
    $h2 = (($b[4] -shl 8) -bor $b[5])
    $h3 = (($b[6] -shl 8) -bor $b[7])

    return ("{0:x}:{1:x}:{2:x}:{3:x}::/64" -f $h0,$h1,$h2,$h3)
}

function Get-CandidateCampusRoute {
    param([string]$AnchorPrefix)

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
                (Test-IPv6InPrefix -Address ([string]$_.IPAddress) -Prefix $AnchorPrefix)
            }
        )

        if ($addresses.Count -eq 0) { continue }
        if (-not ([string]$route.NextHop).ToLowerInvariant().StartsWith("fe80:")) { continue }

        $ipIf = Get-NetIPInterface -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | Select-Object -First 1
        $metric = [int]$route.RouteMetric
        if ($ipIf) { $metric += [int]$ipIf.InterfaceMetric }

        $adapter = $physical | Where-Object { [int]$_.ifIndex -eq [int]$route.InterfaceIndex } | Select-Object -First 1

        $guid = ""
        $description = ""
        if ($adapter) {
            $guid = [string]$adapter.InterfaceGuid
            $description = [string]$adapter.InterfaceDescription
        }

        $candidates += [pscustomobject]@{
            InterfaceIndex = [int]$route.InterfaceIndex
            InterfaceAlias = [string]$route.InterfaceAlias
            InterfaceGuid = $guid
            InterfaceDescription = $description
            NextHop = [string]$route.NextHop
            Metric = $metric
            Addresses = $addresses
        }
    }

    return ($candidates | Sort-Object Metric | Select-Object -First 1)
}

if (-not (Test-Administrator)) {
    Write-Host "需要管理员 PowerShell。请以管理员身份运行。" -ForegroundColor Red
    exit 1
}

if (-not (Test-IPv6InPrefix -Address "2001:db8::1" -Prefix "2001:db8::/32")) {
    throw "Internal CIDR parser self-test failed."
}

if ($HotspotMTU -lt 1200 -or $HotspotMTU -gt 1500) {
    throw "HotspotMTU must be between 1200 and 1500."
}

if ($IntervalSeconds -lt 3) {
    throw "IntervalSeconds must be at least 3."
}

if ($NonCampusMissThreshold -lt 2) {
    throw "NonCampusMissThreshold must be at least 2."
}

Write-Host "===== Campus IPv6 Lab / 安装前检查 =====" -ForegroundColor Cyan
Write-Host "仅在检测到指定校园 IPv6 地址范围 + 物理 IPv6 默认路由时继续。"
Write-Host "安装识别范围 : $CampusAnchorPrefix"
Write-Host "节点地址范围 : $NodeIPv6Prefix"
Write-Host ""

$legacyTask = Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue
if ($legacyTask) {
    Write-Host "检测到旧任务 '$LegacyTaskName'。" -ForegroundColor Yellow
    Write-Host "为避免两个后台任务同时修改路由/MTU，本安装器拒绝继续。"
    Write-Host "请保留现有稳定配置，或先按单独的迁移流程处理。"
    exit 2
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask -or (Test-Path $InstallDir)) {
    Write-Host "检测到现有 CampusIPv6Lab 安装或残留目录。" -ForegroundColor Yellow
    Write-Host "为避免覆盖已有回退状态，本安装器不会原地覆盖。"
    Write-Host "请先运行 Run-Uninstall.cmd；若卸载失败，先保留现场并进行诊断。"
    exit 3
}

$candidate = Get-CandidateCampusRoute -AnchorPrefix $CampusAnchorPrefix
if (-not $candidate) {
    Write-Host "未检测到目标 IPv6 环境，停止安装，不修改系统。" -ForegroundColor Red
    Write-Host "请确认当前网络、IPv6 和认证状态。"
    exit 4
}

$preferredAddress = @(
    $candidate.Addresses |
    Sort-Object @{Expression={ if ([string]$_.PrefixOrigin -eq "Dhcp") { 0 } else { 1 } }}
)[0]

$runtimeCampusPrefix = Get-IPv6Prefix64 -Address ([string]$preferredAddress.IPAddress)

Write-Host "检测到候选上行：" -ForegroundColor Green
Write-Host ("  接口       : {0} (ifIndex={1})" -f $candidate.InterfaceAlias, $candidate.InterfaceIndex)
Write-Host ("  描述       : {0}" -f $candidate.InterfaceDescription)
Write-Host ("  IPv6 网关  : {0}" -f $candidate.NextHop)
Write-Host ("  运行时 /64 : {0}" -f $runtimeCampusPrefix)
Write-Host "  IPv6 地址  :"
foreach ($addr in @($candidate.Addresses)) {
    Write-Host ("    {0}  PrefixOrigin={1} SkipAsSource={2}" -f $addr.IPAddress, $addr.PrefixOrigin, $addr.SkipAsSource)
}

if (-not $Force) {
    Write-Host ""
    $answer = Read-Host "确认当前检测结果正确吗？输入 YES 继续"
    if ($answer -ne "YES") {
        Write-Host "已取消。未修改系统。"
        exit 5
    }
}

$sourceHelper = Join-Path $PSScriptRoot "CampusNetworkHelper.ps1"
$sourceCheck = Join-Path $PSScriptRoot "Check.ps1"
$sourceUninstall = Join-Path $PSScriptRoot "Uninstall.ps1"
$sourceDiagnostics = Join-Path $PSScriptRoot "Collect-Diagnostics.ps1"

foreach ($required in @($sourceHelper,$sourceCheck,$sourceUninstall,$sourceDiagnostics)) {
    if (-not (Test-Path $required)) {
        throw "Missing required file: $required"
    }
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

try {
    Copy-Item $sourceHelper $HelperPath -Force
    Copy-Item $sourceCheck (Join-Path $InstallDir "Check.ps1") -Force
    Copy-Item $sourceUninstall (Join-Path $InstallDir "Uninstall.ps1") -Force
    Copy-Item $sourceDiagnostics (Join-Path $InstallDir "Collect-Diagnostics.ps1") -Force

    $config = [pscustomobject]@{
        Version = 2
        Purpose = "Campus IPv6 configuration experiment"
        InstalledAt = (Get-Date).ToString("o")
        CampusAnchorPrefix = $CampusAnchorPrefix
        CampusPrefix = $runtimeCampusPrefix
        NodeIPv6Prefix = $NodeIPv6Prefix
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

    $powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $q = [char]34
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File $q$HelperPath$q -ConfigPath $q$ConfigPath$q -StatePath $q$StatePath$q -LogPath $q$LogPath$q"

    $action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Campus IPv6 configuration experiment helper. Fail-closed outside the recorded /64." -Force | Out-Null

    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
} catch {
    Write-Host "安装过程中发生错误：$($_.Exception.Message)" -ForegroundColor Red

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    if (-not (Test-Path $StatePath)) {
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "已产生状态文件，因此保留 $InstallDir 以便安全恢复。" -ForegroundColor Yellow
    }

    exit 6
}

Write-Host ""
Write-Host "===== 安装完成 =====" -ForegroundColor Green
Write-Host "任务名称 : $TaskName"
Write-Host "运行时前缀 : $runtimeCampusPrefix"
Write-Host "配置文件 : $ConfigPath"
Write-Host "状态文件 : $StatePath"
Write-Host "日志文件 : $LogPath"
Write-Host ""
Write-Host "下一步请运行：" -ForegroundColor Cyan
Write-Host "  .\Run-Check.cmd"
Write-Host ""
Write-Host "如果 Check 出现 FAIL，不要继续进行高负载测试，先保存输出并排查。"
