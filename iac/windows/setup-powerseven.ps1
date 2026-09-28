[CmdletBinding()]
param(
    [string]$Vps14Address,
    [string]$UbuntuUsername,
    [ValidateSet('1', '2', '3', '4', '5', '6', '7', '8', '9')]
    [string]$Checkpoint = '1',
    [switch]$Check,
    [switch]$Apply,
    [switch]$PrepareBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requiredBootstrapVersion = '5'
$requiredBootstrapCapabilities = 'checkpoints=1,2,3'

function Write-Result {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL', 'SKIP', 'INFO', 'MISSING')]
        [string]$Status,
        [string]$Label,
        [string]$Message
    )

    Write-Host ("{0}: {1}: {2}" -f $Status, $Label, $Message)
}

function Get-NativeCommand {
    param([string]$Name)

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command is unavailable: $Name"
    }
    return $command.Source
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw ('Command failed with exit code {0}: {1}' -f $LASTEXITCODE, $FilePath)
    }
}

function Invoke-NativeInteractive {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    # Keep the console attached: SSH password and sudo prompts must be visible.
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw ('Interactive command failed with exit code {0}: {1}' -f $LASTEXITCODE, $FilePath)
    }
}

function Assert-LinuxPayloadLf {
    param(
        [string]$Name,
        [AllowEmptyString()][AllowNull()][string]$Content
    )

    if ($null -ne $Content -and $Content.Contains("`r")) {
        throw "Linux payload contains CR characters: $Name"
    }
}

function ConvertTo-LinuxLf {
    param(
        [string]$Name,
        [AllowEmptyString()][AllowNull()][string]$Content
    )

    if ($null -eq $Content) { return $null }
    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", '')
    Assert-LinuxPayloadLf -Name $Name -Content $normalized
    return $normalized
}

function ConvertTo-WindowsProcessArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '""' }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"{0}"' -f $escaped
}

function Invoke-SshKeygenProcess {
    param([string[]]$ArgumentList)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:SshKeygen
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (($ArgumentList | ForEach-Object {
        ConvertTo-WindowsProcessArgument -Value $_
    }) -join ' ')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'ssh-keygen process could not start'
        }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return @{
            ExitCode = $process.ExitCode
            StandardOutput = $stdout
            StandardError = $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-DerivedSshPublicKey {
    param([string]$KeyPath)

    $result = Invoke-SshKeygenProcess @('-y', '-f', $KeyPath)
    if ($result.ExitCode -ne 0) {
        return $null
    }
    $derived = ([string]$result.StandardOutput).Trim()
    $derivedParts = $derived -split '\s+'
    if ($derivedParts.Count -lt 2 -or
        $derivedParts[0] -ne 'ssh-ed25519' -or
        $derivedParts[1] -notmatch '^[A-Za-z0-9+/]+={0,2}$') {
        return $null
    }
    return '{0} {1}' -f $derivedParts[0], $derivedParts[1]
}

function Ensure-SshKeyPair {
    param(
        [string]$KeyPath,
        [string]$PublicKeyPath
    )

    $hasPrivate = Test-Path -LiteralPath $KeyPath -PathType Leaf
    $hasPublic = Test-Path -LiteralPath $PublicKeyPath -PathType Leaf
    $reused = $false

    if ($hasPrivate) {
        $derivedPublic = Get-DerivedSshPublicKey -KeyPath $KeyPath
        if ($null -eq $derivedPublic) {
            Remove-Item -LiteralPath $KeyPath, $PublicKeyPath -Force -ErrorAction SilentlyContinue
            $hasPrivate = $false
            $hasPublic = $false
            Write-Result 'WARN' 'ssh-key' 'incomplete or invalid private key material removed'
        } elseif (-not $hasPublic) {
            [System.IO.File]::WriteAllText($PublicKeyPath, "$derivedPublic`n", [System.Text.Encoding]::ASCII)
            $hasPublic = $true
            Write-Result 'PASS' 'ssh-key' 'public key reconstructed from the existing private key'
        } else {
            $storedPublic = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim() -split '\s+'
            $derivedParts = $derivedPublic -split '\s+'
            if ($storedPublic.Count -lt 2 -or
                $storedPublic[0] -ne $derivedParts[0] -or
                $storedPublic[1] -ne $derivedParts[1]) {
                Remove-Item -LiteralPath $KeyPath, $PublicKeyPath -Force
                $hasPrivate = $false
                $hasPublic = $false
                Write-Result 'WARN' 'ssh-key' 'private/public key mismatch removed; pair will be regenerated'
            } else {
                $reused = $true
            }
        }
    } elseif ($hasPublic) {
        Remove-Item -LiteralPath $PublicKeyPath -Force
        $hasPublic = $false
        Write-Result 'WARN' 'ssh-key' 'orphan public key removed; pair will be regenerated'
    }

    if (-not $hasPrivate) {
        Write-Result 'INFO' 'ssh-key' 'generating PowerSeven ED25519 key without passphrase'
        $result = Invoke-SshKeygenProcess @(
            '-q',
            '-t', 'ed25519',
            '-f', $KeyPath,
            '-N', '',
            '-C', 'PowerSeven VPS14 bootstrap'
        )
        if ($result.ExitCode -ne 0) {
            $detail = ([string]$result.StandardError).Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'no diagnostic output' }
            throw ('ssh-keygen failed with exit code {0}: {1}' -f $result.ExitCode, $detail)
        }
    }

    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
        throw 'ssh-keygen did not create a complete private/public key pair'
    }
    if ($reused) {
        Write-Result 'PASS' 'ssh-key' 'existing valid PowerSeven key reused'
    } else {
        Write-Result 'PASS' 'ssh-key' 'PowerSeven SSH private and public key are complete'
    }
}

