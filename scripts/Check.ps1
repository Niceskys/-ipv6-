[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:ProgramData\CampusIPv6Lab\config.json",
    [string]$StatePath  = "$env:ProgramData\CampusIPv6Lab\state.json",
    [string]$LogPath    = "$env:ProgramData\CampusIPv6Lab\helper.log"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "SilentlyContinue"

$TaskName = "CampusIPv6LabHelper"
$pass = 0
$warn = 0
$fail = 0

function Mark {
    param([string]$Level, [string]$Message)
    if ($Level -eq "PASS") {
        $script:pass++
        Write-Host "[PASS] $Message" -ForegroundColor Green
    } elseif ($Level -eq "WARN") {
        $script:warn++
        Write-Host "[WARN] $Message" -ForegroundColor Yellow
    } else {
        $script:fail++
        Write-Host "[FAIL] $Message" -ForegroundColor Red
    }
}

function Test-IPv6InPrefix {
    param([string]$Address,[string]$Prefix)
    try {
        $parts = $Prefix.Split("/")
        if ($parts.Count -ne 2) { return $false }
        $prefixLength = [int]$parts[1]
        if ($prefixLength -lt 0 -or $prefixLength -gt 128) { return $false }

        $addrIp = [System.Net.IPAddress]::Parse($Address)
        $netIp = [System.Net.IPAddress]::Parse($parts[0])
        if ($addrIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return $false }
        if ($netIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return $false }

        $a = $addrIp.GetAddressBytes()
        $n = $netIp.GetAddressBytes()
        $fullBytes = [math]::Floor($prefixLength / 8)
        $remainingBits = $prefixLength % 8

        for ($i=0; $i -lt $fullBytes; $i++) {
            if ($a[$i] -ne $n[$i]) { return $false }
        }

        if ($remainingBits -gt 0) {
            $mask = (0xFF -shl (8 - $remainingBits)) -band 0xFF
            if (($a[$fullBytes] -band $mask) -ne ($n[$fullBytes] -band $mask)) { return $false }
        }

        return $true
    } catch {
        return $false
    }
}

Write-Host "===== Campus IPv6 Lab / Check =====" -ForegroundColor Cyan

if (-not (Test-Path $ConfigPath)) {
    Mark "FAIL" "未找到配置文件：$ConfigPath"
    exit 2
}

try {
    $config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Mark "FAIL" "配置文件无法解析：$($_.Exception.Message)"
    exit 2
}

if (-not ($config.PSObject.Properties.Name -contains "Version") -or [int]$config.Version -lt 2) {
    Mark "FAIL" "配置版本过旧或不完整。"
    exit 2
}

Mark "PASS" "已读取配置 Version=$($config.Version)"
Write-Host "CampusPrefix  : $($config.CampusPrefix)"
Write-Host "NodeIPv6Prefix: $($config.NodeIPv6Prefix)"

Write-Host ""
Write-Host "===== Scheduled Task =====" -ForegroundColor Cyan

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    Mark "PASS" "计划任务存在，State=$($task.State)"
    if ($info) {
        Write-Host ("LastRunTime={0} LastTaskResult={1}" -f $info.LastRunTime, $info.LastTaskResult)
        if ([int64]$info.LastTaskResult -eq 267009) {
            Write-Host "0x41301/267009 表示连续任务当前正在运行。"
        }
    }
} else {
    Mark "FAIL" "计划任务不存在：$TaskName"
}

Write-Host ""
Write-Host "===== Campus Safety Gate =====" -ForegroundColor Cyan

$physical = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq "Up" })
$physicalIndexes = @($physical | ForEach-Object { [int]$_.ifIndex })
$defaults = @(
    Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" -PolicyStore ActiveStore |
    Where-Object { $physicalIndexes -contains [int]$_.InterfaceIndex }
)

$campusMatches = @()
foreach ($route in $defaults) {
    $addresses = @(
        Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv6 |
        Where-Object {
            $_.AddressState -ne "Invalid" -and
            (Test-IPv6InPrefix -Address ([string]$_.IPAddress) -Prefix ([string]$config.CampusPrefix))
        }
    )

    if ($addresses.Count -gt 0 -and ([string]$route.NextHop).ToLowerInvariant().StartsWith("fe80:")) {
        $campusMatches += [pscustomobject]@{
            InterfaceIndex = [int]$route.InterfaceIndex
            InterfaceAlias = [string]$route.InterfaceAlias
            NextHop = [string]$route.NextHop
            Addresses = $addresses
        }
    }
}

if ($campusMatches.Count -gt 0) {
    $ctx = $campusMatches | Select-Object -First 1
    Mark "PASS" "检测到安装时记录的校园 /64：$($ctx.InterfaceAlias) ifIndex=$($ctx.InterfaceIndex) nextHop=$($ctx.NextHop)"

    foreach ($addr in @($ctx.Addresses)) {
        Write-Host ("  {0} PrefixOrigin={1} SuffixOrigin={2} State={3} SkipAsSource={4}" -f $addr.IPAddress, $addr.PrefixOrigin, $addr.SuffixOrigin, $addr.AddressState, $addr.SkipAsSource)
    }

    $raBad = @(
        Get-NetIPAddress -InterfaceIndex $ctx.InterfaceIndex -AddressFamily IPv6 |
        Where-Object { [string]$_.PrefixOrigin -eq "RouterAdvertisement" -and -not [bool]$_.SkipAsSource }
    )
    $dhcpBad = @(
        Get-NetIPAddress -InterfaceIndex $ctx.InterfaceIndex -AddressFamily IPv6 |
        Where-Object { [string]$_.PrefixOrigin -eq "Dhcp" -and [bool]$_.SkipAsSource }
    )

    if ($raBad.Count -eq 0 -and $dhcpBad.Count -eq 0) {
        Mark "PASS" "IPv6 源地址策略符合当前实验基线（RA=True, DHCP=False）。"
    } else {
        Mark "WARN" "IPv6 源地址策略尚未完全达到实验基线；等待 Helper 下一轮或查看日志。"
    }
} else {
    Mark "WARN" "当前未检测到安装时记录的校园 /64。Helper 应处于 Fail-Closed/恢复状态。"
}

