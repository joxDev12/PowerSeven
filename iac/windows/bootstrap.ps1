[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Apply,
    [ValidateSet('1', '2', '3', '4', '5', '6', '7', '8', 'All')]
    [string]$Checkpoint = 'All',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'provisioning.psd1'),
    [string]$UsersPath = (Join-Path $PSScriptRoot 'users.psd1'),
    [string]$SecretsPath = (Join-Path $PSScriptRoot 'secrets.psd1'),
    [string]$InterfaceAlias = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failure = $false
$script:Missing = $false
$script:RebootRequired = $false
$script:ReadOnly = -not $Apply

function Write-Result {
    param(
        [ValidateSet('PASS', 'WARN', 'MISSING', 'SKIP', 'FAIL', 'REBOOT_REQUIRED')]
        [string]$Status,
        [string]$Check,
        [string]$Detail,
        [switch]$NoPipeline
    )

    $line = ("{0}: {1}: {2}" -f $Status, $Check, $Detail)
    if ($NoPipeline) { Write-Host $line } else { Write-Output $line }
    if ($Status -eq 'FAIL') { $script:Failure = $true }
    if ($Status -eq 'MISSING' -and $script:ReadOnly) { $script:Missing = $true }
    if ($Status -eq 'REBOOT_REQUIRED') { $script:RebootRequired = $true }
}

function Import-Declaration {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label declaration is missing: $Path"
    }
    try {
        return Import-PowerShellDataFile -Path $Path
    }
    catch {
        throw "$Label declaration is invalid: $($_.Exception.Message)"
    }
}

function Test-RequiredCommand {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'cannot resolve an empty PowerShell command name'
    }
    if (Get-Command -Name $Name -ErrorAction SilentlyContinue) {
        return $true
    }
    if ($Apply) {
        Write-Result 'FAIL' "command:$Name" 'PowerShell cmdlet is not available for Apply' -NoPipeline
    }
    else {
        Write-Result 'MISSING' "command:$Name" 'PowerShell cmdlet is not available' -NoPipeline
    }
    return $false
}

function Skip-Checkpoint {
    param([string]$Number, [string]$Reason)

    if ($Apply) {
        Write-Result 'FAIL' "checkpoint$Number" "prerequisite unavailable: $Reason"
    }
    else {
        Write-Result 'SKIP' "checkpoint$Number" $Reason
    }
}

function Test-Declaration {
    $required = @('Hostname', 'Network', 'Domain', 'DnsRecords')
    foreach ($key in $required) {
        if (-not $Config.ContainsKey($key)) {
            throw "Provisioning declaration is missing: $key"
        }
    }

    $network = $Config.Network
    foreach ($key in @('Address', 'PrefixLength', 'Gateway', 'BootstrapDns', 'PostPromotionDns')) {
        if (-not $network.ContainsKey($key)) {
            throw "Network declaration is missing: $key"
        }
    }
    $domain = $Config.Domain
    foreach ($key in @('Fqdn', 'Netbios', 'DnsZone', 'Forwarders')) {
        if (-not $domain.ContainsKey($key)) {
            throw "Domain declaration is missing: $key"
        }
    }

    try {
        [void][System.Net.IPAddress]::Parse($network.Address)
        [void][System.Net.IPAddress]::Parse($network.Gateway)
        foreach ($dns in $network.BootstrapDns) { [void][System.Net.IPAddress]::Parse($dns) }
        foreach ($dns in $network.PostPromotionDns) { [void][System.Net.IPAddress]::Parse($dns) }
        foreach ($dns in $domain.Forwarders) { [void][System.Net.IPAddress]::Parse($dns) }
        foreach ($record in $Config.DnsRecords) { [void][System.Net.IPAddress]::Parse($record.Address) }
    }
    catch {
        throw "Invalid IPv4 value in provisioning declaration: $($_.Exception.Message)"
    }

    $recordNames = @($Config.DnsRecords | ForEach-Object { $_.Name })
    if ($recordNames.Count -ne (@($recordNames | Select-Object -Unique)).Count) {
        throw 'Provisioning declaration contains duplicate DNS records'
    }
    Write-Result 'PASS' 'declaration' 'VPS13 target, domain, forwarders and DNS records are valid'
}

function Test-SecretManifest {
    if (-not (Test-Path -LiteralPath $SecretsPath -PathType Leaf)) {
        Write-Result 'WARN' 'secret-manifest' 'secrets.psd1 is absent; Apply will prompt with SecureString at runtime'
        return
    }

    $manifest = Import-Declaration -Path $SecretsPath -Label 'Secret manifest'
    foreach ($key in @('Administrator', 'DirectoryServicesRestoreMode', 'UserPasswords')) {
        if (-not $manifest.ContainsKey($key)) {
            throw "Secret manifest is missing reference: $key"
        }
    }
    Write-Result 'PASS' 'secret-manifest' 'secret references are present; values are not read or printed'
}

