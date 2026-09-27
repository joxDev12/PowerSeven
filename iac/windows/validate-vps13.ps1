[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'provisioning.psd1'),
    [string]$UsersPath = (Join-Path $PSScriptRoot 'users.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$script:Warn = 0

function Find-ADGroupBySamAccountName {
    param([string]$SamAccountName)

    try {
        return Get-ADGroup -Identity $SamAccountName -ErrorAction Stop
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        return $null
    }
}

function Find-ADUserBySamAccountName {
    param([string]$SamAccountName)

    try {
        return Get-ADUser -Identity $SamAccountName -Properties Enabled -ErrorAction Stop
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        return $null
    }
}

function Report {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL', 'NEEDS_LIVE_TEST')]
        [string]$Status,
        [string]$Check,
        [string]$Detail
    )

    Write-Output ("{0}: {1}: {2}" -f $Status, $Check, $Detail)
    if ($Status -eq 'PASS') { $script:Pass++ }
    if ($Status -eq 'FAIL' -or $Status -eq 'NEEDS_LIVE_TEST') { $script:Fail++ }
    if ($Status -eq 'WARN') { $script:Warn++ }
}

if ($env:OS -ne 'Windows_NT') {
    Report 'NEEDS_LIVE_TEST' 'platform' 'validator must run on the live VPS13 Windows host'
    exit 2
}

