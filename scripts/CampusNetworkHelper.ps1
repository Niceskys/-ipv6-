[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:ProgramData\CampusIPv6Lab\config.json",
    [string]$StatePath  = "$env:ProgramData\CampusIPv6Lab\state.json",
    [string]$LogPath    = "$env:ProgramData\CampusIPv6Lab\helper.log",
    [switch]$Once,
    [switch]$RestoreAndExit
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Ensure-ParentDirectory {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    try {
        Ensure-ParentDirectory -Path $LogPath
        if (Test-Path $LogPath) {
            $item = Get-Item $LogPath -ErrorAction SilentlyContinue
            if ($item -and $item.Length -gt 2097152) {
                $old = "$LogPath.1"
                if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
                Move-Item $LogPath $old -Force -ErrorAction SilentlyContinue
            }
        }
        $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch {
    }
}

function Load-Config {
    if (-not (Test-Path $ConfigPath)) {
        throw "Config not found: $ConfigPath"
    }
    return (Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function New-State {
    return [pscustomobject]@{
        Version = 1
        NonCampusMisses = 0
        ManagedAddresses = @()
        ManagedRoutes = @()
        Hotspot = [pscustomobject]@{
            Managed = $false
            InterfaceGuid = ""
            InterfaceAlias = ""
            InterfaceIndex = -1
            OriginalMtu = 0
        }
        LastCampusSeen = $null
    }
}

function Normalize-State {
    param($State)

    if (-not ($State.PSObject.Properties.Name -contains "Version")) {
        Add-Member -InputObject $State -NotePropertyName Version -NotePropertyValue 1
    }
    if (-not ($State.PSObject.Properties.Name -contains "NonCampusMisses")) {
        Add-Member -InputObject $State -NotePropertyName NonCampusMisses -NotePropertyValue 0
    }
    if (-not ($State.PSObject.Properties.Name -contains "ManagedAddresses")) {
        Add-Member -InputObject $State -NotePropertyName ManagedAddresses -NotePropertyValue @()
    }
    if (-not ($State.PSObject.Properties.Name -contains "ManagedRoutes")) {
        Add-Member -InputObject $State -NotePropertyName ManagedRoutes -NotePropertyValue @()
    }
    if (-not ($State.PSObject.Properties.Name -contains "Hotspot")) {
        Add-Member -InputObject $State -NotePropertyName Hotspot -NotePropertyValue ([pscustomobject]@{
            Managed = $false
            InterfaceGuid = ""
            InterfaceAlias = ""
            InterfaceIndex = -1
            OriginalMtu = 0
        })
    }
    if (-not ($State.PSObject.Properties.Name -contains "LastCampusSeen")) {
        Add-Member -InputObject $State -NotePropertyName LastCampusSeen -NotePropertyValue $null
    }

    return $State
}

function Load-State {
    if (-not (Test-Path $StatePath)) {
        return (New-State)
    }

    try {
        $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return (Normalize-State -State $state)
    } catch {
        Write-Log "State file exists but is unreadable. Refusing to continue because rollback ownership would be lost. Error=$($_.Exception.Message)" "ERROR"
        throw "State file is unreadable: $StatePath"
    }
}

function Save-State {
    param($State)
    Ensure-ParentDirectory -Path $StatePath
    $tmp = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $StatePath -Force
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

function Get-PhysicalDefaultRoutes {
    $physical = @(
        Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq "Up" }
    )

    $physicalIndexes = @($physical | ForEach-Object { [int]$_.ifIndex })
    if ($physicalIndexes.Count -eq 0) { return @() }

    $routes = @(
        Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Where-Object { $physicalIndexes -contains [int]$_.InterfaceIndex }
    )

    $result = @()
    foreach ($route in $routes) {
        $ipIf = Get-NetIPInterface -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | Select-Object -First 1
        $metric = [int]$route.RouteMetric
        if ($ipIf) { $metric += [int]$ipIf.InterfaceMetric }

        $adapter = $physical | Where-Object { [int]$_.ifIndex -eq [int]$route.InterfaceIndex } | Select-Object -First 1
        $adapterGuid = ""
        if ($adapter) { $adapterGuid = [string]$adapter.InterfaceGuid }

        $result += [pscustomobject]@{
            InterfaceIndex = [int]$route.InterfaceIndex
            InterfaceAlias = $route.InterfaceAlias
            InterfaceGuid = $adapterGuid
            NextHop = [string]$route.NextHop
            Metric = $metric
        }
    }

    return @($result | Sort-Object Metric)
}

function Get-CampusContext {
    param($Config)

    $campusPrefix = [string]$Config.CampusPrefix
    $routes = @(Get-PhysicalDefaultRoutes)

    foreach ($route in $routes) {
        $addresses = @(
            Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.AddressState -ne "Invalid" -and
                (Test-IPv6InPrefix -Address ([string]$_.IPAddress) -Prefix $campusPrefix)
            }
        )

        if ($addresses.Count -gt 0 -and ([string]$route.NextHop).ToLowerInvariant().StartsWith("fe80:")) {
            return [pscustomobject]@{
                Detected = $true
                Reason = "CampusPrefix+PhysicalIPv6DefaultRoute"
                InterfaceIndex = $route.InterfaceIndex
                InterfaceAlias = $route.InterfaceAlias
                InterfaceGuid = $route.InterfaceGuid
                NextHop = $route.NextHop
                Addresses = $addresses
            }
        }
    }

    return [pscustomobject]@{
        Detected = $false
        Reason = "NoStrongCampusSignature"
        InterfaceIndex = -1
        InterfaceAlias = ""
        InterfaceGuid = ""
        NextHop = ""
        Addresses = @()
    }
}

function Get-CrushCoreProcesses {
    $result = @()

    $legacy = @(Get-CimInstance Win32_Process -Filter "Name='crushcloudCore.exe'" -ErrorAction SilentlyContinue)
    foreach ($p in $legacy) {
        $result += [pscustomobject]@{
            ProcessId = [int]$p.ProcessId
            Name = [string]$p.Name
            Path = [string]$p.ExecutablePath
            Detection = "LegacyProcessName"
        }
    }

    $fl = @(Get-CimInstance Win32_Process -Filter "Name='FlClashCore.exe'" -ErrorAction SilentlyContinue)
    foreach ($p in $fl) {
        $path = [string]$p.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $dir = Split-Path -Parent $path
        $frontend = Join-Path $dir "crushcloud.exe"

        if (Test-Path $frontend) {
            $result += [pscustomobject]@{
                ProcessId = [int]$p.ProcessId
                Name = [string]$p.Name
                Path = $path
                Detection = "PathQualifiedFlClashCore"
            }
        }
    }

    return @($result)
}

function Ensure-SourceAddressPolicy {
    param($Context, $State)

    $addresses = @(
        Get-NetIPAddress -InterfaceIndex $Context.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.AddressState -ne "Invalid" }
    )

    foreach ($addr in $addresses) {
        $origin = [string]$addr.PrefixOrigin
        $desired = $null

        if ($origin -eq "RouterAdvertisement") {
            $desired = $true
        } elseif ($origin -eq "Dhcp") {
            $desired = $false
        } else {
            continue
        }

        if ([bool]$addr.SkipAsSource -eq [bool]$desired) { continue }

        $alreadyManaged = @(
            $State.ManagedAddresses |
            Where-Object {
                [int]$_.InterfaceIndex -eq [int]$Context.InterfaceIndex -and
                [string]$_.IPAddress -eq [string]$addr.IPAddress
            }
        ).Count -gt 0

        if (-not $alreadyManaged) {
            $State.ManagedAddresses = @($State.ManagedAddresses) + [pscustomobject]@{
                InterfaceIndex = [int]$Context.InterfaceIndex
                IPAddress = [string]$addr.IPAddress
                OriginalSkipAsSource = [bool]$addr.SkipAsSource
            }
            Save-State -State $State
        }

        Set-NetIPAddress -InterfaceIndex $Context.InterfaceIndex -IPAddress $addr.IPAddress -SkipAsSource ([bool]$desired) -ErrorAction Stop
        Write-Log "Source policy: $($addr.IPAddress) PrefixOrigin=$origin SkipAsSource=$desired"
    }
}

function Get-NodeRemoteAddresses {
    param($Config, $CoreProcesses)

    $nodePrefix = [string]$Config.NodeIPv6Prefix
    $remotes = @()

    foreach ($core in $CoreProcesses) {
        $connections = @(
            Get-NetTCPConnection -OwningProcess $core.ProcessId -ErrorAction SilentlyContinue |
            Where-Object {
                [string]$_.State -eq "Established" -and
                -not [string]::IsNullOrWhiteSpace([string]$_.RemoteAddress) -and
                ([string]$_.RemoteAddress).Contains(":") -and
                (Test-IPv6InPrefix -Address ([string]$_.RemoteAddress) -Prefix $nodePrefix)
            }
        )

        foreach ($conn in $connections) {
            $remotes += [string]$conn.RemoteAddress
        }
    }

    return @($remotes | Sort-Object -Unique)
}

function Ensure-NodeRoutes {
    param($Config, $Context, $State, $CoreProcesses)

    $remotes = @(Get-NodeRemoteAddresses -Config $Config -CoreProcesses $CoreProcesses)

    foreach ($remote in $remotes) {
        $destination = "$remote/128"

        $existing = @(
            Get-NetRoute -AddressFamily IPv6 -DestinationPrefix $destination -PolicyStore ActiveStore -ErrorAction SilentlyContinue
        )

        $good = @(
            $existing |
            Where-Object {
                [int]$_.InterfaceIndex -eq [int]$Context.InterfaceIndex -and
                [string]$_.NextHop -eq [string]$Context.NextHop
            }
        )

        if ($good.Count -gt 0) { continue }

        if ($existing.Count -gt 0) {
            Write-Log "Exact node route already exists but is not owned by this helper; skipped: $destination" "WARN"
            continue
        }

        $tracked = @(
            $State.ManagedRoutes |
            Where-Object {
                [string]$_.DestinationPrefix -eq $destination -and
                [int]$_.InterfaceIndex -eq [int]$Context.InterfaceIndex -and
                [string]$_.NextHop -eq [string]$Context.NextHop
            }
        ).Count -gt 0

        if (-not $tracked) {
            $State.ManagedRoutes = @($State.ManagedRoutes) + [pscustomobject]@{
                DestinationPrefix = $destination
                InterfaceIndex = [int]$Context.InterfaceIndex
                NextHop = [string]$Context.NextHop
            }

            # Write ownership before changing the route table.
            # If route creation later fails, rollback can safely see an absent route
            # and clear this record.
            Save-State -State $State
        }

        try {
            New-NetRoute -DestinationPrefix $destination -InterfaceIndex $Context.InterfaceIndex -NextHop $Context.NextHop -AddressFamily IPv6 -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
            Write-Log "Added node bypass: $destination -> ifIndex=$($Context.InterfaceIndex) nextHop=$($Context.NextHop)"
        } catch {
            Write-Log "Failed to add node bypass $destination. Ownership record is retained for safe retry/rollback. Error=$($_.Exception.Message)" "ERROR"
        }
    }
}

function Get-HotspotInterface {
    param($Config)

    $hotspotIp = [string]$Config.HotspotIPv4
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.IPAddress -eq $hotspotIp } |
        Select-Object -First 1

    if (-not $ip) { return $null }

    $adapter = Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1
    $ipIf = Get-NetIPInterface -InterfaceIndex $ip.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $ipIf) { return $null }

    $adapterGuid = ""
    if ($adapter) { $adapterGuid = [string]$adapter.InterfaceGuid }

    $mtu = 0
    if ($ipIf.PSObject.Properties.Name -contains "NlMtu") {
        $mtu = [int]$ipIf.NlMtu
    } elseif ($ipIf.PSObject.Properties.Name -contains "NlMtuBytes") {
        $mtu = [int]$ipIf.NlMtuBytes
    }

    return [pscustomobject]@{
        InterfaceIndex = [int]$ip.InterfaceIndex
        InterfaceAlias = [string]$ip.InterfaceAlias
        InterfaceGuid = $adapterGuid
        Mtu = $mtu
    }
}

