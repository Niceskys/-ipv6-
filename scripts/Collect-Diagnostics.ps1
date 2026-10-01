[CmdletBinding()]
param(
    [string]$OutputPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "SilentlyContinue"

$InstallDir = Join-Path $env:ProgramData "CampusIPv6Lab"
$ConfigPath = Join-Path $InstallDir "config.json"
$StatePath = Join-Path $InstallDir "state.json"
$LogPath = Join-Path $InstallDir "helper.log"
$TaskName = "CampusIPv6LabHelper"

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) ("diagnostics-{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

function Append-Line {
    param([string]$Text = "")
    Add-Content -Path $OutputPath -Value $Text -Encoding UTF8
}

function Append-Section {
    param([string]$Title, [scriptblock]$Body)

    Append-Line ""
    Append-Line ("===== {0} =====" -f $Title)

    try {
        $text = (& $Body 2>&1 | Out-String -Width 240).TrimEnd()
        if ([string]::IsNullOrWhiteSpace($text)) {
            Append-Line "(no output)"
        } else {
            Append-Line $text
        }
    } catch {
        Append-Line ("ERROR: {0}" -f $_.Exception.Message)
    }
}

Set-Content -Path $OutputPath -Value "Campus IPv6 Lab diagnostics" -Encoding UTF8
Append-Line ("GeneratedAt: {0}" -f (Get-Date).ToString("o"))
Append-Line "This report intentionally does not read subscription URLs, browser data, cookies, passwords or tokens."

Append-Section "OS" {
    Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption,Version,BuildNumber,OSArchitecture,LastBootUpTime
}

Append-Section "Physical adapters" {
    Get-NetAdapter -Physical |
        Select-Object ifIndex,Name,InterfaceDescription,Status,LinkSpeed,MacAddress
}

Append-Section "IPv6 addresses" {
    Get-NetIPAddress -AddressFamily IPv6 |
        Select-Object InterfaceIndex,InterfaceAlias,IPAddress,PrefixLength,PrefixOrigin,SuffixOrigin,AddressState,SkipAsSource
}

Append-Section "IPv6 default routes" {
    Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" |
        Select-Object InterfaceIndex,InterfaceAlias,DestinationPrefix,NextHop,RouteMetric,PolicyStore
}

Append-Section "IPv6 interfaces" {
    Get-NetIPInterface -AddressFamily IPv6 |
        Select-Object ifIndex,InterfaceAlias,ConnectionState,InterfaceMetric,Forwarding,Dhcp
}

Append-Section "Project scheduled task" {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $task | Select-Object TaskName,State
        Get-ScheduledTaskInfo -TaskName $TaskName |
            Select-Object LastRunTime,LastTaskResult,NextRunTime
    } else {
        "Task not installed."
    }
}

Append-Section "CrushCloud processes" {
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -in @("crushcloud.exe","crushcloudCore.exe","FlClashCore.exe") } |
        Select-Object Name,ProcessId,ExecutablePath
}

Append-Section "Port 7890 TCP" {
    Get-NetTCPConnection -LocalPort 7890 -ErrorAction SilentlyContinue |
        Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess
}

Append-Section "Port 7890 UDP" {
    Get-NetUDPEndpoint -LocalPort 7890 -ErrorAction SilentlyContinue |
        Select-Object LocalAddress,LocalPort,OwningProcess
}

Append-Section "Windows hotspot" {
    $ips = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -like "192.168.137.*" }

    $ips | Select-Object InterfaceIndex,InterfaceAlias,IPAddress,PrefixLength

    foreach ($ip in @($ips)) {
        Get-NetIPInterface -InterfaceIndex $ip.InterfaceIndex -AddressFamily IPv4 |
            Select-Object ifIndex,InterfaceAlias,ConnectionState,InterfaceMetric,NlMtu,NlMtuBytes
    }
}

Append-Section "Project config" {
    if (Test-Path $ConfigPath) {
        Get-Content $ConfigPath -Raw -Encoding UTF8
    } else {
        "Config not found."
    }
}

Append-Section "Project state" {
    if (Test-Path $StatePath) {
        Get-Content $StatePath -Raw -Encoding UTF8
    } else {
        "State not found."
    }
}

Append-Section "Recent helper log" {
    if (Test-Path $LogPath) {
        Get-Content $LogPath -Tail 100
    } else {
        "Log not found."
    }
}

Append-Section "Exact /128 IPv6 routes" {
    Get-NetRoute -AddressFamily IPv6 |
        Where-Object { $_.DestinationPrefix -like "*/128" } |
        Select-Object InterfaceIndex,InterfaceAlias,DestinationPrefix,NextHop,RouteMetric,PolicyStore
}

Append-Line ""
Append-Line "===== END ====="

Write-Host "诊断报告已生成：" -ForegroundColor Green
Write-Host $OutputPath
Write-Host ""
Write-Host "发送给 AI/同学前仍建议快速检查一次内容；本脚本不会读取订阅、密码、Token 或浏览器数据。"