function Test-BaseWindows {
    if (-not (Test-RequiredCommand 'Get-CimInstance')) { return }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($os.Caption -match 'Windows Server 2022') {
        Write-Result 'PASS' 'os-version' $os.Caption
    }
    else {
        Write-Result 'FAIL' 'os-version' "expected Windows Server 2022, got $($os.Caption)"
    }

    $edition = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID' -ErrorAction SilentlyContinue).EditionID
    if ($edition -match 'ServerDatacenter') {
        Write-Result 'PASS' 'os-edition' $edition
    }
    else {
        Write-Result 'FAIL' 'os-edition' "expected ServerDatacenter, got $edition"
    }

    $osKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    if ($null -eq $osKey) {
        Write-Result 'FAIL' 'desktop-experience' 'Windows version registry key is missing'
    }
    else {
        $installationType = [string]$osKey.InstallationType
        switch ($installationType) {
            'Server' {
                Write-Result 'PASS' 'desktop-experience' 'InstallationType=Server (Desktop Experience)'
            }
            'Server Core' {
                Write-Result 'FAIL' 'desktop-experience' 'InstallationType=Server Core; target requires Desktop Experience'
            }
            default {
                Write-Result 'FAIL' 'desktop-experience' "unknown or missing InstallationType: '$installationType'"
            }
        }
    }

    if (Test-RequiredCommand 'Get-WindowsCapability') {
        $ssh = @(Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1)
        if ($ssh.Count -eq 1 -and $ssh[0].State -eq 'Installed') {
            Write-Result 'PASS' 'openssh' 'OpenSSH Server capability is installed'
        }
        elseif (-not $Apply) {
            Write-Result 'MISSING' 'openssh' 'OpenSSH Server capability is not installed'
        }
        else {
            if ($ssh.Count -ne 1) { throw 'OpenSSH Server capability package was not found' }
            Add-WindowsCapability -Online -Name $ssh[0].Name | Out-Null
            $ssh = @(Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1)
            if ($ssh.Count -ne 1 -or $ssh[0].State -ne 'Installed') {
                throw 'OpenSSH Server capability installation did not complete'
            }
            Write-Result 'PASS' 'openssh' 'OpenSSH Server capability installed'
        }
    }

    $sshd = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    if ($null -ne $sshd) {
        if ($sshd.StartType -eq 'Automatic' -and $sshd.Status -eq 'Running') {
            Write-Result 'PASS' 'openssh-service' 'sshd is automatic and running'
        }
        elseif ($Apply) {
            Set-Service -Name 'sshd' -StartupType Automatic
            Start-Service -Name 'sshd'
            Write-Result 'PASS' 'openssh-service' 'sshd is now automatic and running'
        }
        else {
            Write-Result 'WARN' 'openssh-service' 'sshd exists but is not automatic/running'
        }
    }
    else {
        Write-Result 'MISSING' 'openssh-service' 'sshd service is not installed'
    }

    if ($Apply) {
        Enable-PSRemoting -SkipNetworkProfileCheck -Force | Out-Null
        Write-Result 'PASS' 'psremoting' 'PowerShell remoting enabled for future configuration management'
    }
    else {
        Write-Result 'WARN' 'psremoting' 'not changed during Check; Apply enables PowerShell remoting'
    }
}

function Resolve-Interface {
    $requested = $InterfaceAlias
    if ([string]::IsNullOrWhiteSpace($requested) -and $Config.ContainsKey('InterfaceAlias')) {
        $requested = [string]$Config.InterfaceAlias
    }

    if (-not (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue)) {
        if ($Apply) {
            Write-Result 'FAIL' 'command:Get-NetAdapter' 'PowerShell cmdlet is not available for networking' | Out-Null
        }
        else {
            Write-Result 'MISSING' 'command:Get-NetAdapter' 'PowerShell cmdlet is not available for networking' | Out-Null
        }
        return $null
    }
    if (-not [string]::IsNullOrWhiteSpace($requested)) {
        $adapters = @(Get-NetAdapter -Name $requested -ErrorAction SilentlyContinue)
        if ($adapters.Count -eq 0) {
            Write-Result 'FAIL' 'interface' "configured interface not found: $requested" | Out-Null
            return $null
        }
        if ($adapters.Count -gt 1) {
            Write-Result 'FAIL' 'interface' "configured alias matched multiple interfaces: $requested" | Out-Null
            return $null
        }
        return $adapters[0]
    }

    $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface })
    if ($adapters.Count -eq 1) {
        Write-Result 'PASS' 'interface' "auto-detected interface: $($adapters[0].Name)" | Out-Null
        return $adapters[0]
    }
    if ($adapters.Count -eq 0) {
        Write-Result 'MISSING' 'interface' 'no active physical interface found' | Out-Null
    }
    else {
        Write-Result 'FAIL' 'interface' 'multiple active interfaces; pass -InterfaceAlias explicitly' | Out-Null
    }
    return $null
}

function Get-InterfaceIndex {
    param([object]$Adapter)

    if ($null -eq $Adapter) {
        throw 'network interface object is null'
    }

    $property = $Adapter.PSObject.Properties['ifIndex']
    if ($null -eq $property) {
        $typeName = $Adapter.GetType().FullName
        $available = @($Adapter.PSObject.Properties.Name) -join ', '
        throw "Get-NetAdapter returned $typeName without ifIndex; available properties: $available"
    }
    if ($null -eq $property.Value) {
        throw 'Get-NetAdapter returned an interface with a null ifIndex'
    }

    try {
        return [uint32]$property.Value
    }
    catch {
        throw "Get-NetAdapter returned a non-numeric ifIndex: $($property.Value)"
    }
}