function Ensure-HotspotMtu {
    param($Config, $State)

    $hotspot = Get-HotspotInterface -Config $Config
    if (-not $hotspot) { return $false }

    $target = [int]$Config.HotspotMTU

    if ([bool]$State.Hotspot.Managed) {
        $sameAdapter = $false

        if (
            -not [string]::IsNullOrWhiteSpace([string]$State.Hotspot.InterfaceGuid) -and
            -not [string]::IsNullOrWhiteSpace([string]$hotspot.InterfaceGuid)
        ) {
            $sameAdapter = ([string]$State.Hotspot.InterfaceGuid -eq [string]$hotspot.InterfaceGuid)
        } else {
            $sameAdapter = ([int]$State.Hotspot.InterfaceIndex -eq [int]$hotspot.InterfaceIndex)
        }

        if (-not $sameAdapter) {
            Write-Log "Hotspot interface changed; restoring the previously managed interface before adopting the new one." "WARN"
            Restore-HotspotMtu -State $State

            if ([bool]$State.Hotspot.Managed) {
                Write-Log "Previous hotspot MTU could not be restored; refusing to manage the new hotspot interface." "ERROR"
                return $false
            }
        }
    }

    if (-not [bool]$State.Hotspot.Managed) {
        if ($hotspot.Mtu -le 0) {
            Write-Log "Unable to determine original hotspot MTU; refusing to modify it." "ERROR"
            return $false
        }

        $State.Hotspot.Managed = $true
        $State.Hotspot.InterfaceGuid = $hotspot.InterfaceGuid
        $State.Hotspot.InterfaceAlias = $hotspot.InterfaceAlias
        $State.Hotspot.InterfaceIndex = $hotspot.InterfaceIndex
        $State.Hotspot.OriginalMtu = $hotspot.Mtu
        Save-State -State $State
        Write-Log "Managing hotspot MTU: alias=$($hotspot.InterfaceAlias) ifIndex=$($hotspot.InterfaceIndex) originalMTU=$($hotspot.Mtu) targetMTU=$target"
    }

    if ($hotspot.Mtu -ne $target) {
        Set-NetIPInterface -InterfaceIndex $hotspot.InterfaceIndex -AddressFamily IPv4 -NlMtuBytes $target -ErrorAction Stop
        Write-Log "Applied hotspot MTU=$target to $($hotspot.InterfaceAlias)"
    }

    return $true
}