try {
    $config = Import-PowerShellDataFile -Path $ConfigPath
    $users = Import-PowerShellDataFile -Path $UsersPath

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($os.Caption -match 'Windows Server 2022') { Report 'PASS' 'os' $os.Caption }
    else { Report 'FAIL' 'os' "expected Windows Server 2022, got $($os.Caption)" }

    $edition = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID' -ErrorAction SilentlyContinue).EditionID
    if ($edition -match 'ServerDatacenter') { Report 'PASS' 'os-edition' $edition }
    else { Report 'FAIL' 'os-edition' "expected ServerDatacenter, got $edition" }

    if ($env:COMPUTERNAME -eq $config.Hostname) { Report 'PASS' 'hostname' $config.Hostname }
    else { Report 'FAIL' 'hostname' "expected $($config.Hostname), got $env:COMPUTERNAME" }

    $ip = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $config.Network.Address -and $_.PrefixLength -eq $config.Network.PrefixLength })
    if ($ip.Count -gt 0) { Report 'PASS' 'ipv4' "$($config.Network.Address)/$($config.Network.PrefixLength)" }
    else { Report 'FAIL' 'ipv4' "missing $($config.Network.Address)/$($config.Network.PrefixLength)" }

    $gateway = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -eq $config.Network.Gateway })
    if ($gateway.Count -gt 0) { Report 'PASS' 'gateway' $config.Network.Gateway }
    else { Report 'FAIL' 'gateway' "missing default route via $($config.Network.Gateway)" }

    if ($ip.Count -gt 0) {
        $interfaceAliasProperty = $ip[0].PSObject.Properties['InterfaceAlias']
        if ($null -eq $interfaceAliasProperty -or [string]::IsNullOrWhiteSpace([string]$interfaceAliasProperty.Value)) {
            Report 'NEEDS_LIVE_TEST' 'dns-client' 'target IPv4 interface alias is unavailable'
        }
        elseif (-not (Get-Command -Name 'Get-DnsClientServerAddress' -ErrorAction SilentlyContinue)) {
            Report 'NEEDS_LIVE_TEST' 'dns-client' 'Get-DnsClientServerAddress is unavailable'
        }
        else {
            $expectedClientDns = @($config.Network.PostPromotionDns | ForEach-Object { [string]$_ })
            $actualClientDns = @((Get-DnsClientServerAddress -InterfaceAlias $interfaceAliasProperty.Value -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses |
                ForEach-Object { [string]$_ })
            if (($actualClientDns -join ',') -eq ($expectedClientDns -join ',')) {
                Report 'PASS' 'dns-client' ($expectedClientDns -join ', ')
            }
            else {
                Report 'FAIL' 'dns-client' "expected $($expectedClientDns -join ', '), got $($actualClientDns -join ', ')"
            }
        }
    }

    if (-not (Get-Command -Name 'Get-DnsServerForwarder' -ErrorAction SilentlyContinue)) {
        Report 'NEEDS_LIVE_TEST' 'dns-forwarders' 'Get-DnsServerForwarder is unavailable'
    }
    else {
        $expectedForwarders = @($config.Domain.Forwarders | ForEach-Object { [string]$_ })
        $actualForwarders = @((Get-DnsServerForwarder -ErrorAction SilentlyContinue).IPAddress |
            ForEach-Object { $_.IPAddressToString })
        if (($actualForwarders -join ',') -eq ($expectedForwarders -join ',')) {
            Report 'PASS' 'dns-forwarders' ($expectedForwarders -join ', ')
        }
        else {
            Report 'FAIL' 'dns-forwarders' "expected $($expectedForwarders -join ', '), got $($actualForwarders -join ', ')"
        }
    }

    foreach ($serviceName in @('NTDS', 'DNS')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service -and $service.Status -eq 'Running') { Report 'PASS' "service:$serviceName" 'running' }
        else { Report 'FAIL' "service:$serviceName" 'missing or not running' }
    }

    if (-not (Get-Command -Name 'Get-ADDomain' -ErrorAction SilentlyContinue)) {
        Report 'NEEDS_LIVE_TEST' 'activedirectory-module' 'ActiveDirectory PowerShell module is unavailable'
        exit 2
    }

    $domain = Get-ADDomain -Identity $config.Domain.Fqdn -ErrorAction SilentlyContinue
    if ($null -ne $domain -and
        $domain.DNSRoot.ToUpperInvariant() -eq $config.Domain.Fqdn.ToUpperInvariant() -and
        $domain.NetBIOSName.ToUpperInvariant() -eq $config.Domain.Netbios.ToUpperInvariant()) {
        Report 'PASS' 'domain' "$($domain.DNSRoot) / $($domain.NetBIOSName)"
    }
    else { Report 'FAIL' 'domain' "expected $($config.Domain.Fqdn) / $($config.Domain.Netbios)" }

    $forest = Get-ADForest -ErrorAction SilentlyContinue
    if ($null -ne $forest -and $forest.RootDomain.ToUpperInvariant() -eq $config.Domain.Fqdn.ToUpperInvariant()) {
        Report 'PASS' 'forest' $forest.RootDomain
    }
    else { Report 'FAIL' 'forest' "expected $($config.Domain.Fqdn)" }

    $zone = Get-DnsServerZone -Name $config.Domain.DnsZone -ErrorAction SilentlyContinue
    if ($null -ne $zone) { Report 'PASS' 'dns-zone' $config.Domain.DnsZone }
    else { Report 'FAIL' 'dns-zone' "missing $($config.Domain.DnsZone)" }

    $msdcs = Get-DnsServerZone -Name ("_msdcs.{0}" -f $config.Domain.DnsZone) -ErrorAction SilentlyContinue
    if ($null -ne $msdcs) { Report 'PASS' 'dns-zone:_msdcs' 'present' }
    else { Report 'WARN' 'dns-zone:_msdcs' 'not found; inspect AD DNS replication state' }

    foreach ($record in $config.DnsRecords) {
        $found = @(Get-DnsServerResourceRecord -ZoneName $config.Domain.DnsZone -Name $record.Name -RRType 'A' -ErrorAction SilentlyContinue |
            Where-Object { $_.RecordData.IPv4Address.IPAddressToString -eq $record.Address })
        if ($found.Count -gt 0) { Report 'PASS' "dns-record:$($record.Name)" $record.Address }
        else { Report 'FAIL' "dns-record:$($record.Name)" "expected $($record.Address)" }
    }

    foreach ($group in $users.GroupDefinitions) {
        $found = Find-ADGroupBySamAccountName -SamAccountName $group.Name
        if ($null -ne $found) { Report 'PASS' "group:$($group.Name)" 'present' }
        else { Report 'FAIL' "group:$($group.Name)" 'missing' }
    }

    foreach ($definition in $users.Users) {
        $found = Find-ADUserBySamAccountName -SamAccountName $definition.SamAccountName
        if ($null -eq $found) {
            Report 'FAIL' "user:$($definition.SamAccountName)" 'missing'
            continue
        }
        if ([bool]$found.Enabled -eq [bool]$definition.Enabled) {
            Report 'PASS' "user:$($definition.SamAccountName)" 'present; password not inspected'
        }
        else {
            Report 'FAIL' "user:$($definition.SamAccountName)" "enabled state differs from declaration"
        }
        $membership = @(Get-ADPrincipalGroupMembership -Identity $definition.SamAccountName -ErrorAction Stop |
            ForEach-Object { $_.SamAccountName })
        foreach ($group in $definition.Groups) {
            if ($membership -contains $group) { Report 'PASS' "membership:$($definition.SamAccountName)/$group" 'present' }
            else { Report 'FAIL' "membership:$($definition.SamAccountName)/$group" 'missing' }
        }
    }
}
catch {
    Report 'FAIL' 'validator' $_.Exception.Message
}

Write-Output ("SUMMARY: PASS={0}; WARN={1}; FAIL={2}" -f $script:Pass, $script:Warn, $script:Fail)
if ($script:Fail -gt 0) { exit 2 }
if ($script:Warn -gt 0) { exit 1 }
exit 0