function Test-SshKeyPair {
    param(
        [string]$KeyPath,
        [string]$PublicKeyPath
    )

    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
        return $false
    }
    $derivedPublic = Get-DerivedSshPublicKey -KeyPath $KeyPath
    if ($null -eq $derivedPublic) { return $false }
    $storedPublic = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim() -split '\s+'
    $derivedParts = $derivedPublic -split '\s+'
    return ($storedPublic.Count -ge 2 -and
        $storedPublic[0] -eq $derivedParts[0] -and
        $storedPublic[1] -eq $derivedParts[1])
}

function Test-NativeSuccess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (($ArgumentList | ForEach-Object {
        ConvertTo-WindowsProcessArgument -Value $_
    }) -join ' ')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            return $false
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $null = $stdoutTask.Result
        $null = $stderrTask.Result
        return ($process.ExitCode -eq 0)
    }
    catch {
        return $false
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (($ArgumentList | ForEach-Object {
        ConvertTo-WindowsProcessArgument -Value $_
    }) -join ' ')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start native command: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = [string]$stdoutTask.Result
            StandardError = [string]$stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-NativeReadOnly {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (($ArgumentList | ForEach-Object {
        ConvertTo-WindowsProcessArgument -Value $_
    }) -join ' ')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Could not start read-only command: $FilePath" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $hasRemediation = $false
        foreach ($line in ([string]$stdout -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host $line
                if ($line -match '^\s*(MISSING|SKIP):') { $hasRemediation = $true }
            }
        }
        foreach ($line in ([string]$stderr -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Host $line }
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            HasRemediation = $hasRemediation
        }
    }
    finally {
        $process.Dispose()
    }
}

function Set-RestrictedAcl {
    param(
        [string]$Path,
        [bool]$Directory
    )

    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $currentRule = if ($Directory) {
        '{0}:(OI)(CI)(F)' -f $currentIdentity
    } else {
        '{0}:(R)' -f $currentIdentity
    }
    $systemRule = if ($Directory) { '*S-1-5-18:(OI)(CI)(F)' } else { '*S-1-5-18:(F)' }
    $administratorsRule = if ($Directory) { '*S-1-5-32-544:(OI)(CI)(F)' } else { '*S-1-5-32-544:(F)' }

    Invoke-Native $script:Icacls @(
        $Path,
        '/inheritance:r',
        '/grant:r',
        $currentRule,
        $systemRule,
        $administratorsRule
    )
}

function Test-SshKeyAuthentication {
    param(
        [string]$SshPath,
        [string]$KeyPath,
        [string]$Target
    )

    return Test-NativeSuccess $SshPath @(
        '-o', 'BatchMode=yes',
        '-o', 'PasswordAuthentication=no',
        '-o', 'IdentitiesOnly=yes',
        '-i', $KeyPath,
        $Target,
        'true'
    )
}

function Test-BootstrapProtocol {
    param(
        [string]$SshPath,
        [string]$KeyPath,
        [string]$Target,
        [string]$RequiredVersion,
        [string]$RequiredCapabilities,
        [ValidateSet('1', '2', '3', '4', '5', '6', '7', '8', '9')]
        [string]$RequiredCheckpoint
    )

    $sshOptions = @(
        '-o', 'BatchMode=yes',
        '-o', 'PasswordAuthentication=no',
        '-o', 'IdentitiesOnly=yes',
        '-i', $KeyPath
    )

    if (-not (Test-NativeSuccess $SshPath ($sshOptions + @($Target, 'test', '-x', '/usr/local/sbin/powerseven-bootstrap')))) {
        return $false
    }
    if (-not (Test-NativeSuccess $SshPath ($sshOptions + @($Target, 'test', '-f', '/usr/local/lib/powerseven/bootstrap.sh')))) {
        return $false
    }

    $versionResult = Invoke-NativeCapture $SshPath ($sshOptions + @($Target, 'sudo', '-n', '/usr/local/sbin/powerseven-bootstrap', '--version'))
    if ($versionResult.ExitCode -ne 0 -or ([string]$versionResult.StandardOutput).Trim() -cne ('powerseven-bootstrap {0}' -f $RequiredVersion)) {
        return $false
    }

    $capabilitiesResult = Invoke-NativeCapture $SshPath ($sshOptions + @($Target, 'sudo', '-n', '/usr/local/sbin/powerseven-bootstrap', '--capabilities'))
    $capabilities = ([string]$capabilitiesResult.StandardOutput).Trim()
    if ($capabilitiesResult.ExitCode -ne 0 -or $capabilities -cne $RequiredCapabilities) {
        return $false
    }

    $capabilityMatch = [regex]::Match($capabilities, '^checkpoints=(?<values>[1-9][0-9]*(?:,[1-9][0-9]*)*)$')
    if (-not $capabilityMatch.Success -or
        (($capabilityMatch.Groups['values'].Value -split ',') -notcontains $RequiredCheckpoint)) {
        return $false
    }
    return $true
}

function Test-ExistingBootstrapInstallation {
    param(
        [string]$SshPath,
        [string]$KeyPath,
        [string]$Target,
        [string]$RequiredVersion,
        [string]$RequiredCapabilities,
        [ValidateSet('1', '2', '3', '4', '5', '6', '7', '8', '9')]
        [string]$RequiredCheckpoint
    )

    $protocolSupported = Test-BootstrapProtocol -SshPath $SshPath -KeyPath $KeyPath -Target $Target -RequiredVersion $RequiredVersion -RequiredCapabilities $RequiredCapabilities -RequiredCheckpoint $RequiredCheckpoint
    if (-not $protocolSupported) {
        return [pscustomobject]@{ Ready = $false; ProtocolSupported = $false }
    }
    return [pscustomobject]@{ Ready = $true; ProtocolSupported = $true }
}