Write-Host ""
Write-Host "===== CrushCloud =====" -ForegroundColor Cyan

$cores = @()
$legacy = @(Get-CimInstance Win32_Process -Filter "Name='crushcloudCore.exe'")
foreach ($p in $legacy) {
    $cores += [pscustomobject]@{
        Name = [string]$p.Name
        Id = [int]$p.ProcessId
        Path = [string]$p.ExecutablePath
        Detection = "LegacyProcessName"
    }
}

$fl = @(Get-CimInstance Win32_Process -Filter "Name='FlClashCore.exe'")
foreach ($p in $fl) {
    $path = [string]$p.ExecutablePath
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $frontend = Join-Path (Split-Path -Parent $path) "crushcloud.exe"
        if (Test-Path $frontend) {
            $cores += [pscustomobject]@{
                Name = [string]$p.Name
                Id = [int]$p.ProcessId
                Path = $path
                Detection = "PathQualifiedFlClashCore"
            }
        }
    }
}

if ($cores.Count -gt 0) {
    Mark "PASS" "检测到 CrushCloud Core。"
    $cores | Format-Table Name,Id,Detection,Path -AutoSize

    $nodeConnections = @()
    foreach ($core in $cores) {
        $nodeConnections += @(
            Get-NetTCPConnection -OwningProcess $core.Id |
            Where-Object {
                (Test-IPv6InPrefix -Address ([string]$_.RemoteAddress) -Prefix ([string]$config.NodeIPv6Prefix))
            }
        )
    }

    if ($nodeConnections.Count -gt 0) {
        Mark "PASS" "检测到符合节点 IPv6 前缀的核心连接。"
        $nodeConnections | Sort-Object RemoteAddress,RemotePort -Unique |
            Format-Table State,LocalAddress,LocalPort,RemoteAddress,RemotePort -AutoSize
    } else {
        Mark "WARN" "当前未捕获到符合 NodeIPv6Prefix 的核心连接；可能尚未建立连接或节点地址范围已变化。"
    }
} else {
    Mark "WARN" "未检测到 CrushCloud Core。若客户端当前未启动，这是正常的。"
}

Write-Host ""
Write-Host "===== Mobile Hotspot =====" -ForegroundColor Cyan

$hotspot = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { [string]$_.IPAddress -eq [string]$config.HotspotIPv4 } |
    Select-Object -First 1

if ($hotspot) {
    $ipIf = Get-NetIPInterface -InterfaceIndex $hotspot.InterfaceIndex -AddressFamily IPv4 | Select-Object -First 1
    $mtu = $null
    if ($ipIf) {
        if ($ipIf.PSObject.Properties.Name -contains "NlMtu") {
            $mtu = [int]$ipIf.NlMtu
        } elseif ($ipIf.PSObject.Properties.Name -contains "NlMtuBytes") {
            $mtu = [int]$ipIf.NlMtuBytes
        }
    }

    Write-Host ("Hotspot: {0} ifIndex={1} MTU={2}" -f $hotspot.InterfaceAlias, $hotspot.InterfaceIndex, $mtu)

    if ($cores.Count -gt 0 -and $campusMatches.Count -gt 0) {
        if ($mtu -eq [int]$config.HotspotMTU) {
            Mark "PASS" "热点 MTU=$mtu。"
        } else {
            Mark "WARN" "热点已激活，但 MTU=$mtu，目标值为 $($config.HotspotMTU)。"
        }
    }
} else {
    Write-Host "$($config.HotspotIPv4) 热点当前未激活。"
}

Write-Host ""
Write-Host "===== Managed State =====" -ForegroundColor Cyan

if (Test-Path $StatePath) {
    try {
        $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "State Version       : $($state.Version)"
    Write-Host "NonCampusMisses     : $($state.NonCampusMisses)"
    Write-Host "ManagedAddresses    : $(@($state.ManagedAddresses).Count)"
    Write-Host "ManagedRoutes       : $(@($state.ManagedRoutes).Count)"
    Write-Host "HotspotManaged      : $($state.Hotspot.Managed)"

    if (@($state.ManagedRoutes).Count -gt 0) {
        $state.ManagedRoutes | Format-Table DestinationPrefix,InterfaceIndex,NextHop -AutoSize
    }
    } catch {
        Mark "FAIL" "状态文件存在但无法解析：$($_.Exception.Message)"
    }
} else {
    Mark "WARN" "状态文件尚未创建。任务可能刚安装，等待几秒后重试。"
}

Write-Host ""
Write-Host "===== Recent Log =====" -ForegroundColor Cyan

if (Test-Path $LogPath) {
    Get-Content $LogPath -Tail 25
} else {
    Write-Host "日志尚不存在。"
}

Write-Host ""
Write-Host "===== Summary =====" -ForegroundColor Cyan
Write-Host "PASS=$pass WARN=$warn FAIL=$fail"

if ($fail -gt 0) {
    exit 2
} elseif ($warn -gt 0) {
    exit 1
} else {
    exit 0
}
