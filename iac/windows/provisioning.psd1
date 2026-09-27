@{
    SchemaVersion = 1
    Hostname = 'DC02'
    InterfaceAlias = ''
    Network = @{
        Address = '192.168.214.13'
        PrefixLength = 24
        Gateway = '192.168.214.2'
        BootstrapDns = @('1.1.1.1', '8.8.8.8')
        PostPromotionDns = @('192.168.214.13')
    }
    Domain = @{
        Fqdn = 'LAB.TEST'
        Netbios = 'LAB'
        DnsZone = 'lab.test'
        Forwarders = @('1.1.1.1', '8.8.8.8')
    }
    DnsRecords = @(
        @{ Name = 'dc02'; Address = '192.168.214.13' }
        @{ Name = 'cloud'; Address = '10.10.10.14' }
        @{ Name = 'git'; Address = '10.10.10.14' }
        @{ Name = 'login'; Address = '10.10.10.14' }
        @{ Name = 'panel'; Address = '10.10.10.14' }
        @{ Name = 'pdf'; Address = '10.10.10.14' }
        @{ Name = 'scribble'; Address = '10.10.10.14' }
        @{ Name = 'scribble-2'; Address = '10.10.10.14' }
        @{ Name = 'wazuh'; Address = '10.10.10.14' }
        @{ Name = 'wings'; Address = '10.10.10.14' }
        @{ Name = 'adguard'; Address = '10.10.10.14' }
    )
}