function New-RemoteCheckpointArguments {
    param(
        [ValidateSet('--check', '--apply')]
        [string]$Action,
        [ValidateSet('1', '2', '3', '4', '5', '6', '7', '8', '9')]
        [string]$Checkpoint,
        [ValidateSet('', '--network-token', '--confirm-network', '--cleanup-client')]
        [string]$ExtraOption = '',
        [string]$ExtraValue = ''
    )

    # Keep every remote command token as a separate ssh.exe argument.
    $arguments = @(
        'sudo',
        '-n',
        '/usr/local/sbin/powerseven-bootstrap',
        $Action,
        '--checkpoint',
        [string]$Checkpoint
    )
    if ($ExtraOption -eq '--cleanup-client') {
        $arguments += $ExtraOption
    } elseif (-not [string]::IsNullOrWhiteSpace($ExtraOption)) {
        if ([string]::IsNullOrWhiteSpace($ExtraValue) -or $ExtraValue -notmatch '^[a-f0-9]{32}$') {
            throw 'Remote transaction token must be a 32-character hexadecimal value'
        }
        $arguments += @($ExtraOption, $ExtraValue)
    }
    return $arguments
}

function New-RemoteBootstrapFiles {
    param(
        [string]$Username,
        [string]$BootstrapSource
    )

    $wrapper = @'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 1 && ( "$1" == '--version' || "$1" == '--capabilities' ) ]]; then
    exec /usr/local/lib/powerseven/bootstrap.sh "$@"
fi

if [[ "$#" -ne 3 && "$#" -ne 4 && "$#" -ne 5 ]]; then
    echo 'usage: powerseven-bootstrap --check|--apply --checkpoint N' >&2
    exit 2
fi

case "$1" in
    --check|--apply) ;;
    *) echo 'invalid action' >&2; exit 2 ;;
esac

if [[ "$2" != '--checkpoint' || ! "$3" =~ ^[1-9][0-9]*$ ]]; then
    echo 'invalid checkpoint arguments' >&2
    exit 2
fi

case "$3" in
    1|2|3|4|5|6|7|8|9) ;;
    *) echo 'checkpoint is not allowlisted' >&2; exit 2 ;;
esac

if [[ "$#" -eq 4 ]]; then
    if [[ "$3" != '3' || "$4" != '--cleanup-client' || "$1" != '--apply' ]]; then
        echo 'invalid extended checkpoint arguments' >&2
        exit 2
    fi
fi
if [[ "$#" -eq 5 ]]; then
    if [[ "$1" != '--apply' || "$3" != '2' ]]; then
        echo 'invalid extended checkpoint arguments' >&2
        exit 2
    fi
    if [[ "$4" != '--network-token' && "$4" != '--confirm-network' ]]; then
        echo 'invalid extended checkpoint arguments' >&2
        exit 2
    fi
    if [[ ! "$5" =~ ^[a-f0-9]{32}$ ]]; then
        echo 'invalid transaction token' >&2
        exit 2
    fi
fi

exec /usr/local/lib/powerseven/bootstrap.sh "$@"
'@

    $sudoers = "{0} ALL=(root) NOPASSWD: /usr/local/sbin/powerseven-bootstrap`n" -f $Username
    $wrapper = ConvertTo-LinuxLf -Name 'bootstrap wrapper' -Content $wrapper
    $sudoers = ConvertTo-LinuxLf -Name 'bootstrap sudoers' -Content $sudoers
    $bootstrapContent = ConvertTo-LinuxLf -Name 'bootstrap script' -Content ([System.IO.File]::ReadAllText($BootstrapSource))
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('powerseven-bootstrap-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $wrapperPath = Join-Path $tempRoot 'powerseven-bootstrap-wrapper'
    $sudoersPath = Join-Path $tempRoot 'powerseven-bootstrap.sudoers'
    $bootstrapCopyPath = Join-Path $tempRoot 'bootstrap.sh'
    [System.IO.File]::WriteAllText($wrapperPath, $wrapper, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($sudoersPath, $sudoers, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($bootstrapCopyPath, $bootstrapContent, [System.Text.UTF8Encoding]::new($false))

    return @($tempRoot, $wrapperPath, $sudoersPath, $bootstrapCopyPath)
}

function Assert-LocalAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Checkpoint 3 requires an elevated PowerShell session on DC02'
    }
}

function Get-DC02UnderlayInterface {
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -match '^192\.168\.214\.[0-9]+$' -and $_.PrefixLength -eq 24 })
    if ($addresses.Count -ne 1) {
        throw 'Expected exactly one DC02 interface on 192.168.214.0/24'
    }
    return $addresses[0]
}

function Ensure-DC02AdminRoute {
    param([string]$Gateway = '192.168.214.14')

    $destination = '10.99.0.0/24'
    $underlay = Get-DC02UnderlayInterface
    $routes = @(Get-NetRoute -DestinationPrefix $destination -ErrorAction SilentlyContinue)
    $matching = @($routes | Where-Object { $_.NextHop -eq $Gateway -and $_.InterfaceIndex -eq $underlay.InterfaceIndex })
    $conflicts = @($routes | Where-Object { $_.NextHop -ne $Gateway -or $_.InterfaceIndex -ne $underlay.InterfaceIndex })
    if ($conflicts.Count -gt 0) {
        throw "Conflicting DC02 route already exists for $destination"
    }
    if ($matching.Count -gt 1) {
        throw "Duplicate DC02 routes already exist for $destination"
    }
    if ($matching.Count -gt 0) {
        Write-Result 'PASS' 'dc02-route' "$destination via $Gateway already present"
        return @{ Added = $false; Destination = $destination; NextHop = $Gateway; InterfaceIndex = $underlay.InterfaceIndex }
    }
    New-NetRoute -DestinationPrefix $destination -NextHop $Gateway -InterfaceIndex $underlay.InterfaceIndex -RouteMetric 50 -PolicyStore PersistentStore -ErrorAction Stop | Out-Null
    $verified = @(Get-NetRoute -DestinationPrefix $destination -ErrorAction Stop |
        Where-Object { $_.NextHop -eq $Gateway -and $_.InterfaceIndex -eq $underlay.InterfaceIndex })
    if ($verified.Count -ne 1) { throw "Could not validate persistent DC02 route for $destination" }
    Write-Result 'PASS' 'dc02-route' "$destination via $Gateway created persistently"
    return @{ Added = $true; Destination = $destination; NextHop = $Gateway; InterfaceIndex = $underlay.InterfaceIndex }
}

