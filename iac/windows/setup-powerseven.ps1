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
$requiredBootstrapVersion = '10'
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
        if ($ExtraValue -notin @('jarvis', 'giorgio-laptop')) { throw 'Unknown admin VPN peer' }
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
        [string]$BootstrapSource
    )

    $wrapper = @'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 1 && ( "$1" == '--version' || "$1" == '--capabilities' || "$1" == '--protocol' || "$1" == '--peer-status' ) ]]; then
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
        if [[ "$4" != '--cleanup-client' || "$5" != 'jarvis' && "$5" != 'giorgio-laptop' ]]; then
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
    param([string]$Path, [string]$Address)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $content = Get-Content -LiteralPath $Path -Raw
    return ($content -match '(?m)^\[Interface\]$' -and
        $content -match ("(?m)^Address = {0}$" -f [regex]::Escape($Address)) -and
        $content -match '(?m)^\[Peer\]$' -and
        $content -match '(?m)^AllowedIPs = 192\.168\.214\.0/24$' -and
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
$localFirewallState = $null
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
test "$(sudo "$wrapper" --protocol)" = "$(printf 'powerseven-bootstrap 10\ncheckpoints=1,2,3')"
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
        $localRouteState = Ensure-DC02AdminRoute
        $localFirewallState = Ensure-DC02RdpFirewall
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
        $adminPeers = @(
            @{ Name = 'jarvis'; Address = '10.99.0.2/32' },
            @{ Name = 'giorgio-laptop'; Address = '10.99.0.3/32' }
        )
        $peerStatusResult = Invoke-NativeCapture $script:Ssh ($keyOnlySshOptions + @($target, 'sudo', '-n', '/usr/local/sbin/powerseven-bootstrap', '--peer-status'))
        if ($peerStatusResult.ExitCode -ne 0) { throw 'remote admin VPN peer-state probe failed' }
        $peerStatusText = $peerStatusResult.StandardOutput.Replace("`r", '').Trim()
        $expectedPeerStatus = "jarvis=(absent|staged|exported)`ngiorgio-laptop=(absent|staged|exported)"
        if ($peerStatusText -notmatch ("\A{0}\z" -f $expectedPeerStatus)) {
            throw 'remote admin VPN peer-state protocol is invalid'
        }
        $peerStatuses = @{}
        foreach ($line in ($peerStatusText -split "`n")) {
            $parts = $line.Trim() -split '=', 2
            $peerStatuses[$parts[0]] = $parts[1]
        }
        foreach ($peer in $adminPeers) {
            $peer.Path = Join-Path $clientDirectory ("powerseven-admin-{0}.conf" -f $peer.Name)
            $peer.LocalExists = Test-Path -LiteralPath $peer.Path -PathType Leaf
            if ($peer.LocalExists) {
                Set-RestrictedAcl -Path $peer.Path -Directory $false
                if (-not (Test-AdminClientConfig -Path $peer.Path -Address $peer.Address)) {
                    throw "existing $($peer.Name) config is invalid; explicit rotation is required"
                }
            }
            $peer.RemoteExists = $peerStatuses[$peer.Name] -ne 'absent'
            $peer.Staged = $peerStatuses[$peer.Name] -eq 'staged'
            if ($peer.LocalExists -and -not $peer.RemoteExists) {
                throw "$($peer.Name) local config exists but remote public identity is missing; explicit rotation is required"
            }
            if (-not $peer.LocalExists -and $peer.RemoteExists -and -not $peer.Staged) {
                throw "$($peer.Name) private config is lost; explicit rotation is required"
            }
        }
        $applyArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '3')
        Write-Result 'INFO' 'checkpoint' ("remote command={0}" -f ($applyArguments -join ' '))
        Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $applyArguments)
        foreach ($peer in $adminPeers) {
            if (-not $peer.LocalExists) {
                $temporaryClientPath = Join-Path $clientDirectory ('.powerseven-admin-' + $peer.Name + '.' + [guid]::NewGuid().ToString('N'))
                try {
                    Invoke-Native $script:Scp ($keyOnlySshOptions + @($target + ":/tmp/powerseven-admin-$($peer.Name).conf", $temporaryClientPath))
                    Set-RestrictedAcl -Path $temporaryClientPath -Directory $false
                    if (-not (Test-AdminClientConfig -Path $temporaryClientPath -Address $peer.Address)) {
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
        $privateKeys = @($adminPeers | ForEach-Object {
            $content = Get-Content -LiteralPath $_.Path -Raw
            [regex]::Match($content, '(?m)^PrivateKey = (\S+)').Groups[1].Value
        })
        if ($privateKeys[0] -eq $privateKeys[1]) { throw 'admin VPN peers share a private key; explicit rotation is required' }
        foreach ($peer in $adminPeers) {
            $cleanupArguments = @(New-RemoteCheckpointArguments -Action '--apply' -Checkpoint '3' -ExtraOption '--cleanup-client' -ExtraValue $peer.Name)
            Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $cleanupArguments)
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
    # Unexported staged client secrets remain for a safe retry; never rotate silently.
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
