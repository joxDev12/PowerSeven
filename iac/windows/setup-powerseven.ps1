[CmdletBinding()]
param(
    [string]$Vps14Address,
    [string]$UbuntuUsername,
    [ValidateSet('1', '2', '3', '4', '5', '6', '7', '8', '9')]
    [string]$Checkpoint = '1',
    [string[]]$PeerNames = @(),
    [switch]$Check,
    [switch]$Apply,
    [switch]$PrepareBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AdminClientAllowedIPs = '192.168.214.0/25, 192.168.214.128/25'
$script:LegacyAdminClientAllowedIPs = '192.168.214.0/24'

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

    & $FilePath @ArgumentList | Out-Host
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

function Invoke-NativeBounded {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds
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
            throw "Could not start bounded command: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            try { $process.Kill() } catch { }
            $process.WaitForExit()
        }
        return [pscustomobject]@{
            ExitCode = if ($completed) { $process.ExitCode } else { $null }
            TimedOut = -not $completed
            StandardOutput = [string]$stdoutTask.Result
            StandardError = [string]$stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Write-NativeResultOutput {
    param([pscustomobject]$Result)

    foreach ($line in ([string]$Result.StandardOutput -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Host $line }
    }
    foreach ($line in ([string]$Result.StandardError -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Host $line }
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
        [string]$Target,
        [string]$HostKeyAlias = ''
    )

    $result = Invoke-SshKeyAuthenticationProbe -SshPath $SshPath -KeyPath $KeyPath -Target $Target -HostKeyAlias $HostKeyAlias
    return ($result.ExitCode -eq 0)
}

function Invoke-SshKeyAuthenticationProbe {
    param(
        [string]$SshPath,
        [string]$KeyPath,
        [string]$Target,
        [string]$HostKeyAlias = ''
    )

    $arguments = @(
        '-o', 'BatchMode=yes',
        '-o', 'PasswordAuthentication=no',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=5',
        '-o', 'ServerAliveCountMax=2',
        '-i', $KeyPath,
        $Target,
        'true'
    )
    if (-not [string]::IsNullOrWhiteSpace($HostKeyAlias)) {
        $arguments = @('-o', "HostKeyAlias=$HostKeyAlias") + $arguments
    }
    return Invoke-NativeCapture $SshPath $arguments
}

function Test-TcpPort {
    param(
        [string]$Address,
        [int]$Port,
        [ValidateRange(100, 10000)]
        [int]$TimeoutMilliseconds = 1000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Wait-ForVps14Ssh {
    param(
        [string]$SshPath,
        [string]$KeyPath,
        [string]$Address,
        [string]$Username,
        [string]$HostKeyAlias,
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 60,
        [ValidateRange(1, 10)]
        [int]$IntervalSeconds = 2
    )

    $target = '{0}@{1}' -f $Username, $Address
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -le $TimeoutSeconds) {
        $elapsed = [int][math]::Floor($stopwatch.Elapsed.TotalSeconds)
        if (Test-TcpPort -Address $Address -Port 22) {
            $probe = Invoke-SshKeyAuthenticationProbe -SshPath $SshPath -KeyPath $KeyPath -Target $target -HostKeyAlias $HostKeyAlias
            if ($probe.ExitCode -eq 0) {
                return $true
            }
            $diagnostic = '{0} {1}' -f $probe.StandardError, $probe.StandardOutput
            if ($diagnostic -match '(?i)(host key verification failed|remote host identification has changed|no .* host key is known)') {
                throw 'VPS14 static address host key does not match the previously trusted DHCP identity; refusing connection'
            }
            Write-Result 'INFO' 'network' ("{0}:22 reachable; key-only authentication pending ({1}s/{2}s)" -f $Address, $elapsed, $TimeoutSeconds)
        } else {
            Write-Result 'INFO' 'network' ("waiting for {0}:22 ({1}s/{2}s)" -f $Address, $elapsed, $TimeoutSeconds)
        }
        $remaining = $TimeoutSeconds - [int][math]::Floor($stopwatch.Elapsed.TotalSeconds)
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([math]::Min($IntervalSeconds, $remaining))
    }
    return $false
}

function Test-BootstrapProtocol {
    param(
        [string]$SshPath,
        [string]$KeyPath,
        [string]$Target,
        [string]$RequiredVersion,
        [string]$RequiredCapabilities,
        [string]$HostKeyAlias = '',
        [ValidateSet('1', '2', '3', '4', '5', '6', '7', '8', '9')]
        [string]$RequiredCheckpoint
    )

    $sshOptions = @(
        '-o', 'BatchMode=yes',
        '-o', 'PasswordAuthentication=no',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=5',
        '-o', 'ServerAliveCountMax=2',
        '-i', $KeyPath
    )
    if (-not [string]::IsNullOrWhiteSpace($HostKeyAlias)) {
        $sshOptions += @('-o', "HostKeyAlias=$HostKeyAlias")
    }

    $probe = Invoke-NativeCapture $SshPath ($sshOptions + @($Target, 'sudo', '-n', '/usr/local/sbin/powerseven-bootstrap', '--protocol'))
    $output = ([string]$probe.StandardOutput).Trim()
    $authenticated = $probe.ExitCode -ne 255
    if (-not $authenticated) {
        return [pscustomobject]@{ Authenticated = $false; Supported = $false }
    }
    if ($probe.ExitCode -ne 0) {
        return [pscustomobject]@{ Authenticated = $true; Supported = $false }
    }

    $protocolLines = @($output -split '\r?\n')
    if ($protocolLines.Count -ne 2 -or
        $protocolLines[0] -cne ('powerseven-bootstrap {0}' -f $RequiredVersion) -or
        $protocolLines[1] -cne $RequiredCapabilities) {
        return [pscustomobject]@{ Authenticated = $true; Supported = $false }
    }

    $capabilityMatch = [regex]::Match($protocolLines[1], '^checkpoints=(?<values>[1-9][0-9]*(?:,[1-9][0-9]*)*)$')
    if (-not $capabilityMatch.Success -or
        (($capabilityMatch.Groups['values'].Value -split ',') -notcontains $RequiredCheckpoint)) {
        return [pscustomobject]@{ Authenticated = $true; Supported = $false }
    }
    return [pscustomobject]@{ Authenticated = $true; Supported = $true }
}

function Test-ExistingBootstrapInstallation {
    param(
        [string]$SshPath,
        [string]$KeyPath,
        [string]$Target,
        [string]$RequiredVersion,
        [string]$RequiredCapabilities,
        [string]$HostKeyAlias = '',
        [ValidateSet('1', '2', '3', '4', '5', '6', '7', '8', '9')]
        [string]$RequiredCheckpoint
    )

    $protocol = Test-BootstrapProtocol -SshPath $SshPath -KeyPath $KeyPath -Target $Target -RequiredVersion $RequiredVersion -RequiredCapabilities $RequiredCapabilities -HostKeyAlias $HostKeyAlias -RequiredCheckpoint $RequiredCheckpoint
    if (-not $protocol.Authenticated -or -not $protocol.Supported) {
        return [pscustomobject]@{ Ready = $false; Authenticated = $protocol.Authenticated; ProtocolSupported = $false }
    }
    return [pscustomobject]@{ Ready = $true; Authenticated = $true; ProtocolSupported = $true }
}

function New-RemoteCheckpointArguments {
    param(
        [ValidateSet('--check', '--apply')]
        [string]$Action,
        [ValidateSet('1', '2', '3', '4', '5', '6', '7', '8', '9')]
        [string]$Checkpoint,
        [ValidateSet('', '--network-token', '--confirm-network', '--cleanup-client', '--peer-list')]
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
        if ($ExtraValue -cnotmatch '^[a-z][a-z0-9_-]{0,31}$') { throw 'Invalid admin VPN peer name' }
        $arguments += @($ExtraOption, $ExtraValue)
    } elseif ($ExtraOption -eq '--peer-list') {
        if ($Checkpoint -ne '3' -or $Action -ne '--apply' -or $ExtraValue -cnotmatch '^[a-z][a-z0-9_-]{0,31}(,[a-z][a-z0-9_-]{0,31})*$') {
            throw 'Invalid initial admin VPN peer list'
        }
        $arguments += @($ExtraOption, $ExtraValue)
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
        [string]$BootstrapContent
    )

    $wrapper = @'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 1 && ( "$1" == '--version' || "$1" == '--capabilities' || "$1" == '--protocol' || "$1" == '--peer-status' || "$1" == '--admin-endpoint' ) ]]; then
    exec /usr/local/lib/powerseven/bootstrap.sh "$@"
fi

if [[ "$#" -ne 3 && "$#" -ne 5 ]]; then
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

if [[ "$#" -eq 5 ]]; then
    if [[ "$1" != '--apply' ]]; then
        echo 'invalid extended checkpoint arguments' >&2
        exit 2
    fi
    if [[ "$3" == '2' ]]; then
        if [[ "$4" != '--network-token' && "$4" != '--confirm-network' ]] || [[ ! "$5" =~ ^[a-f0-9]{32}$ ]]; then
            echo 'invalid network transaction token' >&2; exit 2
        fi
    elif [[ "$3" == '3' ]]; then
        if [[ "$4" == '--cleanup-client' ]]; then
            [[ "$5" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo 'invalid admin VPN peer' >&2; exit 2; }
        elif [[ "$4" == '--peer-list' ]]; then
            [[ "$5" =~ ^[a-z][a-z0-9_-]{0,31}(,[a-z][a-z0-9_-]{0,31})*$ ]] || { echo 'invalid admin VPN peer list' >&2; exit 2; }
        else
            echo 'invalid admin VPN peer' >&2; exit 2
        fi
    else
        echo 'invalid extended checkpoint arguments' >&2; exit 2
    fi
fi

exec /usr/local/lib/powerseven/bootstrap.sh "$@"
'@

    $sudoers = "{0} ALL=(root) NOPASSWD: /usr/local/sbin/powerseven-bootstrap`n" -f $Username
    $wrapper = ConvertTo-LinuxLf -Name 'bootstrap wrapper' -Content $wrapper
    $sudoers = ConvertTo-LinuxLf -Name 'bootstrap sudoers' -Content $sudoers
    $bootstrapContent = ConvertTo-LinuxLf -Name 'bootstrap script' -Content $BootstrapContent
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
    $stores = @('ActiveStore', 'PersistentStore')
    $present = @()
    foreach ($store in $stores) {
        $routes = @(Get-NetRoute -DestinationPrefix $destination -PolicyStore $store -ErrorAction SilentlyContinue)
        if ($routes.Count -gt 1 -or @($routes | Where-Object { $_.NextHop -ne $Gateway -or $_.InterfaceIndex -ne $underlay.InterfaceIndex }).Count -gt 0) {
            throw "Conflicting or duplicate DC02 route exists in $store for $destination"
        }
        $present += ($routes.Count -eq 1)
    }
    if ($present[0] -and $present[1]) {
        Write-Result 'PASS' 'dc02-route' "$destination via $Gateway already present in both route stores"
        return @{ Added = $false; Destination = $destination; NextHop = $Gateway; InterfaceIndex = $underlay.InterfaceIndex }
    }
    if ($present[0] -or $present[1]) {
        $existingStore = if ($present[0]) { 'ActiveStore' } else { 'PersistentStore' }
        Remove-NetRoute -DestinationPrefix $destination -NextHop $Gateway -InterfaceIndex $underlay.InterfaceIndex -PolicyStore $existingStore -Confirm:$false -ErrorAction Stop
        Write-Result 'WARN' 'dc02-route' "partial route in $existingStore removed before recreating both stores"
    }
    try {
        New-NetRoute -DestinationPrefix $destination -NextHop $Gateway -InterfaceIndex $underlay.InterfaceIndex -RouteMetric 50 -ErrorAction Stop | Out-Null
        foreach ($store in $stores) {
            $verified = @(Get-NetRoute -DestinationPrefix $destination -PolicyStore $store -ErrorAction Stop |
                Where-Object { $_.NextHop -eq $Gateway -and $_.InterfaceIndex -eq $underlay.InterfaceIndex })
            if ($verified.Count -ne 1) { throw "Could not validate DC02 route in $store for $destination" }
        }
    }
    catch {
        foreach ($store in $stores) {
            Remove-NetRoute -DestinationPrefix $destination -NextHop $Gateway -InterfaceIndex $underlay.InterfaceIndex -PolicyStore $store -Confirm:$false -ErrorAction SilentlyContinue
        }
        throw
    }
    Write-Result 'PASS' 'dc02-route' "$destination via $Gateway created persistently"
    return @{ Added = $true; Destination = $destination; NextHop = $Gateway; InterfaceIndex = $underlay.InterfaceIndex }
}

function Remove-DC02AdminRoute {
    param([hashtable]$RouteState)
    if ($null -eq $RouteState -or -not $RouteState.Added) { return }
    foreach ($store in @('ActiveStore', 'PersistentStore')) {
        Remove-NetRoute -DestinationPrefix $RouteState.Destination -NextHop $RouteState.NextHop -InterfaceIndex $RouteState.InterfaceIndex -PolicyStore $store -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Result 'WARN' 'dc02-route' 'new administrative VPN route removed during rollback'
}

function Get-FirewallAddressIdentity {
    param([string]$Address)
    $token = $Address.Trim()
    if ($token -match '^(?i:Any|LocalSubnet|DNS|DHCP|WINS|DefaultGateway|Internet|Intranet|IntranetRemoteAccess|PlayToDevice|CaptivePortal)([46])?$') {
        return "keyword:$($token.ToLowerInvariant())"
    }

    $parts = @([regex]::Split($token, '-', 3))
    if ($parts.Count -eq 2) {
        $start = $null
        $end = $null
        if (-not [System.Net.IPAddress]::TryParse($parts[0].Trim(), [ref]$start) -or
            -not [System.Net.IPAddress]::TryParse($parts[1].Trim(), [ref]$end)) { throw "Invalid firewall address range: $token" }
        $startBytes = $start.GetAddressBytes()
        $endBytes = $end.GetAddressBytes()
        if ($startBytes.Length -ne $endBytes.Length) { throw "Mixed-family firewall address range: $token" }
        $startKey = [System.BitConverter]::ToString($startBytes).Replace('-', '').ToLowerInvariant()
        $endKey = [System.BitConverter]::ToString($endBytes).Replace('-', '').ToLowerInvariant()
        if ([string]::CompareOrdinal($startKey, $endKey) -gt 0) { throw "Reversed firewall address range: $token" }
        return "range$($startBytes.Length):$startKey-$endKey"
    }

    $subnet = @([regex]::Split($token, '/', 3))
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($subnet[0], [ref]$ip)) { throw "Invalid firewall address: $token" }
    $bytes = $ip.GetAddressBytes()
    $prefix = $bytes.Length * 8
    if ($subnet.Count -eq 2) {
        if ($subnet[1] -match '^\d+$') {
            if (-not [int]::TryParse($subnet[1], [ref]$prefix) -or $prefix -gt ($bytes.Length * 8)) {
                throw "Invalid firewall network prefix: $token"
            }
        } else {
            $mask = $null
            if ($bytes.Length -ne 4 -or -not [System.Net.IPAddress]::TryParse($subnet[1], [ref]$mask) -or $mask.GetAddressBytes().Length -ne 4) {
                throw "Invalid firewall subnet mask: $token"
            }
            $prefix = 0
            $zeroSeen = $false
            foreach ($maskByte in $mask.GetAddressBytes()) {
                for ($bit = 7; $bit -ge 0; $bit--) {
                    if (($maskByte -band (1 -shl $bit)) -ne 0) {
                        if ($zeroSeen) { throw "Non-contiguous firewall subnet mask: $token" }
                        $prefix++
                    } else {
                        $zeroSeen = $true
                    }
                }
            }
        }
    } elseif ($subnet.Count -gt 2) {
        throw "Invalid firewall subnet: $token"
    }

    $remaining = $prefix
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($remaining -ge 8) {
            $remaining -= 8
        } elseif ($remaining -gt 0) {
            $maskByte = (255 -shl (8 - $remaining)) -band 255
            $bytes[$index] = [byte]($bytes[$index] -band $maskByte)
            $remaining = 0
        } else {
            $bytes[$index] = 0
        }
    }
    $networkKey = [System.BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    return "network$($bytes.Length):$networkKey/$prefix"
}

function Test-FirewallAddressSet {
    param([string[]]$Actual, [string[]]$Expected)
    try {
        $actualSet = @{}
        foreach ($address in $Actual) { $actualSet[(Get-FirewallAddressIdentity -Address $address)] = $true }
        $expectedSet = @{}
        foreach ($address in $Expected) { $expectedSet[(Get-FirewallAddressIdentity -Address $address)] = $true }
        if ($actualSet.Count -ne $expectedSet.Count) { return $false }
        foreach ($identity in $expectedSet.Keys) {
            if (-not $actualSet.ContainsKey($identity)) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Test-ManagedRdpRule {
    param([string]$Name, [string]$Action, [string[]]$RemoteAddress, [string]$LocalAddress)
    foreach ($store in @('PersistentStore', 'ActiveStore')) {
        $rules = @(Get-NetFirewallRule -Name $Name -PolicyStore $store -ErrorAction SilentlyContinue)
        if ($rules.Count -ne 1) { return $false }
        $rule = $rules[0]
        if ($rule.Direction -ne 'Inbound' -or $rule.Action -ne $Action -or $rule.Enabled -ne 'True' -or $rule.Profile -ne 'Any') { return $false }
        $port = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
        $address = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
        if ([string]$port.Protocol -notin @('TCP', '6') -or @($port.LocalPort).Count -ne 1 -or [string]$port.LocalPort -ne '3389') { return $false }
        if (-not (Test-FirewallAddressSet -Actual @($address.LocalAddress) -Expected @($LocalAddress))) { return $false }
        if (-not (Test-FirewallAddressSet -Actual @($address.RemoteAddress) -Expected $RemoteAddress)) { return $false }
    }
    return $true
}

function Test-DC02RdpFirewall {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    if ($profiles.Count -ne 3 -or @($profiles | Where-Object { $_.Enabled -ne 'True' }).Count -gt 0) { return $false }
    $outsideIPv4 = @('0.0.0.1-10.98.255.255', '10.99.1.0-255.255.255.254')
    $outsideIPv6 = @('::2-feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
    return ((Test-ManagedRdpRule -Name 'PowerSeven-AdminVPN-RDP-BlockOutsideIPv4' -Action Block -RemoteAddress $outsideIPv4 -LocalAddress Any) -and
        (Test-ManagedRdpRule -Name 'PowerSeven-AdminVPN-RDP-BlockOutsideIPv6' -Action Block -RemoteAddress $outsideIPv6 -LocalAddress Any) -and
        (Test-ManagedRdpRule -Name 'PowerSeven-AdminVPN-RDP-Allow' -Action Allow -RemoteAddress @('10.99.0.0/24') -LocalAddress '192.168.214.13'))
}

function Ensure-DC02RdpFirewall {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    if ($profiles.Count -ne 3 -or @($profiles | Where-Object { $_.Enabled -ne 'True' }).Count -gt 0) {
        throw 'Windows Defender Firewall must be enabled in all active profiles before CP3 can protect RDP'
    }
    $outsideIPv4 = @('0.0.0.1-10.98.255.255', '10.99.1.0-255.255.255.254')
    $outsideIPv6 = @('::2-feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
    $blockIPv4Name = 'PowerSeven-AdminVPN-RDP-BlockOutsideIPv4'
    $blockIPv6Name = 'PowerSeven-AdminVPN-RDP-BlockOutsideIPv6'
    $allowName = 'PowerSeven-AdminVPN-RDP-Allow'
    $blockIPv4 = @(Get-NetFirewallRule -Name $blockIPv4Name -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
    if ($blockIPv4.Count -eq 0) {
        New-NetFirewallRule -Name $blockIPv4Name -DisplayName 'PowerSeven RDP block outside admin VPN IPv4' -Direction Inbound -Action Block -Enabled True -Profile Any -Protocol TCP -LocalPort 3389 -RemoteAddress $outsideIPv4 -PolicyStore PersistentStore -ErrorAction Stop | Out-Null
    }
    if (-not (Test-ManagedRdpRule -Name $blockIPv4Name -Action Block -RemoteAddress $outsideIPv4 -LocalAddress Any)) {
        throw 'PowerSeven RDP IPv4 block rule is missing or differs from the effective policy'
    }
    $blockIPv6 = @(Get-NetFirewallRule -Name $blockIPv6Name -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
    if ($blockIPv6.Count -eq 0) {
        New-NetFirewallRule -Name $blockIPv6Name -DisplayName 'PowerSeven RDP block outside admin VPN IPv6' -Direction Inbound -Action Block -Enabled True -Profile Any -Protocol TCP -LocalPort 3389 -RemoteAddress $outsideIPv6 -PolicyStore PersistentStore -ErrorAction Stop | Out-Null
    }
    if (-not (Test-ManagedRdpRule -Name $blockIPv6Name -Action Block -RemoteAddress $outsideIPv6 -LocalAddress Any)) {
        throw 'PowerSeven RDP IPv6 block rule is missing or differs from the effective policy'
    }
    $allow = @(Get-NetFirewallRule -Name $allowName -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
    if ($allow.Count -eq 0) {
        New-NetFirewallRule -Name $allowName -DisplayName 'PowerSeven RDP allow from admin VPN' -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalPort 3389 -LocalAddress '192.168.214.13' -RemoteAddress '10.99.0.0/24' -PolicyStore PersistentStore -ErrorAction Stop | Out-Null
    }
    if (-not (Test-DC02RdpFirewall)) { throw 'PowerSeven RDP allow/block policy is not effective' }
    Write-Result 'PASS' 'dc02-rdp-firewall' 'managed IPv4/IPv6 TCP/3389 blocks outside VPN and allow from 10.99.0.0/24 are effective'
}

function Test-AdminClientConfig {
    param([string]$Path, [string]$Address, [string]$Endpoint = '', [switch]$AllowLegacyRoutes)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $content = Get-Content -LiteralPath $Path -Raw
    $allowed = [regex]::Matches($content, '(?m)^AllowedIPs = (.+)$')
    $validRoutes = @($script:AdminClientAllowedIPs)
    if ($AllowLegacyRoutes) { $validRoutes += $script:LegacyAdminClientAllowedIPs }
    return ($content -match '(?m)^\[Interface\]$' -and
        $content -match ("(?m)^Address = {0}$" -f [regex]::Escape($Address)) -and
        [regex]::Matches($content, '(?m)^\[Peer\]$').Count -eq 1 -and
        $allowed.Count -eq 1 -and $allowed[0].Groups[1].Value -cin $validRoutes -and
        $content -match '(?m)^Endpoint = \S+:51820$' -and
        ($Endpoint -eq '' -or $content -match ("(?m)^Endpoint = {0}$" -f [regex]::Escape($Endpoint))) -and
        $content -match '(?m)^PrivateKey = \S+$')
}

function Get-RemoteAdminPeers {
    param([string]$Target, [string[]]$SshOptions)
    $result = Invoke-NativeCapture $script:Ssh ($SshOptions + @($Target, 'sudo', '-n', '/usr/local/sbin/powerseven-bootstrap', '--peer-status'))
    if ($result.ExitCode -ne 0) { throw 'remote admin VPN peer-state probe failed' }
    $output = $result.StandardOutput.Replace("`r", '').Trim()
    if ($output.Length -eq 0) { return @() }
    $peers = @()
    $seen = @{}
    foreach ($line in ($output -split "`n")) {
        if ($line -cnotmatch '^([a-z][a-z0-9_-]{0,31})\|(10\.99\.0\.([0-9]{1,3})/32)\|(absent|staged|exported|invalid)$') {
            throw 'remote admin VPN peer-state protocol is invalid'
        }
        $name = $Matches[1]
        $address = $Matches[2]
        $octet = [int]$Matches[3]
        $status = $Matches[4]
        if ($seen.ContainsKey($name) -or $octet -ne ($peers.Count + 2) -or $peers.Count -ge 253 -or $status -eq 'invalid') {
            throw 'remote admin VPN peer inventory is inconsistent'
        }
        $seen[$name] = $true
        $peers += @{ Name = $name; Address = $address; Status = $status }
    }
    return $peers
}

function Resolve-AdminPeerNames {
    param([array]$ExistingPeers, [string[]]$RequestedNames)
    $names = @($RequestedNames)
    if ($ExistingPeers.Count -eq 0 -and $names.Count -eq 0) {
        $countText = Read-Host 'Quanti dispositivi VPN amministrativi vuoi creare (1-253)?'
        $count = 0
        if (-not [int]::TryParse($countText, [ref]$count) -or $count -lt 1 -or $count -gt 253) {
            throw 'Peer count must be between 1 and 253; rerun with -PeerNames to automate setup'
        }
        for ($index = 1; $index -le $count; $index++) {
            $names += Read-Host ("Nome del dispositivo VPN {0}/{1}" -f $index, $count)
        }
    }
    if ($names.Count -eq 0) { return @($ExistingPeers | ForEach-Object { $_.Name }) }
    if ($names.Count -gt 253) { throw 'At most 253 admin VPN peers are supported' }
    $normalized = @()
    $seen = @{}
    foreach ($name in $names) {
        $canonical = $name.Trim().ToLowerInvariant()
        if ($canonical -cnotmatch '^[a-z][a-z0-9_-]{0,31}$' -or $seen.ContainsKey($canonical)) {
            throw "Invalid or duplicate admin VPN peer name: $name"
        }
        $seen[$canonical] = $true
        $normalized += $canonical
    }
    if ($ExistingPeers.Count -gt 0 -and (($normalized -join ',') -cne ((@($ExistingPeers | ForEach-Object { $_.Name })) -join ','))) {
        throw 'Requested peers differ from the persistent VPS14 inventory; normal reruns cannot rename or replace identities'
    }
    return $normalized
}

function Get-RemoteAdminEndpoint {
    param([string]$Target, [string[]]$SshOptions)
    $result = Invoke-NativeCapture $script:Ssh ($SshOptions + @($Target, 'sudo', '-n', '/usr/local/sbin/powerseven-bootstrap', '--admin-endpoint'))
    $endpoint = $result.StandardOutput.Trim()
    if ($result.ExitCode -ne 0 -or $endpoint -notmatch '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}:51820$') {
        throw 'Could not determine the current VPS14 bridged VPN endpoint'
    }
    return $endpoint
}

function Update-AdminClientProfile {
    param([string]$Path, [string]$Endpoint)
    $content = Get-Content -LiteralPath $Path -Raw
    $endpointMatches = [regex]::Matches($content, '(?m)^Endpoint = \S+:51820$')
    $allowedMatches = [regex]::Matches($content, '(?m)^AllowedIPs = (.+)$')
    if ($endpointMatches.Count -ne 1 -or $allowedMatches.Count -ne 1) { throw "Client profile has invalid endpoint/AllowedIPs lines: $Path" }
    $updated = $content.Replace($endpointMatches[0].Value, "Endpoint = $Endpoint").Replace($allowedMatches[0].Value, "AllowedIPs = $script:AdminClientAllowedIPs")
    if ($updated -ceq $content) { return }
    $profileDirectory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $profileDirectory ('.powerseven-profile-' + [guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $profileDirectory ('.powerseven-profile-backup-' + [guid]::NewGuid().ToString('N'))
    $rollbackPath = Join-Path $profileDirectory ('.powerseven-profile-rollback-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $updated, [System.Text.UTF8Encoding]::new($false))
        Set-RestrictedAcl -Path $temporaryPath -Directory $false
        try {
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
            Set-RestrictedAcl -Path $Path -Directory $false
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
        }
        catch {
            $updateFailure = $_.Exception.Message
            if (Test-Path -LiteralPath $backupPath) {
                try {
                    if (Test-Path -LiteralPath $Path) {
                        [System.IO.File]::Replace($backupPath, $Path, $rollbackPath)
                        if (Test-Path -LiteralPath $rollbackPath) {
                            Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction Stop
                        }
                    } else {
                        [System.IO.File]::Move($backupPath, $Path)
                    }
                }
                catch {
                    throw "Client profile update failed ($updateFailure); inspect '$Path', '$backupPath' and '$rollbackPath' to recover the original profile: $($_.Exception.Message)"
                }
            }
            throw
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    Write-Result 'PASS' 'admin-client-profile' "updated $(Split-Path -Leaf $Path) endpoint/routes without changing its private key"
}

function Test-DC02AdminState {
    param([string]$Endpoint, [array]$Peers)
    $ready = $true
    $underlay = Get-DC02UnderlayInterface
    foreach ($store in @('ActiveStore', 'PersistentStore')) {
        $routes = @(Get-NetRoute -DestinationPrefix '10.99.0.0/24' -PolicyStore $store -ErrorAction SilentlyContinue)
        if ($routes.Count -ne 1 -or $routes[0].NextHop -ne '192.168.214.14' -or $routes[0].InterfaceIndex -ne $underlay.InterfaceIndex) {
            Write-Result 'MISSING' 'dc02-route' "10.99.0.0/24 via 192.168.214.14 is absent or incorrect in $store"
            $ready = $false
        }
    }
    if (-not (Test-DC02RdpFirewall)) {
        Write-Result 'MISSING' 'dc02-rdp-firewall' 'managed RDP block/allow policy is absent or ineffective'
        $ready = $false
    }
    $clientDirectory = Join-Path $env:ProgramData 'PowerSeven\clients'
    $clientKeys = @()
    if ($Peers.Count -eq 0) { Write-Result 'MISSING' 'admin-client' 'peer inventory is empty'; $ready = $false }
    foreach ($peer in $Peers) {
        $path = Join-Path $clientDirectory ("powerseven-admin-{0}.conf" -f $peer.Name)
        if (-not (Test-AdminClientConfig -Path $path -Address $peer.Address -Endpoint $Endpoint)) {
            Write-Result 'MISSING' 'admin-client' "$($peer.Name) profile is missing or invalid at $path"
            $ready = $false
        } else {
            $content = Get-Content -LiteralPath $path -Raw
            $clientKeys += [regex]::Match($content, '(?m)^PrivateKey = (\S+)').Groups[1].Value
        }
    }
    if (@($clientKeys | Select-Object -Unique).Count -ne $clientKeys.Count) {
        Write-Result 'MISSING' 'admin-client' 'VPN profiles share a private key'
        $ready = $false
    }
    if ($ready) { Write-Result 'PASS' 'dc02-admin-state' 'route, RDP scope and distinct client profiles match CP3' }
    return $ready
}

function Test-LocalRdpFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $expected = "full address:s:192.168.214.13`r`nusername:s:LAB\Administrator`r`n"
    return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::ASCII) -ceq $expected)
}

function New-LocalRdpFile {
    param([string]$Directory)
    $path = Join-Path $Directory 'PowerSeven-DC02.rdp'
    [System.IO.File]::WriteAllText($path, "full address:s:192.168.214.13`r`nusername:s:LAB\Administrator`r`n", [System.Text.Encoding]::ASCII)
    Set-RestrictedAcl -Path $path -Directory $false
    if (-not (Test-LocalRdpFile -Path $path)) { throw 'Generated DC02 RDP profile failed validation' }
    return $path
}

function Copy-AdminDeliveryFile {
    param([string]$Source, [string]$Destination, [string]$Address = '', [string]$Endpoint = '')

    if (-not [System.IO.File]::Exists($Source)) { throw "Canonical delivery source is missing: $Source" }
    if ([string]::Equals([System.IO.Path]::GetFullPath($Source), [System.IO.Path]::GetFullPath($Destination), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Desktop delivery path resolves to the canonical source; refusing to overwrite it'
    }
    if ($Address) {
        if (-not (Test-AdminClientConfig -Path $Source -Address $Address -Endpoint $Endpoint)) { throw "Canonical client profile failed validation: $Source" }
    } elseif (-not (Test-LocalRdpFile -Path $Source)) {
        throw "Canonical RDP profile failed validation: $Source"
    }

    $destinationDirectory = Split-Path -Parent $Destination
    $temporaryPath = Join-Path $destinationDirectory ('.powerseven-delivery-' + [guid]::NewGuid().ToString('N'))
    try {
        $stream = [System.IO.File]::Create($temporaryPath)
        $stream.Dispose()
        Set-RestrictedAcl -Path $temporaryPath -Directory $false
        [System.IO.File]::WriteAllBytes($temporaryPath, [System.IO.File]::ReadAllBytes($Source))
        Set-RestrictedAcl -Path $temporaryPath -Directory $false
        if ($Address) {
            if (-not (Test-AdminClientConfig -Path $temporaryPath -Address $Address -Endpoint $Endpoint)) { throw "Staged client delivery copy failed validation: $Destination" }
        } elseif (-not (Test-LocalRdpFile -Path $temporaryPath)) {
            throw "Staged RDP delivery copy failed validation: $Destination"
        }

        if (Test-Path -LiteralPath $Destination) {
            $existing = Get-Item -LiteralPath $Destination -Force
            if ($existing.PSIsContainer -or (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw "Refusing to replace a non-file or reparse-point Desktop item: $Destination"
            }
            Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop
        }
        [System.IO.File]::Move($temporaryPath, $Destination)
        Set-RestrictedAcl -Path $Destination -Directory $false
        if ($Address) {
            if (-not (Test-AdminClientConfig -Path $Destination -Address $Address -Endpoint $Endpoint)) { throw "Desktop client delivery copy failed validation: $Destination" }
        } elseif (-not (Test-LocalRdpFile -Path $Destination)) {
            throw "Desktop RDP delivery copy failed validation: $Destination"
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

function Export-AdminArtifactsToDesktop {
    param([string]$ClientDirectory, [string]$RdpPath, [array]$Peers, [string]$Endpoint)

    $desktopDirectory = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::DesktopDirectory)
    if ([string]::IsNullOrWhiteSpace($desktopDirectory) -or -not (Test-Path -LiteralPath $desktopDirectory -PathType Container)) {
        throw 'The current Windows user Desktop path is unavailable'
    }
    $deliveryDirectory = Join-Path $desktopDirectory 'PowerSeven-Clients'
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $canonicalRoot = [System.IO.Path]::GetFullPath($ClientDirectory).TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
    $deliveryRoot = [System.IO.Path]::GetFullPath($deliveryDirectory).TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
    if ($deliveryRoot.StartsWith($canonicalRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The current user Desktop resolves inside the canonical client directory; refusing delivery'
    }

    if (Test-Path -LiteralPath $deliveryDirectory) {
        $directoryItem = Get-Item -LiteralPath $deliveryDirectory -Force
        if (-not $directoryItem.PSIsContainer -or (($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "PowerSeven Desktop delivery path is not a regular directory: $deliveryDirectory"
        }
    } else {
        New-Item -ItemType Directory -Path $deliveryDirectory -ErrorAction Stop | Out-Null
        Set-RestrictedAcl -Path $deliveryDirectory -Directory $true
    }

    $expectedFiles = @()
    foreach ($peer in $Peers) {
        $fileName = 'powerseven-admin-{0}.conf' -f $peer.Name
        $source = Join-Path $ClientDirectory $fileName
        if (-not [string]::Equals([System.IO.Path]::GetFullPath($peer.Path), [System.IO.Path]::GetFullPath($source), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Peer profile is outside the canonical client directory: $($peer.Name)"
        }
        $destination = Join-Path $deliveryDirectory $fileName
        Copy-AdminDeliveryFile -Source $source -Destination $destination -Address $peer.Address -Endpoint $Endpoint
        $expectedFiles += $fileName
    }

    $canonicalRdpPath = Join-Path $ClientDirectory 'PowerSeven-DC02.rdp'
    if (-not [string]::Equals([System.IO.Path]::GetFullPath($RdpPath), [System.IO.Path]::GetFullPath($canonicalRdpPath), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'RDP delivery source is outside the canonical client directory'
    }
    Copy-AdminDeliveryFile -Source $canonicalRdpPath -Destination (Join-Path $deliveryDirectory 'PowerSeven-DC02.rdp')

    $staleProfiles = @(Get-ChildItem -LiteralPath $deliveryDirectory -Filter 'powerseven-admin-*.conf' -File -ErrorAction Stop |
        Where-Object { $expectedFiles -notcontains $_.Name })
    foreach ($staleProfile in $staleProfiles) {
        Write-Result 'WARN' 'desktop-stale-profile' "left untouched because it is not in the current peer inventory: $($staleProfile.Name)"
    }
    Write-Result 'PASS' 'desktop-export' ("{0} validated delivery files copied to {1}; canonical files remain in {2}" -f ($Peers.Count + 1), $deliveryDirectory, $ClientDirectory)
}

$selectedModes = 0
if ($Check) { $selectedModes++ }
if ($Apply) { $selectedModes++ }
if ($PrepareBootstrap) { $selectedModes++ }
if ($selectedModes -ne 1) {
    throw 'Choose exactly one mode: -Check, -Apply or -PrepareBootstrap'
}
if ($PeerNames.Count -gt 0 -and (-not $Apply -or $Checkpoint -ne '3')) {
    throw '-PeerNames is valid only with -Apply -Checkpoint 3'
}

$bootstrapSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'linux\bootstrap.sh'
if (-not (Test-Path -LiteralPath $bootstrapSource -PathType Leaf)) {
    throw "Linux bootstrap source is missing: $bootstrapSource"
}
$bootstrapContractSource = Get-Content -LiteralPath $bootstrapSource -Raw
$bootstrapVersionMatches = [regex]::Matches($bootstrapContractSource, "(?m)^readonly POWERSEVEN_BOOTSTRAP_VERSION='([0-9]+)'\r?$")
$bootstrapCapabilitiesMatches = [regex]::Matches($bootstrapContractSource, "(?m)^readonly POWERSEVEN_BOOTSTRAP_CAPABILITIES='([0-9]+(,[0-9]+)*)'\r?$")
if ($bootstrapVersionMatches.Count -ne 1 -or $bootstrapCapabilitiesMatches.Count -ne 1) {
    throw 'Linux bootstrap must declare exactly one numeric version and checkpoint capability list'
}
$requiredBootstrapVersion = $bootstrapVersionMatches[0].Groups[1].Value
$bootstrapCapabilities = $bootstrapCapabilitiesMatches[0].Groups[1].Value
$requiredBootstrapCapabilities = "checkpoints=$bootstrapCapabilities"

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
$targetHostKeyAlias = ''

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
    if (Test-SshKeyAuthentication -SshPath $script:Ssh -KeyPath $keyPath -Target $staticTarget -HostKeyAlias $Vps14Address) {
        Write-Result 'PASS' 'vps14-address' 'existing static VPS14 address 192.168.214.14 selected'
        $targetHostKeyAlias = $Vps14Address
        $Vps14Address = '192.168.214.14'
        $target = $staticTarget
    }
}

$keyOnlySshOptions = @(
    '-o', 'BatchMode=yes',
    '-o', 'PasswordAuthentication=no',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'ConnectTimeout=10',
    '-o', 'ServerAliveInterval=5',
    '-o', 'ServerAliveCountMax=2',
    '-i', $keyPath
)
if (-not [string]::IsNullOrWhiteSpace($targetHostKeyAlias)) {
    $keyOnlySshOptions += @('-o', "HostKeyAlias=$targetHostKeyAlias")
}

if ($Check) {
    Write-Result 'INFO' 'ssh-key-auth' 'validating key-only access and bootstrap protocol in one remote probe'
    $bootstrapProbe = Test-ExistingBootstrapInstallation -SshPath $script:Ssh -KeyPath $keyPath -Target $target -RequiredVersion $requiredBootstrapVersion -RequiredCapabilities $requiredBootstrapCapabilities -HostKeyAlias $targetHostKeyAlias -RequiredCheckpoint $Checkpoint
    if (-not $bootstrapProbe.Authenticated -and $Vps14Address -eq '192.168.214.14' -and [string]::IsNullOrWhiteSpace($targetHostKeyAlias)) {
        $bootstrapProbe = Test-ExistingBootstrapInstallation -SshPath $script:Ssh -KeyPath $keyPath -Target $target -RequiredVersion $requiredBootstrapVersion -RequiredCapabilities $requiredBootstrapCapabilities -HostKeyAlias '192.168.214.145' -RequiredCheckpoint $Checkpoint
        if ($bootstrapProbe.Authenticated) {
            $targetHostKeyAlias = '192.168.214.145'
            $keyOnlySshOptions += @('-o', "HostKeyAlias=$targetHostKeyAlias")
            Write-Result 'PASS' 'vps14-hostkey' 'static address verified against the trusted DHCP host identity'
        }
    }
    if (-not $bootstrapProbe.Authenticated) {
        Write-Result 'FAIL' 'ssh-key-auth' 'key-only SSH authentication or host identity verification failed'
        exit 1
    }
    Write-Result 'PASS' 'ssh-key-auth' 'key-only authentication succeeded'
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
        if ($Checkpoint -eq '3') {
            $adminPeers = @(Get-RemoteAdminPeers -Target $target -SshOptions $keyOnlySshOptions)
            $endpoint = Get-RemoteAdminEndpoint -Target $target -SshOptions $keyOnlySshOptions
            if (-not (Test-DC02AdminState -Endpoint $endpoint -Peers $adminPeers)) { exit 10 }
        }
        exit 0
    }
    if ($remoteCheck.HasRemediation) {
        Write-Result 'WARN' 'checkpoint' 'remote check completed; remediation is required and no mutation was performed'
        exit 10
    }
    Write-Result 'FAIL' 'checkpoint' ("remote read-only check failed with exit code {0}" -f $remoteCheck.ExitCode)
    exit 1
}

Write-Result 'INFO' 'ssh-key-auth' 'probing existing key-only authentication; no password prompt expected'
$sshKeyAuthentication = Test-SshKeyAuthentication -SshPath $script:Ssh -KeyPath $keyPath -Target $target -HostKeyAlias $targetHostKeyAlias
if (-not $sshKeyAuthentication -and $Vps14Address -eq '192.168.214.14' -and [string]::IsNullOrWhiteSpace($targetHostKeyAlias)) {
    if (Test-SshKeyAuthentication -SshPath $script:Ssh -KeyPath $keyPath -Target $target -HostKeyAlias '192.168.214.145') {
        $targetHostKeyAlias = '192.168.214.145'
        $sshKeyAuthentication = $true
        Write-Result 'PASS' 'vps14-hostkey' 'static address verified against the trusted DHCP host identity'
    }
}
if (-not $sshKeyAuthentication) {
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
        $enrollmentSshOptions = @(
            '-tt',
            '-o', 'PreferredAuthentications=password',
            '-o', 'PubkeyAuthentication=no',
            '-o', 'ConnectTimeout=10'
        )
        if (-not [string]::IsNullOrWhiteSpace($targetHostKeyAlias)) {
            $enrollmentSshOptions += @('-o', "HostKeyAlias=$targetHostKeyAlias")
        }
        Invoke-NativeInteractive $script:Ssh ($enrollmentSshOptions + @($target, $enrollCommand))
    }
    catch {
        throw ('SSH enrollment failed; no remote mutation was attempted unless SSH authentication succeeded: {0}' -f $_.Exception.Message)
    }

    if (-not (Test-SshKeyAuthentication -SshPath $script:Ssh -KeyPath $keyPath -Target $target -HostKeyAlias $targetHostKeyAlias)) {
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
            Invoke-NativeInteractive $script:Ssh ($enrollmentSshOptions + @($target, $rollbackCommand))
        }
        catch {
            throw ('SSH enrollment failed and rollback could not be confirmed: {0}' -f $_.Exception.Message)
        }
        throw 'SSH enrollment failed; PowerSeven key rolled back'
    }

    $cleanupEnrollmentCommand = 'rm -f "$HOME/.ssh/{0}" "$HOME/.ssh/{1}"' -f $enrollmentBackupName, $enrollmentMarkerName
    $cleanupEnrollmentCommand = ConvertTo-LinuxLf -Name 'SSH enrollment cleanup command' -Content $cleanupEnrollmentCommand
    Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target, $cleanupEnrollmentCommand))
    $sshKeyAuthentication = $true
    Write-Result 'PASS' 'ssh-enrollment' 'key-only authentication verified'
}
Write-Result 'PASS' 'ssh-key-auth' 'key-only authentication succeeded'

$temporaryFiles = $null
$remoteStageDir = $null
$localRouteState = $null
$remoteClientStaged = $false
try {
    $bootstrapProbe = Test-ExistingBootstrapInstallation -SshPath $script:Ssh -KeyPath $keyPath -Target $target -RequiredVersion $requiredBootstrapVersion -RequiredCapabilities $requiredBootstrapCapabilities -HostKeyAlias $targetHostKeyAlias -RequiredCheckpoint $Checkpoint
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

        $temporaryFiles = New-RemoteBootstrapFiles -Username $UbuntuUsername -BootstrapContent $bootstrapContractSource
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
expected_protocol="$(printf 'powerseven-bootstrap %s\ncheckpoints=%s' '__BOOTSTRAP_VERSION__' '__BOOTSTRAP_CAPABILITIES__')"
test "$(sudo "$wrapper" --protocol)" = "$expected_protocol"
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
        $installCommand = $installCommand.Replace('__STAGE__', $remoteStageDir).Replace('__BACKUP__', $remoteBackupDir).Replace('__BOOTSTRAP_VERSION__', $requiredBootstrapVersion).Replace('__BOOTSTRAP_CAPABILITIES__', $bootstrapCapabilities)
        $installCommand = ConvertTo-LinuxLf -Name 'privileged bootstrap transaction' -Content $installCommand
        $transactionPath = Join-Path $temporaryFiles[0] 'powerseven-install-transaction.sh'
        [System.IO.File]::WriteAllText($transactionPath, $installCommand, [System.Text.UTF8Encoding]::new($false))
        Assert-LinuxPayloadLf -Name 'staged privileged bootstrap transaction' -Content ([System.IO.File]::ReadAllText($transactionPath))
        Invoke-Native $script:Scp ($keyOnlySshOptions + @($transactionPath, ($target + ':' + $remoteStageDir + '/powerseven-install-transaction.sh')))
        $remoteTransactionCommand = ConvertTo-LinuxLf -Name 'privileged bootstrap transaction launcher' -Content ('bash "{0}/powerseven-install-transaction.sh"' -f $remoteStageDir)
        try {
            Invoke-NativeInteractive $script:Ssh (@('-tt') + $keyOnlySshOptions + @($target, $remoteTransactionCommand))
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
    }

    $action = if ($Apply) { '--apply' } else { '--check' }
    Write-Result 'INFO' 'checkpoint' ("mode={0} checkpoint={1}" -f $action.TrimStart('-'), $Checkpoint)

    if ($Checkpoint -eq '2' -and $Apply) {
        $originalAddress = $Vps14Address
        $originalHostKeyAlias = $targetHostKeyAlias
        $networkCheckArguments = @(New-RemoteCheckpointArguments -Action '--check' -Checkpoint '2')
        Write-Result 'INFO' 'checkpoint' 'checking current network state before opening a DHCP-to-static transaction'
        $networkCheck = Invoke-NativeReadOnly $script:Ssh ($keyOnlySshOptions + @($target) + $networkCheckArguments)
        if ($networkCheck.ExitCode -eq 0 -and -not $networkCheck.HasRemediation) {
            Write-Result 'PASS' 'network' 'VPS14 network already matches the CP2 target; no transition required'
            exit 0
        }
        if (-not $networkCheck.HasRemediation) {
            throw "VPS14 CP2 read-only check failed with exit code $($networkCheck.ExitCode); refusing to start a network transaction"
        }

        $networkToken = [guid]::NewGuid().ToString('N')
        $remoteCheckpointArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '2' -ExtraOption '--network-token' -ExtraValue $networkToken)
        Write-Result 'INFO' 'checkpoint' 'network transition may close the current SSH session'
        Write-Result 'INFO' 'checkpoint' 'remote command=sudo -n /usr/local/sbin/powerseven-bootstrap --apply --checkpoint 2 --network-token <redacted>'
        $transitionResult = Invoke-NativeBounded $script:Ssh ($keyOnlySshOptions + @($target) + $remoteCheckpointArguments) -TimeoutSeconds 15
        Write-NativeResultOutput -Result $transitionResult
        if ($transitionResult.TimedOut) {
            Write-Result 'WARN' 'checkpoint' 'network transition SSH session exceeded its bounded handoff window; validating the static address'
        } elseif ($transitionResult.ExitCode -ne 0) {
            Write-Result 'WARN' 'checkpoint' ("network transition SSH session ended with exit code {0}; validating the static address" -f $transitionResult.ExitCode)
        }

        $Vps14Address = '192.168.214.14'
        $target = '{0}@{1}' -f $UbuntuUsername, $Vps14Address
        $targetHostKeyAlias = if ($originalAddress -eq '192.168.214.14') { $originalHostKeyAlias } else { $originalAddress }
        $keyOnlySshOptions = @(
            '-o', 'BatchMode=yes',
            '-o', 'PasswordAuthentication=no',
            '-o', 'IdentitiesOnly=yes',
            '-o', 'ConnectTimeout=10',
            '-o', 'ServerAliveInterval=5',
            '-o', 'ServerAliveCountMax=2',
            '-i', $keyPath
        )
        if (-not [string]::IsNullOrWhiteSpace($targetHostKeyAlias)) {
            $keyOnlySshOptions += @('-o', "HostKeyAlias=$targetHostKeyAlias")
        }

        $staticReachable = $false
        $staticFailure = $null
        try {
            $staticReachable = Wait-ForVps14Ssh -SshPath $script:Ssh -KeyPath $keyPath -Address $Vps14Address -Username $UbuntuUsername -HostKeyAlias $targetHostKeyAlias -TimeoutSeconds 60 -IntervalSeconds 2
        }
        catch {
            $staticFailure = $_.Exception.Message
        }
        if (-not $staticReachable) {
            $rollbackReachable = $false
            $rollbackFailure = $null
            try {
                $rollbackReachable = Wait-ForVps14Ssh -SshPath $script:Ssh -KeyPath $keyPath -Address $originalAddress -Username $UbuntuUsername -HostKeyAlias $originalHostKeyAlias -TimeoutSeconds 20 -IntervalSeconds 2
            }
            catch {
                $rollbackFailure = $_.Exception.Message
            }
            if ($null -ne $staticFailure) {
                if ($rollbackReachable) {
                    throw ("{0}; rollback restored {1}" -f $staticFailure, $originalAddress)
                }
                throw ("{0}; rollback address {1} was not reachable within the bounded recovery window" -f $staticFailure, $originalAddress)
            }
            if ($rollbackReachable) {
                throw ("VPS14 static address did not become reachable before timeout; rollback restored {0}" -f $originalAddress)
            }
            if ($null -ne $rollbackFailure) {
                throw ("VPS14 static address did not become reachable before timeout; rollback verification failed: {0}" -f $rollbackFailure)
            }
            throw ("VPS14 static address did not become reachable before timeout; rollback address {0} was not reachable within the bounded recovery window" -f $originalAddress)
        }

        $confirmArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '2' -ExtraOption '--confirm-network' -ExtraValue $networkToken)
        Write-Result 'INFO' 'checkpoint' 'remote command=sudo -n /usr/local/sbin/powerseven-bootstrap --apply --checkpoint 2 --confirm-network <redacted>'
        $confirmResult = Invoke-NativeBounded $script:Ssh ($keyOnlySshOptions + @($target) + $confirmArguments) -TimeoutSeconds 75
        Write-NativeResultOutput -Result $confirmResult
        if ($confirmResult.TimedOut) {
            throw 'VPS14 network confirmation exceeded the bounded timeout; rollback guard remains active'
        }
        if ($confirmResult.ExitCode -ne 0) {
            throw "VPS14 network confirmation failed with exit code $($confirmResult.ExitCode); rollback guard remains active"
        }
        if ($originalAddress -eq '192.168.214.145') {
            Write-Result 'PASS' 'network' 'DHCP .145 to static .14 transition confirmed'
        } else {
            Write-Result 'PASS' 'network' 'VPS14 CP2 network transaction confirmed'
        }
    } elseif ($Checkpoint -eq '3' -and $Apply) {
        $clientDirectory = Join-Path $env:ProgramData 'PowerSeven\clients'
        $existingPeers = @(Get-RemoteAdminPeers -Target $target -SshOptions $keyOnlySshOptions)
        $chosenNames = @(Resolve-AdminPeerNames -ExistingPeers $existingPeers -RequestedNames $PeerNames)
        if ($existingPeers.Count -eq 0) {
            foreach ($name in $chosenNames) {
                $existingPath = Join-Path $clientDirectory ("powerseven-admin-{0}.conf" -f $name)
                if (Test-Path -LiteralPath $existingPath) {
                    throw "Local profile already exists for $name without a VPS14 identity; explicit recovery or rotation is required"
                }
            }
        }
        $applyArguments = if ($existingPeers.Count -eq 0) {
            @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '3' -ExtraOption '--peer-list' -ExtraValue ($chosenNames -join ','))
        } else {
            @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '3')
        }
        Write-Result 'INFO' 'checkpoint' ("remote command={0}" -f ($applyArguments -join ' '))
        Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $applyArguments)
        $adminPeers = @(Get-RemoteAdminPeers -Target $target -SshOptions $keyOnlySshOptions)
        if ((@($adminPeers | ForEach-Object { $_.Name }) -join ',') -cne ($chosenNames -join ',')) {
            throw 'VPS14 peer inventory differs from the selected names after apply'
        }
        foreach ($peer in $adminPeers) {
            $peer.Path = Join-Path $clientDirectory ("powerseven-admin-{0}.conf" -f $peer.Name)
            $peer.LocalExists = Test-Path -LiteralPath $peer.Path -PathType Leaf
            if ($peer.LocalExists) {
                Set-RestrictedAcl -Path $peer.Path -Directory $false
                if (-not (Test-AdminClientConfig -Path $peer.Path -Address $peer.Address -AllowLegacyRoutes)) {
                    throw "existing $($peer.Name) config is invalid; explicit rotation is required"
                }
            }
            $peer.RemoteExists = $peer.Status -ne 'absent'
            $peer.Staged = $peer.Status -eq 'staged'
            if ($peer.LocalExists -and -not $peer.RemoteExists) {
                throw "$($peer.Name) local config exists but remote public identity is missing; explicit rotation is required"
            }
            if (-not $peer.LocalExists -and $peer.RemoteExists -and -not $peer.Staged) {
                throw "$($peer.Name) private config is lost; explicit rotation is required"
            }
        }
        foreach ($peer in $adminPeers) {
            if (-not $peer.LocalExists) {
                $temporaryClientPath = Join-Path $clientDirectory ('.powerseven-admin-' + $peer.Name + '.' + [guid]::NewGuid().ToString('N'))
                try {
                    $remoteClientPath = '{0}:/tmp/powerseven-admin-{1}.conf' -f $target, $peer.Name
                    Invoke-Native $script:Scp ($keyOnlySshOptions + @($remoteClientPath, $temporaryClientPath))
                    Set-RestrictedAcl -Path $temporaryClientPath -Directory $false
                    if (-not (Test-AdminClientConfig -Path $temporaryClientPath -Address $peer.Address -AllowLegacyRoutes)) {
                        throw "downloaded $($peer.Name) config failed structural validation"
                    }
                    Move-Item -LiteralPath $temporaryClientPath -Destination $peer.Path
                } finally {
                    if (Test-Path -LiteralPath $temporaryClientPath) { Remove-Item -LiteralPath $temporaryClientPath -Force }
                }
                Write-Result 'PASS' 'admin-client' "$($peer.Name) config exported to $($peer.Path)"
            } else {
                Write-Result 'PASS' 'admin-client' "$($peer.Name) identity/config reused"
            }
        }
        $endpoint = Get-RemoteAdminEndpoint -Target $target -SshOptions $keyOnlySshOptions
        foreach ($peer in $adminPeers) {
            Update-AdminClientProfile -Path $peer.Path -Endpoint $endpoint
            if (-not (Test-AdminClientConfig -Path $peer.Path -Address $peer.Address -Endpoint $endpoint)) {
                throw "$($peer.Name) config does not match the current VPS14 endpoint"
            }
        }
        $privateKeys = @($adminPeers | ForEach-Object {
            $content = Get-Content -LiteralPath $_.Path -Raw
            [regex]::Match($content, '(?m)^PrivateKey = (\S+)').Groups[1].Value
        })
        if (@($privateKeys | Select-Object -Unique).Count -ne $privateKeys.Count) { throw 'admin VPN peers share a private key; explicit rotation is required' }
        foreach ($peer in $adminPeers) {
            $cleanupArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '3' -ExtraOption '--cleanup-client' -ExtraValue $peer.Name)
            Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $cleanupArguments)
        }
        $rdpPath = New-LocalRdpFile -Directory $clientDirectory
        Write-Result 'PASS' 'dc02-rdp' "RDP profile created at $rdpPath without credentials"
        $localRouteState = Ensure-DC02AdminRoute
        Ensure-DC02RdpFirewall
        if (-not (Test-DC02AdminState -Endpoint $endpoint -Peers $adminPeers)) { throw 'DC02 administrative VPN state failed final validation' }
        $localRouteState.Added = $false
        Write-Result 'PASS' 'admin-vpn' 'WireGuard administrative VPN checkpoint completed'
        try {
            Export-AdminArtifactsToDesktop -ClientDirectory $clientDirectory -RdpPath $rdpPath -Peers $adminPeers -Endpoint $endpoint
        }
        catch {
            throw "CP3 network state passed and canonical files remain in '$clientDirectory', but Desktop delivery failed; rerun Apply to retry: $($_.Exception.Message)"
        }
    } else {
        $remoteCheckpointArguments = @(New-RemoteCheckpointArguments -Action $action -Checkpoint $Checkpoint)
        Write-Result 'INFO' 'checkpoint' ("remote command={0}" -f ($remoteCheckpointArguments -join ' '))
        Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $remoteCheckpointArguments)
        Write-Result 'PASS' 'powerseven-bootstrap' "$action --checkpoint $Checkpoint completed"
    }
}
catch {
    # Unexported staged client secrets remain for a safe retry; never rotate silently.
    # Keep any managed RDP block in place on failure; a rerun completes the allow rule.
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