function Remove-DC02AdminRoute {
    param([hashtable]$RouteState)
    if ($null -eq $RouteState -or -not $RouteState.Added) { return }
    Remove-NetRoute -DestinationPrefix $RouteState.Destination -NextHop $RouteState.NextHop -InterfaceIndex $RouteState.InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
    Write-Result 'WARN' 'dc02-route' 'new administrative VPN route removed during rollback'
}

function Get-EnabledRdpFirewallRules {
    $rules = @(Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction Stop)
    $matchedRules = @()
    foreach ($rule in $rules) {
        $portFilters = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue)
        foreach ($filter in $portFilters) {
            $localPort = @($filter.LocalPort | ForEach-Object { [string]$_ })
            if ($filter.Protocol -eq 'TCP' -and $localPort -contains '3389') {
                $matchedRules += $rule
                break
            }
        }
    }
    return $matchedRules
}

function Ensure-DC02RdpFirewall {
    $rules = @(Get-EnabledRdpFirewallRules)
    if ($rules.Count -eq 0) {
        throw 'No explicit enabled inbound TCP/3389 rule was found; refusing to create a parallel rule that could leave a broader RDP rule active'
    }
    $state = @()
    try {
        foreach ($rule in $rules) {
            $addressFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
            $state += [pscustomobject]@{
                Name = $rule.Name
                RemoteAddress = @($addressFilter.RemoteAddress)
            }
            $addressFilter | Set-NetFirewallAddressFilter -RemoteAddress '10.99.0.0/24' -ErrorAction Stop
        }
    }
    catch {
        foreach ($entry in @($state)) {
            $previousRule = Get-NetFirewallRule -Name $entry.Name -ErrorAction SilentlyContinue
            if ($null -ne $previousRule) {
                Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $previousRule -ErrorAction SilentlyContinue |
                    Set-NetFirewallAddressFilter -RemoteAddress $entry.RemoteAddress -ErrorAction SilentlyContinue
            }
        }
        throw
    }
    Write-Result 'PASS' 'dc02-rdp-firewall' "RDP rules limited to 10.99.0.0/24 ($($rules.Count) rule(s))"
    return @{ Created = $false; Rules = $state }
}

function Restore-DC02RdpFirewall {
    param([hashtable]$FirewallState)
    if ($null -eq $FirewallState) { return }
    if ($FirewallState.Created) {
        Remove-NetFirewallRule -Name 'PowerSeven-AdminVPN-RDP' -ErrorAction SilentlyContinue
        Write-Result 'WARN' 'dc02-rdp-firewall' 'new RDP rule removed during rollback'
        return
    }
    foreach ($entry in @($FirewallState.Rules)) {
        $previousRule = Get-NetFirewallRule -Name $entry.Name -ErrorAction SilentlyContinue
        if ($null -ne $previousRule) {
            Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $previousRule -ErrorAction SilentlyContinue |
                Set-NetFirewallAddressFilter -RemoteAddress $entry.RemoteAddress -ErrorAction SilentlyContinue
        }
    }
    Write-Result 'WARN' 'dc02-rdp-firewall' 'previous RDP remote-address filters restored during rollback'
}

function Test-AdminClientConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $content = Get-Content -LiteralPath $Path -Raw
    return ($content -match '(?m)^\[Interface\]$' -and
        $content -match '(?m)^Address = 10\.99\.0\.2/32$' -and
        $content -match '(?m)^\[Peer\]$' -and
        $content -match '(?m)^AllowedIPs = 192\.168\.214\.0/24,10\.10\.10\.0/24$' -and
        $content -match '(?m)^PrivateKey = \S+$')
}

function New-LocalRdpFile {
    param([string]$Directory)
    $path = Join-Path $Directory 'PowerSeven-DC02.rdp'
    [System.IO.File]::WriteAllText($path, "full address:s:192.168.214.13`r`nusername:s:LAB\Administrator`r`n", [System.Text.Encoding]::ASCII)
    Set-RestrictedAcl -Path $path -Directory $false
    return $path
}

$selectedModes = 0
if ($Check) { $selectedModes++ }
if ($Apply) { $selectedModes++ }
if ($PrepareBootstrap) { $selectedModes++ }
if ($selectedModes -ne 1) {
    throw 'Choose exactly one mode: -Check, -Apply or -PrepareBootstrap'
}

$bootstrapSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'linux\bootstrap.sh'
if (-not (Test-Path -LiteralPath $bootstrapSource -PathType Leaf)) {
    throw "Linux bootstrap source is missing: $bootstrapSource"
}

if ([string]::IsNullOrWhiteSpace($Vps14Address)) {
    throw 'Vps14Address is required in -Check, -PrepareBootstrap or -Apply mode'
}
$parsedAddress = $null
if (-not [System.Net.IPAddress]::TryParse($Vps14Address, [ref]$parsedAddress) -or
    $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "Vps14Address must be a valid IPv4 address: $Vps14Address"
}
if ([string]::IsNullOrWhiteSpace($UbuntuUsername)) {
    $UbuntuUsername = Read-Host 'Ubuntu username'
}
if ($UbuntuUsername -notmatch '^[a-z_][a-z0-9_-]*$') {
    throw 'UbuntuUsername contains unsupported characters'
}