function Restore-HotspotMtu {
    param($State)

    if (-not [bool]$State.Hotspot.Managed) { return }

    $adapter = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$State.Hotspot.InterfaceGuid)) {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.InterfaceGuid -eq [string]$State.Hotspot.InterfaceGuid } |
            Select-Object -First 1
    }

    if (-not $adapter -and [int]$State.Hotspot.InterfaceIndex -ge 0) {
        $adapter = Get-NetAdapter -InterfaceIndex ([int]$State.Hotspot.InterfaceIndex) -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if (-not $adapter) {
        Write-Log "Managed hotspot adapter is currently unavailable; keeping rollback state instead of discarding ownership." "WARN"
        return
    }

    if ([int]$State.Hotspot.OriginalMtu -le 0) {
        Write-Log "Managed hotspot has no valid OriginalMtu; keeping rollback state." "ERROR"
        return
    }

    try {
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -NlMtuBytes ([int]$State.Hotspot.OriginalMtu) -ErrorAction Stop
        Write-Log "Restored hotspot MTU: alias=$($adapter.Name) ifIndex=$($adapter.ifIndex) MTU=$($State.Hotspot.OriginalMtu)"
    } catch {
        Write-Log "Failed to restore hotspot MTU. Error=$($_.Exception.Message)" "ERROR"
        return
    }

    $State.Hotspot.Managed = $false
    $State.Hotspot.InterfaceGuid = ""
    $State.Hotspot.InterfaceAlias = ""
    $State.Hotspot.InterfaceIndex = -1
    $State.Hotspot.OriginalMtu = 0
    Save-State -State $State
}

