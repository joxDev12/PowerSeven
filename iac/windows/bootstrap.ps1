[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InterfaceAlias = '<UNDERLAY_INTERFACE>'
$Address = '192.168.214.13'
$PrefixLength = 24
$Gateway = '192.168.214.2'
$BootstrapDns = '192.168.214.2'
$Hostname = 'DC02'

Write-Output "PowerSeven Windows bootstrap plan: $Hostname / $Address"
Write-Output 'No domain promotion is performed by this template.'

if (-not $Apply) {
    Write-Output 'Dry-run only. Re-run with -Apply only after explicit review.'
    exit 0
}

if ($PSCmdlet.ShouldProcess($Hostname, 'apply static underlay and bootstrap roles')) {
    Rename-Computer -NewName $Hostname -Force
    New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $Address -PrefixLength $PrefixLength -DefaultGateway $Gateway
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $BootstrapDns
    Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
    Enable-PSRemoting -SkipNetworkProfileCheck -Force
    Write-Output 'Bootstrap complete. AD DS promotion remains a separate reviewed step.'
}