$script:Ssh = Get-NativeCommand 'ssh.exe'
$script:SshKeygen = Get-NativeCommand 'ssh-keygen.exe'
if (-not $Check) {
    $script:Scp = Get-NativeCommand 'scp.exe'
    $script:Icacls = Get-NativeCommand 'icacls.exe'
}

if ($Check) {
    Write-Result 'PASS' 'runner' 'local SSH and key-validation prerequisites are available'
} else {
    Write-Result 'PASS' 'runner' 'local SSH, key-generation, copy and ACL prerequisites are available'
}
Write-Result 'PASS' 'bootstrap-source' $bootstrapSource

$keyDirectory = Join-Path $env:ProgramData 'PowerSeven\ssh'
$keyPath = Join-Path $keyDirectory 'powerseven-vps14_ed25519'
$publicKeyPath = '{0}.pub' -f $keyPath
$target = '{0}@{1}' -f $UbuntuUsername, $Vps14Address

if ($Check) {
    if (-not (Test-SshKeyPair -KeyPath $keyPath -PublicKeyPath $publicKeyPath)) {
        Write-Result 'FAIL' 'ssh-key' 'existing PowerSeven SSH key pair is missing or invalid; -Check will not create or repair it'
        exit 1
    }
    Write-Result 'PASS' 'ssh-key' 'existing valid PowerSeven key reused'
} else {
    New-Item -ItemType Directory -Path $keyDirectory -Force | Out-Null
    Set-RestrictedAcl -Path $keyDirectory -Directory $true
    Ensure-SshKeyPair -KeyPath $keyPath -PublicKeyPath $publicKeyPath
    Set-RestrictedAcl -Path $keyPath -Directory $false
    Set-RestrictedAcl -Path $publicKeyPath -Directory $false
}

$publicKey = (Get-Content -LiteralPath $publicKeyPath -Raw).Trim()
if ($publicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( .*)?$' -or $publicKey.Contains("'")) {
    throw 'Generated public key has an unexpected format'
}

if ($Checkpoint -in @('2', '3') -and $Vps14Address -ne '192.168.214.14') {
    $staticTarget = '{0}@192.168.214.14' -f $UbuntuUsername
    if (Test-SshKeyAuthentication -SshPath $script:Ssh -KeyPath $keyPath -Target $staticTarget) {
        Write-Result 'PASS' 'vps14-address' 'existing static VPS14 address 192.168.214.14 selected'
        $Vps14Address = '192.168.214.14'
        $target = $staticTarget
    }
}

Write-Result 'INFO' 'ssh-key-auth' 'probing existing key-only authentication; no password prompt expected'
if (-not (Test-SshKeyAuthentication -SshPath $script:Ssh -KeyPath $keyPath -Target $target)) {
    if ($Check -or $PrepareBootstrap) {
        Write-Result 'FAIL' 'ssh-key-auth' 'key-only authentication failed; read-only/prepare mode will not enroll a key'
        exit 1
    }
    Write-Result 'INFO' 'ssh-enrollment' 'interactive password authentication required'
    $enrollmentToken = [guid]::NewGuid().ToString('N')
    $enrollmentBackupName = '.powerseven-authorized_keys.backup.' + $enrollmentToken
    $enrollmentMarkerName = '.powerseven-authorized_keys.added.' + $enrollmentToken
    $enrollCommand = @'
set -eu
auth="$HOME/.ssh/authorized_keys"
backup="$HOME/.ssh/__BACKUP__"
marker="$HOME/.ssh/__MARKER__"
key='__KEY__'
umask 077
if [ -f "$auth" ] && grep -Fqx -- "$key" "$auth"; then
    chmod 700 "$HOME/.ssh"
    chmod 600 "$auth"
    exit 0
fi
mkdir -p "$HOME/.ssh"
had_auth=0
if [ -e "$auth" ]; then had_auth=1; fi
touch "$auth"
if [ "$had_auth" -eq 1 ]; then
    cp -p "$auth" "$backup"
else
    : > "$backup"
fi
rollback() {
    set +e
    if [ "$had_auth" -eq 1 ]; then
        cp -p "$backup" "$auth"
    else
        rm -f "$auth"
    fi
    rm -f "$backup" "$marker"
}
trap rollback EXIT
printf '%s\n' "$key" >> "$auth"
: > "$marker"
chmod 700 "$HOME/.ssh"
chmod 600 "$auth"
trap - EXIT
'@
    $enrollCommand = $enrollCommand.Replace('__BACKUP__', $enrollmentBackupName).Replace('__MARKER__', $enrollmentMarkerName).Replace('__KEY__', $publicKey)
    $enrollCommand = ConvertTo-LinuxLf -Name 'SSH enrollment command' -Content $enrollCommand
    try {
        Invoke-NativeInteractive $script:Ssh @(
            '-tt',
            '-o', 'PreferredAuthentications=password',
            '-o', 'PubkeyAuthentication=no',
            $target,
            $enrollCommand
        )
    }
    catch {
        throw ('SSH enrollment failed; no remote mutation was attempted unless SSH authentication succeeded: {0}' -f $_.Exception.Message)
    }

    if (-not (Test-SshKeyAuthentication -SshPath $script:Ssh -KeyPath $keyPath -Target $target)) {
        Write-Result 'WARN' 'ssh-enrollment' 'key-only verification failed; rolling back only the PowerSeven key'
        $rollbackCommand = @'
set -eu
auth="$HOME/.ssh/authorized_keys"
backup="$HOME/.ssh/__BACKUP__"
marker="$HOME/.ssh/__MARKER__"
tmp="$HOME/.ssh/.powerseven-authorized_keys.rollback.__TOKEN__"
key='__KEY__'
if [ -f "$marker" ] && [ -f "$auth" ]; then
    awk -v key="$key" '$0 != key { print }' "$auth" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$auth"
fi
rm -f "$marker" "$backup" "$tmp"
chmod 700 "$HOME/.ssh"
if [ -f "$auth" ]; then chmod 600 "$auth"; fi
'@
        $rollbackCommand = $rollbackCommand.Replace('__BACKUP__', $enrollmentBackupName).Replace('__MARKER__', $enrollmentMarkerName).Replace('__TOKEN__', $enrollmentToken).Replace('__KEY__', $publicKey)
        $rollbackCommand = ConvertTo-LinuxLf -Name 'SSH enrollment rollback command' -Content $rollbackCommand
        try {
            Invoke-NativeInteractive $script:Ssh @(
                '-tt',
                '-o', 'PreferredAuthentications=password',
                '-o', 'PubkeyAuthentication=no',
                $target,
                $rollbackCommand
            )
        }
        catch {
            throw ('SSH enrollment failed and rollback could not be confirmed: {0}' -f $_.Exception.Message)
        }
        throw 'SSH enrollment failed; PowerSeven key rolled back'
    }

    $cleanupEnrollmentCommand = 'rm -f "$HOME/.ssh/{0}" "$HOME/.ssh/{1}"' -f $enrollmentBackupName, $enrollmentMarkerName
    $cleanupEnrollmentCommand = ConvertTo-LinuxLf -Name 'SSH enrollment cleanup command' -Content $cleanupEnrollmentCommand
    Invoke-Native $script:Ssh @(
        '-o', 'BatchMode=yes',
        '-o', 'PasswordAuthentication=no',
        '-o', 'IdentitiesOnly=yes',
        '-i', $keyPath,
        $target,
        $cleanupEnrollmentCommand
    )
    Write-Result 'PASS' 'ssh-enrollment' 'key-only authentication verified'
}
if (-not (Test-SshKeyAuthentication -SshPath $script:Ssh -KeyPath $keyPath -Target $target)) {
    throw 'SSH key authentication failed after enrollment'
}
Write-Result 'PASS' 'ssh-key-auth' 'key-only authentication succeeded'