function Restore-ManagedRoutes {
    param($State)

    $remaining = @()

    foreach ($route in @($State.ManagedRoutes)) {
        try {
            $existing = @(
                Get-NetRoute -AddressFamily IPv6 -DestinationPrefix ([string]$route.DestinationPrefix) -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
                Where-Object {
                    [int]$_.InterfaceIndex -eq [int]$route.InterfaceIndex -and
                    [string]$_.NextHop -eq [string]$route.NextHop
                }
            )

            if ($existing.Count -gt 0) {
                Remove-NetRoute -DestinationPrefix ([string]$route.DestinationPrefix) -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop ([string]$route.NextHop) -AddressFamily IPv6 -Confirm:$false -ErrorAction Stop
                Write-Log "Removed managed route: $($route.DestinationPrefix)"
            } else {
                Write-Log "Managed route already absent: $($route.DestinationPrefix)"
            }
        } catch {
            Write-Log "Failed to remove managed route $($route.DestinationPrefix). Error=$($_.Exception.Message)" "ERROR"
            $remaining += $route
        }
    }

    $State.ManagedRoutes = @($remaining)
    Save-State -State $State
}

function Restore-ManagedAddresses {
    param($State)

    $remaining = @()

    foreach ($record in @($State.ManagedAddresses)) {
        try {
            $addr = Get-NetIPAddress -InterfaceIndex ([int]$record.InterfaceIndex) -IPAddress ([string]$record.IPAddress) -AddressFamily IPv6 -ErrorAction SilentlyContinue | Select-Object -First 1

            if ($addr) {
                Set-NetIPAddress -InterfaceIndex ([int]$record.InterfaceIndex) -IPAddress ([string]$record.IPAddress) -SkipAsSource ([bool]$record.OriginalSkipAsSource) -ErrorAction Stop
                Write-Log "Restored SkipAsSource=$($record.OriginalSkipAsSource): $($record.IPAddress)"
            }
        } catch {
            Write-Log "Failed to restore SkipAsSource for $($record.IPAddress). Error=$($_.Exception.Message)" "ERROR"
            $remaining += $record
        }
    }

    $State.ManagedAddresses = @($remaining)
    Save-State -State $State
}