function Invoke-NetworkCheckpoint {
    foreach ($command in @('Get-NetIPAddress', 'Get-NetIPInterface', 'Get-NetRoute', 'Get-DnsClientServerAddress')) {
        if (-not (Test-RequiredCommand $command)) { return }
    }
    $network = $Config.Network
    $adapter = Resolve-Interface
    if ($null -eq $adapter) { return }
    $interfaceIndex = Get-InterfaceIndex -Adapter $adapter

    $hostname = $Config.Hostname
    if ($env:COMPUTERNAME -eq $hostname) {
        Write-Result 'PASS' 'hostname' $hostname
    }
    elseif ($Apply) {
        Rename-Computer -NewName $hostname -Force -ErrorAction Stop
        Write-Result 'REBOOT_REQUIRED' 'hostname' "renamed to $hostname; reboot before the next checkpoint"
        return
    }
    else {
        Write-Result 'WARN' 'hostname' "expected $hostname, got $env:COMPUTERNAME"
    }

    $current = @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -notlike '169.254.*' })
    $ipInterfaces = @(Get-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop)
    if ($ipInterfaces.Count -ne 1) {
        throw "expected one IPv4 interface state for $($adapter.Name), found $($ipInterfaces.Count)"
    }
    $dhcpProperty = $ipInterfaces[0].PSObject.Properties['Dhcp']
    if ($null -eq $dhcpProperty -or $null -eq $dhcpProperty.Value) {
        throw "Get-NetIPInterface returned no DHCP state for $($adapter.Name)"
    }
    $dhcpState = [string]$dhcpProperty.Value
    $desired = @($current | Where-Object { $_.IPAddress -eq $network.Address -and $_.PrefixLength -eq $network.PrefixLength })
    $manualConflicts = @($current | Where-Object {
        $_.IPAddress -ne $network.Address -and [string]$_.PrefixOrigin -eq 'Manual'
    })
    if ($manualConflicts.Count -gt 0) {
        throw "conflicting manual IPv4 address exists on $($adapter.Name); refusing to remove it"
    }

    if ($desired.Count -gt 0) {
        if ($Apply -and $dhcpState -ieq 'Enabled') {
            Set-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
            $ipInterfaces = @(Get-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop)
            if ($ipInterfaces.Count -ne 1 -or [string]$ipInterfaces[0].Dhcp -ine 'Disabled') {
                throw "failed to disable DHCP on $($adapter.Name)"
            }
        }
        if (-not $Apply -and $dhcpState -ieq 'Enabled') {
            Write-Result 'WARN' 'ipv4' "$($network.Address)/$($network.PrefixLength) exists but DHCP is still enabled"
        }
        else {
            Write-Result 'PASS' 'ipv4' "$($network.Address)/$($network.PrefixLength)"
        }
    }
    elseif (-not $Apply) {
        Write-Result 'MISSING' 'ipv4' "expected $($network.Address)/$($network.PrefixLength)"
    }
    else {
        if ($dhcpState -ieq 'Enabled') {
            Set-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
            $ipInterfaces = @(Get-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop)
            if ($ipInterfaces.Count -ne 1 -or [string]$ipInterfaces[0].Dhcp -ine 'Disabled') {
                throw "failed to disable DHCP on $($adapter.Name)"
            }
        }

        # Re-query after disabling DHCP; the previous CIM objects may be stale.
        $current = @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '169.254.*' })
        $desired = @($current | Where-Object { $_.IPAddress -eq $network.Address -and $_.PrefixLength -eq $network.PrefixLength })
        $stale = @($current | Where-Object { $_.IPAddress -ne $network.Address })
        foreach ($address in $stale) {
            if ([string]$address.PrefixOrigin -ne 'Dhcp') {
                throw "stale IPv4 $($address.IPAddress) has unsupported origin '$($address.PrefixOrigin)'; refusing removal"
            }
        }
        foreach ($address in @($stale | Sort-Object -Property IPAddress -Unique)) {
            Remove-NetIPAddress `
                -IPAddress ([string]$address.IPAddress) `
                -InterfaceIndex $interfaceIndex `
                -AddressFamily IPv4 `
                -Confirm:$false `
                -ErrorAction Stop
        }

        if ($desired.Count -eq 0) {
            New-NetIPAddress `
                -InterfaceIndex $interfaceIndex `
                -IPAddress $network.Address `
                -PrefixLength $network.PrefixLength `
                -DefaultGateway $network.Gateway `
                -ErrorAction Stop | Out-Null
        }
        $verify = @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -eq $network.Address -and $_.PrefixLength -eq $network.PrefixLength })
        if ($verify.Count -eq 0) {
            throw "IPv4 configuration could not be verified on $($adapter.Name)"
        }
        Write-Result 'PASS' 'ipv4' "$($network.Address)/$($network.PrefixLength) configured"
    }

    $route = @(Get-NetRoute -InterfaceIndex $interfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
        Where-Object { $_.NextHop -eq $network.Gateway })
    if ($route.Count -gt 0) {
        Write-Result 'PASS' 'gateway' $network.Gateway
    }
    elseif (-not $Apply) {
        Write-Result 'MISSING' 'gateway' "expected default gateway $($network.Gateway)"
    }
    else {
        New-NetRoute -InterfaceIndex $interfaceIndex -DestinationPrefix '0.0.0.0/0' -NextHop $network.Gateway -PolicyStore PersistentStore -ErrorAction Stop | Out-Null
        $route = @(Get-NetRoute -InterfaceIndex $interfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -eq $network.Gateway })
        if ($route.Count -eq 0) {
            throw "default gateway $($network.Gateway) could not be verified on $($adapter.Name)"
        }
        Write-Result 'PASS' 'gateway' "$($network.Gateway) configured"
    }

    $dns = @((Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses |
        ForEach-Object { [string]$_ })
    $bootstrap = @($network.BootstrapDns | ForEach-Object { [string]$_ })
    if (@($dns) -join ',' -eq ($bootstrap -join ',')) {
        Write-Result 'PASS' 'bootstrap-dns' ($bootstrap -join ', ')
    }
    elseif (-not $Apply) {
        Write-Result 'MISSING' 'bootstrap-dns' "expected $($bootstrap -join ', ')"
    }
    else {
        Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ServerAddresses $bootstrap -ErrorAction Stop
        $dns = @((Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses |
            ForEach-Object { [string]$_ })
        if (($dns -join ',') -ne ($bootstrap -join ',')) {
            throw "bootstrap DNS could not be verified on $($adapter.Name)"
        }
        Write-Result 'PASS' 'bootstrap-dns' ($bootstrap -join ', ')
    }
}

function Test-DomainController {
    $ntds = Get-Service -Name 'NTDS' -ErrorAction SilentlyContinue
    return ($null -ne $ntds)
}

function Get-LocalDomain {
    if (-not (Get-Command -Name 'Get-ADDomain' -ErrorAction SilentlyContinue)) { return $null }
    try {
        return Get-ADDomain -Identity $Config.Domain.Fqdn -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Invoke-AddsCheckpoint {
    if (-not (Test-RequiredCommand 'Get-WindowsFeature')) { return }
    $ad = Get-WindowsFeature -Name 'AD-Domain-Services'
    $dns = Get-WindowsFeature -Name 'DNS'
    if ($ad.Installed) { Write-Result 'PASS' 'feature:AD-Domain-Services' 'installed' }
    else { Write-Result 'MISSING' 'feature:AD-Domain-Services' 'not installed' }
    if ($dns.Installed) { Write-Result 'PASS' 'feature:DNS' 'installed' }
    else { Write-Result 'MISSING' 'feature:DNS' 'not installed' }

    if (Test-DomainController) {
        Write-Result 'PASS' 'domain-controller' 'NTDS service exists; promotion will not be repeated'
        return
    }
    if (-not $Apply -or ($ad.Installed -and $dns.Installed)) { return }

    $result = Install-WindowsFeature -Name 'AD-Domain-Services', 'DNS' -IncludeManagementTools
    if ($result.RestartNeeded -eq 'Yes') {
        Write-Result 'REBOOT_REQUIRED' 'adds-install' 'reboot VPS13, then run checkpoint 3 again before checkpoint 4'
    }
    else {
        Write-Result 'PASS' 'adds-install' 'AD DS and DNS installed'
    }
}

function Invoke-ForestCheckpoint {
    if (-not (Test-RequiredCommand 'Get-ADDomain')) {
        Skip-Checkpoint '4' 'ActiveDirectory module/domain unavailable'
        return
    }
    if (-not (Test-RequiredCommand 'Get-ADForest')) {
        Skip-Checkpoint '4' 'ActiveDirectory module/forest cmdlet unavailable'
        return
    }
    $domain = Get-LocalDomain
    if ($null -ne $domain) {
        if ($domain.DNSRoot.ToUpperInvariant() -ne $Config.Domain.Fqdn.ToUpperInvariant() -or
            $domain.NetBIOSName.ToUpperInvariant() -ne $Config.Domain.Netbios.ToUpperInvariant()) {
            throw "existing domain does not match $($Config.Domain.Fqdn)/$($Config.Domain.Netbios); refusing second promotion"
        }
        Write-Result 'PASS' 'forest-domain' "$($domain.DNSRoot) / $($domain.NetBIOSName) already exists"
        return
    }

    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($computer.PartOfDomain) {
        throw "machine is already joined to $($computer.Domain); refusing new forest promotion"
    }
    if (-not $Apply) {
        Write-Result 'MISSING' 'forest-domain' "new forest $($Config.Domain.Fqdn) is not present"
        return
    }

    $dsrm = Read-Host 'DSRM password (input is hidden)' -AsSecureString
    Install-ADDSForest `
        -DomainName $Config.Domain.Fqdn `
        -DomainNetbiosName $Config.Domain.Netbios `
        -InstallDns:$true `
        -SafeModeAdministratorPassword $dsrm `
        -NoRebootOnCompletion:$true `
        -Force:$true
    Write-Result 'REBOOT_REQUIRED' 'forest-domain' 'forest created; reboot VPS13 manually before DNS checkpoint'
}

function Invoke-DnsCheckpoint {
    if (-not (Test-RequiredCommand 'Get-DnsServerZone')) {
        Skip-Checkpoint '5' 'DNS Server module unavailable'
        return
    }
    if (-not (Test-RequiredCommand 'Get-DnsServerForwarder')) {
        Skip-Checkpoint '5' 'DNS Server forwarder cmdlet unavailable'
        return
    }
    $dnsService = Get-Service -Name 'DNS' -ErrorAction SilentlyContinue
    if ($null -eq $dnsService) {
        if ($Apply) { throw 'DNS Server service is not installed; run checkpoint 3 first' }
        Write-Result 'MISSING' 'dns-service' 'DNS Server service is not installed'
        return
    }
    if ($dnsService.Status -ne 'Running') {
        if ($Apply) {
            Set-Service -Name 'DNS' -StartupType Automatic
            Start-Service -Name 'DNS'
            Write-Result 'PASS' 'dns-service' 'DNS Server started'
        }
        else {
            Write-Result 'WARN' 'dns-service' 'DNS Server is installed but not running'
        }
    }
    else {
        Write-Result 'PASS' 'dns-service' 'running'
    }

    $zone = Get-DnsServerZone -Name $Config.Domain.DnsZone -ErrorAction SilentlyContinue
    if ($null -eq $zone) {
        if (-not $Apply) {
            Write-Result 'MISSING' 'dns-zone' $Config.Domain.DnsZone
        }
        else {
            Add-DnsServerPrimaryZone -Name $Config.Domain.DnsZone -ReplicationScope Forest | Out-Null
            Write-Result 'PASS' 'dns-zone' "$($Config.Domain.DnsZone) created as AD-integrated zone"
        }
    }
    else {
        Write-Result 'PASS' 'dns-zone' "$($Config.Domain.DnsZone) exists"
    }

    $msdcs = Get-DnsServerZone -Name ("_msdcs.{0}" -f $Config.Domain.DnsZone) -ErrorAction SilentlyContinue
    if ($null -ne $msdcs) { Write-Result 'PASS' 'dns-zone:_msdcs' 'exists' }
    else { Write-Result 'WARN' 'dns-zone:_msdcs' 'not found; verify AD-integrated forest DNS after reboot' }

    $forwarders = @($Config.Domain.Forwarders | ForEach-Object { [string]$_ })
    $currentForwarders = @((Get-DnsServerForwarder -ErrorAction SilentlyContinue).IPAddress | ForEach-Object { $_.IPAddressToString })
    if (($currentForwarders -join ',') -eq ($forwarders -join ',')) {
        Write-Result 'PASS' 'dns-forwarders' ($forwarders -join ', ')
    }
    elseif (-not $Apply) {
        Write-Result 'WARN' 'dns-forwarders' "expected $($forwarders -join ', '), got $($currentForwarders -join ', ')"
    }
    else {
        Set-DnsServerForwarder -IPAddress $forwarders -UseRootHint:$false
        Write-Result 'PASS' 'dns-forwarders' ($forwarders -join ', ')
    }

    $adapter = Resolve-Interface
    if ($null -ne $adapter) {
        $interfaceIndex = Get-InterfaceIndex -Adapter $adapter
        $postDns = @($Config.Network.PostPromotionDns | ForEach-Object { [string]$_ })
        $currentDns = @((Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses |
            ForEach-Object { [string]$_ })
        if (@($currentDns) -join ',' -eq ($postDns -join ',')) {
            Write-Result 'PASS' 'post-promotion-dns' ($postDns -join ', ')
        }
        elseif (-not $Apply) {
            Write-Result 'WARN' 'post-promotion-dns' "expected $($postDns -join ', '); apply after forest promotion"
        }
        else {
            Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ServerAddresses $postDns
            Write-Result 'PASS' 'post-promotion-dns' ($postDns -join ', ')
        }
    }
}

function Get-UserDeclaration {
    $declaration = Import-Declaration -Path $UsersPath -Label 'User/group'
    foreach ($key in @('GroupDefinitions', 'Users')) {
        if (-not $declaration.ContainsKey($key)) { throw "User declaration is missing: $key" }
    }
    $groupNames = @($declaration.GroupDefinitions | ForEach-Object { $_.Name })
    if ($groupNames.Count -ne (@($groupNames | Select-Object -Unique)).Count) {
        throw 'User declaration contains duplicate group names'
    }
    $userNames = @($declaration.Users | ForEach-Object { $_.SamAccountName })
    if ($userNames.Count -ne (@($userNames | Select-Object -Unique)).Count) {
        throw 'User declaration contains duplicate sAMAccountName values'
    }
    foreach ($user in $declaration.Users) {
        foreach ($group in $user.Groups) {
            if ($group -notin $groupNames) { throw "$($user.SamAccountName) references undeclared group $group" }
            if ($group -match '(?i)domain admins|enterprise admins|schema admins|administrators') {
                throw "$($user.SamAccountName) references a privileged built-in group: $group"
            }
        }
    }
    return $declaration
}

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
        return Get-ADUser -Identity $SamAccountName -Properties GivenName, Surname, Enabled, Description -ErrorAction Stop
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        return $null
    }
}

function Ensure-PowerSevenMemberships {
    param(
        [string]$SamAccountName,
        [string[]]$GroupNames,
        [switch]$NoPipeline
    )

    $membership = @(Get-ADPrincipalGroupMembership -Identity $SamAccountName -ErrorAction Stop |
        ForEach-Object { $_.SamAccountName })
    foreach ($groupName in $GroupNames) {
        if ($membership -contains $groupName) {
            if ($NoPipeline) { Write-Result 'PASS' "membership:$SamAccountName/$groupName" 'present' -NoPipeline }
            else { Write-Result 'PASS' "membership:$SamAccountName/$groupName" 'present' }
        }
        elseif (-not $Apply) {
            if ($NoPipeline) { Write-Result 'MISSING' "membership:$SamAccountName/$groupName" 'not present' -NoPipeline }
            else { Write-Result 'MISSING' "membership:$SamAccountName/$groupName" 'not present' }
        }
        else {
            Add-ADGroupMember -Identity $groupName -Members $SamAccountName -ErrorAction Stop
            if ($NoPipeline) { Write-Result 'PASS' "membership:$SamAccountName/$groupName" 'added' -NoPipeline }
            else { Write-Result 'PASS' "membership:$SamAccountName/$groupName" 'added' }
            $membership += $groupName
        }
    }
}

function Remove-PowerSevenSessionUser {
    param(
        [string]$SamAccountName,
        [ref]$CreatedThisRun
    )

    if (-not $CreatedThisRun.Value) { return }
    try {
        Remove-ADUser -Identity $SamAccountName -Confirm:$false -ErrorAction Stop
    }
    catch {
        Write-Result 'FAIL' "cleanup:$SamAccountName" $_.Exception.Message -NoPipeline
        throw
    }
    $CreatedThisRun.Value = $false
    Write-Result 'PASS' "cleanup:$SamAccountName" 'partial account removed' -NoPipeline
}

function Ensure-PowerSevenUser {
    param(
        [string]$FirstName,
        [string]$LastName,
        [string]$SamAccountName,
        [System.Security.SecureString]$SecurePassword,
        [string[]]$Groups,
        [string]$ContainerPath,
        [string]$Role = 'installer-created',
        [bool]$Enabled = $true,
        [ref]$CreatedThisRun
    )

    $forbiddenGroups = @('Domain Admins', 'Enterprise Admins', 'Schema Admins')
    $selectedGroups = @($Groups)
    if ($selectedGroups.Count -eq 0) {
        throw "at least one PowerSeven group is required for $SamAccountName"
    }
    foreach ($groupName in $selectedGroups) {
        if ($groupName -in $forbiddenGroups -or $groupName -notmatch '^PowerSeven-') {
            throw "unsupported or privileged AD group requested: $groupName"
        }
    }

    $user = Find-ADUserBySamAccountName -SamAccountName $SamAccountName
    if ($null -ne $user) {
        if (-not $CreatedThisRun.Value) {
            if (-not $user.Enabled) {
                Write-Result 'WARN' "user:$SamAccountName" 'exists and is disabled; password and enable state left unchanged' -NoPipeline
                return $user
            }
            Write-Result 'PASS' "user:$SamAccountName" 'exists; password not inspected or changed' -NoPipeline
            if ($Apply -and ($user.GivenName -ne $FirstName -or $user.Surname -ne $LastName)) {
                Set-ADUser -Identity $user `
                    -GivenName $FirstName `
                    -Surname $LastName `
                    -DisplayName ("{0} {1}" -f $FirstName, $LastName) `
                    -ErrorAction Stop
                Write-Result 'PASS' "user:$SamAccountName" 'name attributes reconciled' -NoPipeline
            }
            Ensure-PowerSevenMemberships -SamAccountName $SamAccountName -GroupNames $selectedGroups -NoPipeline
            return $user
        }
    }

    if ($CreatedThisRun.Value -and $null -eq $user) {
        $CreatedThisRun.Value = $false
        throw "session-created account disappeared before password completion: $SamAccountName"
    }

    try {
        if ($null -eq $user) {
            New-ADUser `
                -Name ("{0} {1}" -f $FirstName, $LastName) `
                -GivenName $FirstName `
                -Surname $LastName `
                -DisplayName ("{0} {1}" -f $FirstName, $LastName) `
                -SamAccountName $SamAccountName `
                -UserPrincipalName ("{0}@{1}" -f $SamAccountName, $Config.Domain.Fqdn.ToLowerInvariant()) `
                -Description ("PowerSeven role: {0}" -f $Role) `
                -Enabled:$false `
                -Path $ContainerPath `
                -ErrorAction Stop
            $CreatedThisRun.Value = $true
            $user = Get-ADUser -Identity $SamAccountName -Properties Enabled -ErrorAction Stop
        }

        if ($null -eq $SecurePassword) {
            throw "a SecureString password is required to create $SamAccountName"
        }
        Set-ADAccountPassword -Identity $user -Reset -NewPassword $SecurePassword -ErrorAction Stop
        Set-ADUser -Identity $user -ChangePasswordAtLogon $true -ErrorAction Stop
        Ensure-PowerSevenMemberships -SamAccountName $SamAccountName -GroupNames $selectedGroups -NoPipeline
        if ($Enabled) {
            Enable-ADAccount -Identity $user -ErrorAction Stop
        }
        $user = Get-ADUser -Identity $SamAccountName -Properties Enabled -ErrorAction Stop
        if ([bool]$user.Enabled -ne $Enabled) {
            throw "account $SamAccountName has unexpected Enabled state: $($user.Enabled)"
        }
        Write-Result 'PASS' "user:$SamAccountName" 'created and fully configured; password was not stored' -NoPipeline
        return $user
    }
    catch [Microsoft.ActiveDirectory.Management.ADPasswordComplexityException] {
        throw
    }
    catch {
        Remove-PowerSevenSessionUser -SamAccountName $SamAccountName -CreatedThisRun $CreatedThisRun
        throw
    }
}

function Read-PowerSevenYesNo {
    param([string]$Prompt)

    do {
        $answer = (Read-Host $Prompt).Trim().ToUpperInvariant()
    } until ($answer -in @('S', 'N', 'Y'))
    return ($answer -in @('S', 'Y'))
}

function ConvertTo-PowerSevenUsernamePart {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $builder = New-Object System.Text.StringBuilder
    $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormD)
    foreach ($character in $normalized.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -eq [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            continue
        }
        if ($character -match '[A-Za-z0-9]') {
            [void]$builder.Append($character.ToString().ToLowerInvariant())
        }
        elseif ($builder.Length -gt 0 -and $builder[$builder.Length - 1] -ne '.') {
            [void]$builder.Append('.')
        }
    }
    return $builder.ToString().Trim('.')
}

function New-PowerSevenUsername {
    param([string]$FirstName, [string]$LastName)

    $firstPart = ConvertTo-PowerSevenUsernamePart -Value $FirstName
    $lastPart = ConvertTo-PowerSevenUsernamePart -Value $LastName
    if ([string]::IsNullOrWhiteSpace($firstPart) -or [string]::IsNullOrWhiteSpace($lastPart)) {
        return $null
    }
    return "$firstPart.$lastPart"
}

function Read-PowerSevenUsername {
    param([string]$FirstName, [string]$LastName)

    $proposed = New-PowerSevenUsername -FirstName $FirstName -LastName $LastName
    $manual = $false
    while ($true) {
        if (-not $manual -and $null -ne $proposed) {
            Write-Host "Username proposto: $proposed"
            if (Read-PowerSevenYesNo 'Confermi? [S/N]') {
                $candidate = $proposed
            }
            else {
                $manual = $true
                continue
            }
        }
        else {
            $candidate = (Read-Host 'Username').Trim().ToLowerInvariant()
        }

        if ($candidate -notmatch '^[a-z0-9][a-z0-9._-]{0,19}$') {
            Write-Host 'Username non valido: usa 1-20 caratteri lowercase, numeri, punto, underscore o trattino.'
            $manual = $true
            continue
        }
        $existing = Find-ADUserBySamAccountName -SamAccountName $candidate
        if ($null -eq $existing) {
            return $candidate
        }
        if (-not $existing.Enabled) {
            Write-Host "L'utente $candidate esiste già ed è disabilitato."
        }
        else {
            Write-Host "L'utente $candidate esiste già."
        }
        if (-not (Read-PowerSevenYesNo 'Vuoi scegliere un altro username? [S/N]')) {
            return $null
        }
        $manual = $true
        $proposed = $null
    }
}

function Read-PowerSevenGroups {
    param([object]$Declaration)

    $groupNames = @($Declaration.GroupDefinitions | ForEach-Object { [string]$_.Name })
    while ($true) {
        Write-Host 'Gruppi disponibili:'
        for ($index = 0; $index -lt $groupNames.Count; $index++) {
            Write-Host ("{0}. {1}" -f ($index + 1), $groupNames[$index])
        }
        $raw = (Read-Host 'Gruppi [es. 1,3]').Trim()
        $tokens = @($raw -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $selected = @()
        $valid = $tokens.Count -gt 0
        foreach ($token in $tokens) {
            [int]$number = 0
            if (-not [int]::TryParse($token, [ref]$number) -or $number -lt 1 -or $number -gt $groupNames.Count) {
                $valid = $false
                break
            }
            $groupName = $groupNames[$number - 1]
            if ($selected -notcontains $groupName) {
                $selected += $groupName
            }
        }
        if ($valid -and $selected.Count -gt 0) {
            return $selected
        }
        Write-Host 'Selezione gruppi non valida; scegli uno o più numeri separati da virgole.'
    }
}

function Read-PowerSevenUserDefinition {
    param(
        [object]$Declaration
    )

    do { $firstName = (Read-Host 'Nome').Trim() } until (-not [string]::IsNullOrWhiteSpace($firstName))
    do { $lastName = (Read-Host 'Cognome').Trim() } until (-not [string]::IsNullOrWhiteSpace($lastName))
    $samAccountName = Read-PowerSevenUsername -FirstName $firstName -LastName $lastName
    if ($null -eq $samAccountName) {
        return $null
    }
    $groups = @(Read-PowerSevenGroups -Declaration $Declaration)
    return [pscustomobject]@{
        FirstName = $firstName
        LastName = $lastName
        SamAccountName = $samAccountName
        Groups = $groups
        Role = 'installer-created'
        Enabled = $true
    }
}

function Invoke-InteractivePowerSevenUsers {
    param(
        [object]$Declaration,
        [string]$ContainerPath
    )

    if (-not (Read-PowerSevenYesNo 'Vuoi creare un utente? [S/N]')) {
        Write-Result 'PASS' 'users' 'interactive user provisioning skipped by operator'
        return
    }

    while ($true) {
        $definition = Read-PowerSevenUserDefinition -Declaration $Declaration
        if ($null -eq $definition) {
            Write-Result 'PASS' 'users' 'current user creation cancelled by operator'
            continue
        }
        $cancelled = $false
        [bool]$createdThisRun = $false
        while ($true) {
            if (-not (Read-PowerSevenYesNo ("Procedere con la password per {0}? [S/N]" -f $definition.SamAccountName))) {
                Write-Result 'PASS' "user:$($definition.SamAccountName)" 'creation cancelled by operator'
                $cancelled = $true
                break
            }
            $password = Read-Host ("Password per {0} (input nascosto)" -f $definition.SamAccountName) -AsSecureString
            try {
                $null = Ensure-PowerSevenUser `
                    -FirstName $definition.FirstName `
                    -LastName $definition.LastName `
                    -SamAccountName $definition.SamAccountName `
                    -SecurePassword $password `
                    -Groups $definition.Groups `
                    -ContainerPath $ContainerPath `
                    -Role $definition.Role `
                    -Enabled $definition.Enabled `
                    -CreatedThisRun ([ref]$createdThisRun)
                Write-Host "Utente $($definition.SamAccountName) creato."
                break
            }
            catch [Microsoft.ActiveDirectory.Management.ADPasswordComplexityException] {
                Write-Output 'Password non conforme alla policy LAB.TEST. Usa maiuscole, minuscole, numeri e simboli e riprova.'
            }
        }

        if ($cancelled) {
            Remove-PowerSevenSessionUser -SamAccountName $definition.SamAccountName -CreatedThisRun ([ref]$createdThisRun)
            continue
        }

        if (-not (Read-PowerSevenYesNo 'Vuoi creare un altro utente? [S/N]')) {
            Write-Result 'PASS' 'users' 'interactive user provisioning completed'
            return
        }
    }
}

function Invoke-UsersCheckpoint {
    if (-not (Test-RequiredCommand 'Get-ADDomain')) {
        Skip-Checkpoint '6' 'ActiveDirectory module/domain unavailable'
        return
    }
    if (-not (Test-RequiredCommand 'Get-ADGroup')) {
        Skip-Checkpoint '6' 'ActiveDirectory module/Get-ADGroup unavailable'
        return
    }
    if (-not (Test-RequiredCommand 'Get-ADUser')) {
        Skip-Checkpoint '6' 'ActiveDirectory module/Get-ADUser unavailable'
        return
    }
    if (-not (Test-RequiredCommand 'Get-ADPrincipalGroupMembership')) {
        Skip-Checkpoint '6' 'ActiveDirectory membership cmdlet unavailable'
        return
    }
    if (-not (Test-RequiredCommand 'Get-ADObject')) {
        Skip-Checkpoint '6' 'ActiveDirectory object cmdlet unavailable'
        return
    }
    $domain = Get-LocalDomain
    if ($null -eq $domain) {
        Skip-Checkpoint '6' 'ActiveDirectory domain LAB.TEST unavailable'
        return
    }
    if ($domain.DNSRoot.ToUpperInvariant() -ne $Config.Domain.Fqdn.ToUpperInvariant() -or
        $domain.NetBIOSName.ToUpperInvariant() -ne $Config.Domain.Netbios.ToUpperInvariant()) {
        Skip-Checkpoint '6' "ActiveDirectory domain is not $($Config.Domain.Fqdn)/$($Config.Domain.Netbios)"
        return
    }
    $declaration = Get-UserDeclaration
    $usersContainerProperty = $domain.PSObject.Properties['UsersContainer']
    $containerPath = if ($null -ne $usersContainerProperty) { [string]$usersContainerProperty.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($containerPath)) {
        $domainDnProperty = $domain.PSObject.Properties['DistinguishedName']
        if ($null -ne $domainDnProperty -and -not [string]::IsNullOrWhiteSpace([string]$domainDnProperty.Value)) {
            $containerPath = "CN=Users,$($domainDnProperty.Value)"
        }
    }
    if ([string]::IsNullOrWhiteSpace($containerPath)) {
        throw 'ActiveDirectory domain did not expose a usable Users container'
    }
    $container = Get-ADObject -Identity $containerPath -ErrorAction Stop
    if ($null -eq $container) {
        throw "ActiveDirectory Users container does not exist: $containerPath"
    }
    Write-Result 'PASS' 'ad-container' $containerPath

    foreach ($group in $declaration.GroupDefinitions) {
        $existing = Find-ADGroupBySamAccountName -SamAccountName $group.Name
        if ($null -ne $existing) {
            Write-Result 'PASS' "group:$($group.Name)" 'exists'
        }
        elseif (-not $Apply) {
            Write-Result 'MISSING' "group:$($group.Name)" 'not present'
        }
        else {
            New-ADGroup `
                -Name $group.Name `
                -SamAccountName $group.Name `
                -GroupScope $group.Scope `
                -GroupCategory $group.Category `
                -Description $group.Description `
                -Path $containerPath `
                -ErrorAction Stop | Out-Null
            Write-Result 'PASS' "group:$($group.Name)" 'created'
        }
    }

    if ($Apply) {
        Invoke-InteractivePowerSevenUsers -Declaration $declaration -ContainerPath $containerPath
        return
    }

    foreach ($definition in $declaration.Users) {
        $user = Find-ADUserBySamAccountName -SamAccountName $definition.SamAccountName
        if ($null -eq $user) {
            Write-Result 'MISSING' "user:$($definition.SamAccountName)" 'not present'
            continue
        }
        Write-Result 'PASS' "user:$($definition.SamAccountName)" 'exists; password not inspected or changed'
        Ensure-PowerSevenMemberships -SamAccountName $definition.SamAccountName -GroupNames $definition.Groups
    }
}

function Invoke-RecordsCheckpoint {
    if (-not (Test-RequiredCommand 'Get-DnsServerResourceRecord')) {
        Skip-Checkpoint '7' 'DNS Server resource-record cmdlet unavailable'
        return
    }
    if (-not (Test-RequiredCommand 'Get-DnsServerZone')) {
        Skip-Checkpoint '7' 'DNS Server module unavailable'
        return
    }
    $zone = $Config.Domain.DnsZone
    if ($null -eq (Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue)) {
        if ($Apply) {
            throw ('DNS zone does not exist: {0}; run checkpoint 5 first' -f $zone)
        }
        Write-Result 'MISSING' 'dns-records' ('zone does not exist: {0}' -f $zone)
        return
    }

    foreach ($definition in $Config.DnsRecords) {
        $existing = @(Get-DnsServerResourceRecord -ZoneName $zone -Name $definition.Name -RRType 'A' -ErrorAction SilentlyContinue)
        $addresses = @($existing | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
        if ($addresses -contains $definition.Address) {
            Write-Result 'PASS' "dns-record:$($definition.Name)" "$($definition.Address)"
            continue
        }
        if (-not $Apply) {
            if ($existing.Count -gt 0) {
                Write-Result 'WARN' "dns-record:$($definition.Name)" "wrong address; expected $($definition.Address), got $($addresses -join ', ')"
            }
            else {
                Write-Result 'MISSING' "dns-record:$($definition.Name)" $definition.Address
            }
            continue
        }
        foreach ($record in $existing) {
            Remove-DnsServerResourceRecord -ZoneName $zone -InputObject $record -Force
        }
        Add-DnsServerResourceRecordA -ZoneName $zone -Name $definition.Name -IPv4Address $definition.Address -TimeToLive ([TimeSpan]::FromHours(1))
        Write-Result 'PASS' "dns-record:$($definition.Name)" "$($definition.Address) reconciled"
    }
}

function Invoke-ValidationCheckpoint {
    Write-Result 'PASS' 'validator' 'checkpoint 8 is read-only; use validate-vps13.ps1 for the standalone validator'
    Test-BaseWindows
    Invoke-NetworkCheckpoint

    $adDomainAvailable = Test-RequiredCommand 'Get-ADDomain'
    if (-not $adDomainAvailable) {
        Skip-Checkpoint '8' 'ActiveDirectory module/domain unavailable'
    }
    else {
        $domain = Get-LocalDomain
        if ($null -eq $domain) {
            Skip-Checkpoint '8' 'ActiveDirectory domain LAB.TEST unavailable'
        }
        elseif ($domain.DNSRoot.ToUpperInvariant() -eq $Config.Domain.Fqdn.ToUpperInvariant()) {
            Write-Result 'PASS' 'domain' $domain.DNSRoot
        }
        else {
            Write-Result 'FAIL' 'domain' "expected $($Config.Domain.Fqdn)"
        }
    }

    Invoke-DnsCheckpoint
    Invoke-RecordsCheckpoint
}

function Invoke-Checkpoint {
    param([string]$Number)

    if ($Number -eq '8' -and $Apply) {
        throw 'Checkpoint 8 is read-only; run bootstrap.ps1 -Check or validate-vps13.ps1'
    }
    $mode = if ($ReadOnly) { 'CHECK' } else { 'APPLY' }
    Write-Output ("--- CHECKPOINT {0} ({1}) ---" -f $Number, $mode)
    switch ($Number) {
        '1' { Test-BaseWindows }
        '2' { Invoke-NetworkCheckpoint }
        '3' { Invoke-AddsCheckpoint }
        '4' { Invoke-ForestCheckpoint }
        '5' { Invoke-DnsCheckpoint }
        '6' { Invoke-UsersCheckpoint }
        '7' { Invoke-RecordsCheckpoint }
        '8' { Invoke-ValidationCheckpoint }
    }
}

try {
    if ($Check -and $Apply) { throw 'Choose either -Check or -Apply, not both' }
    if ($Apply -and $Checkpoint -eq 'All') {
        throw 'Apply requires one checkpoint (1-8); automatic all-in-one provisioning is disabled'
    }
    if (-not $Check -and -not $Apply) { $script:ReadOnly = $true }
    if ($Apply) { $script:ReadOnly = $false }
    if ($env:OS -ne 'Windows_NT') {
        throw 'This workflow must run on VPS13 Windows; Linux can only perform static inspection'
    }

    $Config = Import-Declaration -Path $ConfigPath -Label 'VPS13 provisioning'
    $null = Import-Declaration -Path $UsersPath -Label 'User/group'
    Test-Declaration
    Test-SecretManifest

    if ($Checkpoint -eq 'All') {
        foreach ($number in @('1', '2', '3', '4', '5', '6', '7', '8')) {
            Invoke-Checkpoint -Number $number
            if ($script:RebootRequired) {
                Write-Output 'STOP: reboot required before the next checkpoint'
                break
            }
        }
    }
    else {
        Invoke-Checkpoint -Number $Checkpoint
    }
}
catch {
    $line = if ($null -ne $_.InvocationInfo) { $_.InvocationInfo.ScriptLineNumber } else { '?' }
    Write-Result 'FAIL' 'workflow' ("{0}: {1} (line {2})" -f $_.Exception.GetType().Name, $_.Exception.Message, $line)
}

if ($script:Failure) {
    exit 2
}
if ($script:RebootRequired) {
    exit 10
}
if ($script:Missing) {
    exit 1
}
exit 0