$keyOnlySshOptions = @('-o', 'BatchMode=yes', '-o', 'PasswordAuthentication=no', '-o', 'IdentitiesOnly=yes', '-i', $keyPath)
if ($Check) {
    $bootstrapProbe = Test-ExistingBootstrapInstallation -SshPath $script:Ssh -KeyPath $keyPath -Target $target -RequiredVersion $requiredBootstrapVersion -RequiredCapabilities $requiredBootstrapCapabilities -RequiredCheckpoint $Checkpoint
    if (-not $bootstrapProbe.ProtocolSupported) {
        Write-Result 'WARN' 'bootstrap' ("installed version/capabilities do not support checkpoint {0}" -f $Checkpoint)
        Write-Result 'MISSING' 'bootstrap' 'migration required; no remote mutation was performed'
        exit 10
    }
    Write-Result 'PASS' 'bootstrap' 'version and capabilities support the requested checkpoint'
    $remoteCheckArguments = @(New-RemoteCheckpointArguments -Action '--check' -Checkpoint $Checkpoint)
    Write-Result 'INFO' 'checkpoint' ("mode=check checkpoint={0}" -f $Checkpoint)
    Write-Result 'INFO' 'checkpoint' ("remote command={0}" -f ($remoteCheckArguments -join ' '))
    $remoteCheck = Invoke-NativeReadOnly $script:Ssh ($keyOnlySshOptions + @($target) + $remoteCheckArguments)
    if ($remoteCheck.ExitCode -eq 0 -and -not $remoteCheck.HasRemediation) {
        Write-Result 'PASS' 'powerseven-bootstrap' "--check --checkpoint $Checkpoint completed"
        exit 0
    }
    if ($remoteCheck.HasRemediation) {
        Write-Result 'WARN' 'checkpoint' 'remote check completed; remediation is required and no mutation was performed'
        exit 10
    }
    Write-Result 'FAIL' 'checkpoint' ("remote read-only check failed with exit code {0}" -f $remoteCheck.ExitCode)
    exit 1
}

$temporaryFiles = $null
$remoteStageDir = $null
$localRouteState = $null
$localFirewallState = $null
$remoteClientStaged = $false
try {
    $bootstrapProbe = Test-ExistingBootstrapInstallation -SshPath $script:Ssh -KeyPath $keyPath -Target $target -RequiredVersion $requiredBootstrapVersion -RequiredCapabilities $requiredBootstrapCapabilities -RequiredCheckpoint $Checkpoint
    if ($bootstrapProbe.Ready) {
        Write-Result 'PASS' 'bootstrap' 'existing installation validated'
    } else {
        if (-not $bootstrapProbe.ProtocolSupported) {
            Write-Result 'WARN' 'bootstrap' ("installed version/capabilities do not support checkpoint {0}; automatic migration starting" -f $Checkpoint)
        } else {
            Write-Result 'WARN' 'bootstrap' 'installation is incomplete or incompatible; automatic repair/migration starting'
        }
        Write-Result 'INFO' 'sudo' 'interactive sudo authentication required; password is not captured or stored'
        $installToken = [guid]::NewGuid().ToString('N')
        $remoteStageDir = '/tmp/powerseven-stage-' + $installToken
        $remoteBackupDir = '/tmp/powerseven-backup-' + $installToken
        $stageCommand = 'umask 077; mkdir -p "{0}"; chmod 700 "{0}"' -f $remoteStageDir
        $stageCommand = ConvertTo-LinuxLf -Name 'bootstrap staging command' -Content $stageCommand
        Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target, $stageCommand))

        $temporaryFiles = New-RemoteBootstrapFiles -Username $UbuntuUsername -BootstrapSource $bootstrapSource
        $wrapperPath = $temporaryFiles[1]
        $sudoersPath = $temporaryFiles[2]
        $bootstrapCopyPath = $temporaryFiles[3]
        Invoke-Native $script:Scp ($keyOnlySshOptions + @($bootstrapCopyPath, ($target + ':' + $remoteStageDir + '/bootstrap.sh')))
        Invoke-Native $script:Scp ($keyOnlySshOptions + @($wrapperPath, ($target + ':' + $remoteStageDir + '/powerseven-bootstrap-wrapper')))
        Invoke-Native $script:Scp ($keyOnlySshOptions + @($sudoersPath, ($target + ':' + $remoteStageDir + '/powerseven-bootstrap.sudoers')))

        $installCommand = @'