function Test-HasManagedChanges {
    param($State)

    return (
        [bool]$State.Hotspot.Managed -or
        @($State.ManagedRoutes).Count -gt 0 -or
        @($State.ManagedAddresses).Count -gt 0
    )
}

function Restore-AllManagedChanges {
    param($State)

    Restore-HotspotMtu -State $State
    Restore-ManagedRoutes -State $State
    Restore-ManagedAddresses -State $State
}

try {
    $config = Load-Config
    $state = Load-State

    if ($RestoreAndExit) {
        Write-Log "RestoreAndExit requested."
        Restore-AllManagedChanges -State $state

        $pendingAddressCount = @($state.ManagedAddresses).Count
        $pendingRouteCount = @($state.ManagedRoutes).Count
        $pendingHotspot = [bool]$state.Hotspot.Managed

        if ($pendingAddressCount -gt 0 -or $pendingRouteCount -gt 0 -or $pendingHotspot) {
            Write-Log "RestoreAndExit incomplete: addresses=$pendingAddressCount routes=$pendingRouteCount hotspot=$pendingHotspot" "ERROR"
            exit 2
        }

        Write-Log "RestoreAndExit completed."
        exit 0
    }

    Write-Log "CampusNetworkHelper started. interval=$($config.IntervalSeconds)s hotspotMTU=$($config.HotspotMTU) campusPrefix=$($config.CampusPrefix) nodePrefix=$($config.NodeIPv6Prefix)"

    do {
        try {
            $context = Get-CampusContext -Config $config

            if ($context.Detected) {
                if ([int]$state.NonCampusMisses -ne 0) {
                    $state.NonCampusMisses = 0
                    Save-State -State $state
                }

                $now = Get-Date
                $saveLastSeen = $false

                if ($null -eq $state.LastCampusSeen -or [string]::IsNullOrWhiteSpace([string]$state.LastCampusSeen)) {
                    $saveLastSeen = $true
                } else {
                    try {
                        $previousSeen = [datetime]::Parse([string]$state.LastCampusSeen)
                        if (($now - $previousSeen).TotalSeconds -ge 60) {
                            $saveLastSeen = $true
                        }
                    } catch {
                        $saveLastSeen = $true
                    }
                }

                if ($saveLastSeen) {
                    $state.LastCampusSeen = $now.ToString("o")
                    Save-State -State $state
                }

                Ensure-SourceAddressPolicy -Context $context -State $state

                $cores = @(Get-CrushCoreProcesses)
                if ($cores.Count -gt 0) {
                    Ensure-NodeRoutes -Config $config -Context $context -State $state -CoreProcesses $cores
                    [void](Ensure-HotspotMtu -Config $config -State $state)
                } else {
                    Restore-HotspotMtu -State $state
                    Restore-ManagedRoutes -State $state
                }
            } else {
                if ([int]$state.NonCampusMisses -lt [int]$config.NonCampusMissThreshold) {
                    $state.NonCampusMisses = [int]$state.NonCampusMisses + 1
                    Save-State -State $state
                }

                if (
                    [int]$state.NonCampusMisses -ge [int]$config.NonCampusMissThreshold -and
                    (Test-HasManagedChanges -State $state)
                ) {
                    Restore-AllManagedChanges -State $state
                }
            }
        } catch {
            Write-Log "Loop error: $($_.Exception.Message)" "ERROR"
        }

        if (-not $Once) {
            Start-Sleep -Seconds ([int]$config.IntervalSeconds)
        }
    } while (-not $Once)

    exit 0
} catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "ERROR"
    exit 1
}