set -eu
stage='__STAGE__'
backup='__BACKUP__'
bootstrap='/usr/local/lib/powerseven/bootstrap.sh'
wrapper='/usr/local/sbin/powerseven-bootstrap'
sudoers='/etc/sudoers.d/powerseven-bootstrap'

# Authentication and the complete privileged transaction stay in this one SSH session.
bash -n "$0"
if ! sudo -v; then
    echo 'sudo credential validation failed; no PowerSeven files were installed' >&2
    exit 1
fi

snapshot() {
    destination="$1"
    saved="$2"
    if [ -e "$destination" ]; then
        sudo cp -a "$destination" "$saved"
        sudo touch "$saved.present"
    else
        sudo touch "$saved.absent"
    fi
}

restore() {
    destination="$1"
    saved="$2"
    if [ -e "$saved.present" ]; then
        sudo cp -a "$saved" "$destination"
    elif [ -e "$saved.absent" ]; then
        sudo rm -f "$destination"
    fi
}

rollback() {
    rc=$?
    set +e
    restore "$bootstrap" "$backup/bootstrap"
    restore "$wrapper" "$backup/wrapper"
    restore "$sudoers" "$backup/sudoers"
    sudo rm -rf "$backup" "$stage"
    exit "$rc"
}
trap rollback ERR

test -f "$stage/bootstrap.sh"
test -f "$stage/powerseven-bootstrap-wrapper"
test -f "$stage/powerseven-bootstrap.sudoers"
bash -n "$stage/bootstrap.sh"
bash -n "$stage/powerseven-bootstrap-wrapper"
sudo visudo -cf "$stage/powerseven-bootstrap.sudoers"

sudo install -d -o root -g root -m 0700 "$backup"
snapshot "$bootstrap" "$backup/bootstrap"
snapshot "$wrapper" "$backup/wrapper"
snapshot "$sudoers" "$backup/sudoers"

sudo install -d -o root -g root -m 0755 /usr/local/lib/powerseven
sudo install -o root -g root -m 0755 "$stage/bootstrap.sh" "$bootstrap"
sudo install -o root -g root -m 0755 "$stage/powerseven-bootstrap-wrapper" "$wrapper"
sudo install -o root -g root -m 0440 "$stage/powerseven-bootstrap.sudoers" "$sudoers"
sudo visudo -cf "$sudoers"
test "$(sudo "$wrapper" --version)" = 'powerseven-bootstrap 5'
test "$(sudo "$wrapper" --capabilities)" = 'checkpoints=1,2,3'
test "$(sudo stat -c "%U:%G:%a" "$bootstrap")" = "root:root:755"
test "$(sudo stat -c "%U:%G:%a" "$wrapper")" = "root:root:755"
test "$(sudo stat -c "%U:%G:%a" "$sudoers")" = "root:root:440"
if sudo "$wrapper" --invalid --checkpoint 1 >/dev/null 2>&1; then
    exit 1
else
    rc=$?
    [ "$rc" -eq 2 ]
fi

trap - ERR
sudo rm -rf "$backup" "$stage"
'@
        $installCommand = $installCommand.Replace('__STAGE__', $remoteStageDir).Replace('__BACKUP__', $remoteBackupDir)
        $installCommand = ConvertTo-LinuxLf -Name 'privileged bootstrap transaction' -Content $installCommand
        $transactionPath = Join-Path $temporaryFiles[0] 'powerseven-install-transaction.sh'
        [System.IO.File]::WriteAllText($transactionPath, $installCommand, [System.Text.UTF8Encoding]::new($false))
        Assert-LinuxPayloadLf -Name 'staged privileged bootstrap transaction' -Content ([System.IO.File]::ReadAllText($transactionPath))
        Invoke-Native $script:Scp ($keyOnlySshOptions + @($transactionPath, ($target + ':' + $remoteStageDir + '/powerseven-install-transaction.sh')))
        $remoteTransactionCommand = ConvertTo-LinuxLf -Name 'privileged bootstrap transaction launcher' -Content ('bash "{0}/powerseven-install-transaction.sh"' -f $remoteStageDir)
        try {
            Invoke-NativeInteractive $script:Ssh @('-tt', '-o', 'PasswordAuthentication=no', '-o', 'IdentitiesOnly=yes', '-i', $keyPath, $target, $remoteTransactionCommand)
        }
        catch {
            throw ('privileged bootstrap transaction failed; staged files were cleaned and prior installation was restored when necessary: {0}' -f $_.Exception.Message)
        }
        Write-Result 'PASS' 'bootstrap' 'PowerSeven installation migrated and validated'
    }

    if ($PrepareBootstrap) {
        Write-Result 'PASS' 'bootstrap' ("version {0} installed; capabilities {1}" -f $requiredBootstrapVersion, $requiredBootstrapCapabilities)
        Write-Result 'SKIP' 'checkpoint' ("checkpoint {0} apply not requested" -f $Checkpoint)
        exit 0
    }

    if ($Checkpoint -eq '3' -and $Apply) {
        Assert-LocalAdministrator
        $clientDirectory = Join-Path $env:ProgramData 'PowerSeven\clients'
        New-Item -ItemType Directory -Path $clientDirectory -Force | Out-Null
        Set-RestrictedAcl -Path $clientDirectory -Directory $true
        $localRouteState = Ensure-DC02AdminRoute
        $localFirewallState = Ensure-DC02RdpFirewall
    }

    $action = if ($Apply) { '--apply' } else { '--check' }
    Write-Result 'INFO' 'checkpoint' ("mode={0} checkpoint={1}" -f $action.TrimStart('-'), $Checkpoint)

    if ($Checkpoint -eq '2' -and $Apply) {
        $networkToken = [guid]::NewGuid().ToString('N')
        $remoteCheckpointArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '2' -ExtraOption '--network-token' -ExtraValue $networkToken)
        Write-Result 'INFO' 'checkpoint' 'network transition may close the current DHCP SSH session'
        Write-Result 'INFO' 'checkpoint' ("remote command={0}" -f ($remoteCheckpointArguments -join ' '))
        try {
            Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $remoteCheckpointArguments)
        }
        catch {
            Write-Result 'WARN' 'checkpoint' 'old DHCP address disconnected during the expected network transition; validating the static address'
        }
        $Vps14Address = '192.168.214.14'
        $target = '{0}@{1}' -f $UbuntuUsername, $Vps14Address
        if (-not (Test-SshKeyAuthentication -SshPath $script:Ssh -KeyPath $keyPath -Target $target)) {
            throw 'VPS14 did not become reachable through the new static address; its rollback guard remains active'
        }
        $confirmArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '2' -ExtraOption '--confirm-network' -ExtraValue $networkToken)
        Write-Result 'INFO' 'checkpoint' ("remote command={0}" -f ($confirmArguments -join ' '))
        Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $confirmArguments)
        Write-Result 'PASS' 'network' 'DHCP .145 to static .14 transition confirmed'
    } elseif ($Checkpoint -eq '3' -and $Apply) {
        $clientDirectory = Join-Path $env:ProgramData 'PowerSeven\clients'
        $clientConfigPath = Join-Path $clientDirectory 'powerseven-admin-laptop.conf'
        $localConfigExists = Test-Path -LiteralPath $clientConfigPath -PathType Leaf
        if ($localConfigExists) { Set-RestrictedAcl -Path $clientConfigPath -Directory $false }
        if ($localConfigExists -and -not (Test-AdminClientConfig -Path $clientConfigPath)) {
            throw 'existing local admin client config is invalid; refusing automatic identity replacement'
        }
        $checkArguments = @(New-RemoteCheckpointArguments -Action '--check' -Checkpoint '3')
        $remoteReady = Test-NativeSuccess $script:Ssh ($keyOnlySshOptions + @($target) + $checkArguments)
        if ($localConfigExists -and -not $remoteReady) {
            throw 'VPS14 has no matching usable admin VPN state for the existing local client config; explicit rotation is required'
        }
        if (-not $localConfigExists) {
            $applyArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '3')
            Write-Result 'INFO' 'checkpoint' ("remote command={0}" -f ($applyArguments -join ' '))
            Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $applyArguments)
            $remoteClientStaged = $true
            $temporaryClientPath = Join-Path $clientDirectory ('.powerseven-admin-laptop.conf.' + [guid]::NewGuid().ToString('N'))
            Invoke-Native $script:Scp ($keyOnlySshOptions + @($target + ':/tmp/powerseven-admin-laptop.conf', $temporaryClientPath))
            Set-RestrictedAcl -Path $temporaryClientPath -Directory $false
            if (-not (Test-AdminClientConfig -Path $temporaryClientPath)) {
                throw 'downloaded admin client configuration failed local structural validation'
            }
            Move-Item -LiteralPath $temporaryClientPath -Destination $clientConfigPath -Force
            $cleanupArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '3' -ExtraOption '--cleanup-client')
            Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $cleanupArguments)
            $remoteClientStaged = $false
            Write-Result 'PASS' 'admin-client' "client config exported to $clientConfigPath"
        } else {
            $cleanupArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '3' -ExtraOption '--cleanup-client')
            Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $cleanupArguments)
            Write-Result 'PASS' 'admin-client' 'existing client identity/config reused; no new key generated'
        }
        $rdpPath = New-LocalRdpFile -Directory $clientDirectory
        Write-Result 'PASS' 'dc02-rdp' "RDP profile created at $rdpPath without credentials"
        Write-Result 'PASS' 'admin-vpn' 'WireGuard administrative VPN checkpoint completed'
    } else {
        $remoteCheckpointArguments = @(New-RemoteCheckpointArguments -Action $action -Checkpoint $Checkpoint)
        Write-Result 'INFO' 'checkpoint' ("remote command={0}" -f ($remoteCheckpointArguments -join ' '))
        Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $remoteCheckpointArguments)
        Write-Result 'PASS' 'powerseven-bootstrap' "$action --checkpoint $Checkpoint completed"
    }
}
catch {
    if ($remoteClientStaged) {
        try {
            $cleanupArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '3' -ExtraOption '--cleanup-client')
            Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $cleanupArguments)
        }
        catch {
            Write-Result 'WARN' 'admin-client' 'remote client staging cleanup could not be confirmed; no new identity will be generated automatically'
        }
    }
    Restore-DC02RdpFirewall -FirewallState $localFirewallState
    Remove-DC02AdminRoute -RouteState $localRouteState
    throw
}
finally {
    if ($null -ne $temporaryFiles -and $temporaryFiles.Count -gt 0) {
        Remove-Item -LiteralPath $temporaryFiles[0] -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not [string]::IsNullOrWhiteSpace($remoteStageDir)) {
        try {
            $remoteStageCleanup = ConvertTo-LinuxLf -Name 'bootstrap staging cleanup command' -Content ('rm -rf "{0}"' -f $remoteStageDir)
            Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target, $remoteStageCleanup))
        }
        catch {
            Write-Result 'WARN' 'cleanup' 'remote staging cleanup could not be confirmed'
        }
    }
}
