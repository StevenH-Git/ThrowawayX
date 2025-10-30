# Requirements & Notes
<# 
=== LAB USE ONLY ===

****** MINIMALLY HARDENED ******

Requires:
- Windows 10/11 with OpenSSH client in PATH (ssh, scp, ssh-keygen) (Add-WindowsCapability 'google it')
- PowerShell 5.1+
- Posh-SSH 3.2.4+ module (script auto-installs if missing) may require a restart of the script
- NuGet module, if it prompts to download and install then do it, ctrl+c out of the script and start over.
- IPv4 targets (Linux Workers and Control Nodes) #no IPv6 support

What it does per host:
1) Connects with a service account and password.
2) Enables root SSH login and pubkey auth.
3) Creates /root/.ssh and installs your local public key.
4) Sets root to passwordless sudo via a sudoers drop-in.
5) Sets the root password to the value you provide.
6) Restarts the SSH service.
7) Verifies key-based root SSH works.
8) Cache each host's SSH fingerprint

Edit at your own risk. This modifies sshd and sudoers.

=== LAB USE ONLY ===
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure Posh-SSH
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
  Install-Module -Name Posh-SSH -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module -Name Posh-SSH -ErrorAction Stop

function Read-Ip {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Label,
    [string[]]$Used = @()
  )
  $ipv4Regex = '^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)$'
  while ($true) {
    $raw = Read-Host "$Label IP"
    $ip = $raw.Trim()
    if ($ip -notmatch $ipv4Regex) { Write-Output 'Invalid IPv4. Example: 192.168.1.10'; continue }
    if ($Used -contains $ip)      { Write-Output 'Duplicate IP not allowed. Enter a different IP.'; continue }
    return $ip
  }
}

function ConvertTo-PlainText {
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Read-ConfirmedSecret {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Label)
  while ($true) {
    $p1 = Read-Host "Enter $Label" -AsSecureString
    $p2 = Read-Host "Re-enter $Label" -AsSecureString
    if ((ConvertTo-PlainText $p1) -ceq (ConvertTo-PlainText $p2)) { return $p1 }
    Write-Output 'Mismatch. Try again.'
  }
}

# ssh-keygen invocation avoids empty-arg bug and handles missing .pub
function Initialize-LocalSshKey {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$PrivKeyPath)

  $pub    = "$PrivKeyPath.pub"
  $sshgen = (Get-Command -Name ssh-keygen -ErrorAction Stop).Source

  if ((Test-Path -LiteralPath $PrivKeyPath -PathType Leaf) -and -not (Test-Path -LiteralPath $pub -PathType Leaf)) {
    $pubText = & $sshgen -y -f $PrivKeyPath
    if ($LASTEXITCODE -ne 0 -or -not $pubText) { throw "ssh-keygen -y failed for $PrivKeyPath" }
    Set-Content -LiteralPath $pub -Value $pubText -NoNewline -Encoding ascii
    return
  }
  if ((Test-Path -LiteralPath $PrivKeyPath -PathType Leaf) -and (Test-Path -LiteralPath $pub -PathType Leaf)) { return }

  function Invoke-Keygen([string]$argString) {
    $p = Start-Process -FilePath $sshgen -ArgumentList $argString -NoNewWindow -PassThru -Wait
    if ($p.ExitCode -ne 0) { throw "ssh-keygen failed: $argString (exit $($p.ExitCode))" }
    if (-not (Test-Path -LiteralPath $pub -PathType Leaf)) { throw "Public key not created at $pub" }
  }
  $privEsc = $PrivKeyPath.Replace('"','\"')
  try { Invoke-Keygen ("-q -t ed25519 -N """" -f ""$privEsc""") }
  catch {
    Write-Output 'Ed25519 failed. Falling back to RSA 4096.'
    Invoke-Keygen ("-q -t rsa -b 4096 -N """" -f ""$privEsc""")
  }
}

# Prefer SCP/SFTP cmdlets in Posh-SSH 3.2.4; fallback to SSH.NET SFTP
function Upload-RemoteFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Ip,
    [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)][string]$LocalPath,
    [Parameter(Mandatory)][string]$RemoteDir,     # directory only, e.g. /tmp
    [Parameter(Mandatory)][string]$SvcPassPlain
  )

  $fileName = [IO.Path]::GetFileName($LocalPath)
  $remoteFull = ($RemoteDir.TrimEnd('/')) + '/' + $fileName

  $scpItem = Get-Command -Name Set-SCPItem -Module Posh-SSH -ErrorAction SilentlyContinue
  if ($scpItem) {
    Set-SCPItem -ComputerName $Ip `
                -Credential  $Credential `
                -Path        $LocalPath `
                -Destination $RemoteDir `
                -AcceptKey `
                -Force
    return $remoteFull
  }

  $sftpItem = Get-Command -Name Set-SFTPItem -Module Posh-SSH -ErrorAction SilentlyContinue
  if ($sftpItem) {
    $sftp = New-SFTPSession -ComputerName $Ip -Credential $Credential -AcceptKey
    try {
      Set-SFTPItem -SessionId   $sftp.SessionId `
                   -Path        $LocalPath `
                   -Destination $remoteFull `
                   -Force
    } finally {
      if ($sftp) { $null = Remove-SFTPSession -SessionId $sftp.SessionId }
    }
    return $remoteFull
  }

  # Fallback: SSH.NET SFTP
  Add-Type -AssemblyName Renci.SshNet -ErrorAction SilentlyContinue
  $conn   = New-Object Renci.SshNet.PasswordConnectionInfo($Ip, $Credential.UserName, $SvcPassPlain)
  $client = New-Object Renci.SshNet.SftpClient($conn)
  try {
    $client.Connect()
    $fs = [System.IO.File]::OpenRead($LocalPath)
    try { $client.UploadFile($fs, $remoteFull, $true) }
    finally { $fs.Dispose() }
  } finally {
    if ($client) { $client.Dispose() }
  }
  return $remoteFull
}

# Seed known_hosts using OpenSSH itself (accept-new). Fallback to ssh-keyscan if needed.
function Seed-KnownHost {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Ip,
    [Parameter(Mandatory)][string]$PrivKeyPath
  )

  $ssh    = (Get-Command -Name ssh         -ErrorAction Stop).Source
  $sshgen = (Get-Command -Name ssh-keygen  -ErrorAction Stop).Source
  $scan   = (Get-Command -Name ssh-keyscan -ErrorAction SilentlyContinue).Source

  # Ensure user known_hosts exists
  $sshDir = Join-Path $env:USERPROFILE '.ssh'
  if (-not (Test-Path -LiteralPath $sshDir)) { $null = New-Item -ItemType Directory -Path $sshDir -Force }
  $knownHosts = Join-Path $sshDir 'known_hosts'
  if (-not (Test-Path -LiteralPath $knownHosts)) { $null = New-Item -ItemType File -Path $knownHosts -Force }

  # Best-effort: remove stale entries (doesn't error if none)
  try { & $sshgen -R $Ip 1>$null 2>$null } catch {}
  try { & $sshgen -R "[$Ip]:22" 1>$null 2>$null } catch {}

  # 1) Primary: let OpenSSH add the key itself, non-interactively
  # -o StrictHostKeyChecking=accept-new: automatically accept & write new host key
  # -o BatchMode=yes: do not prompt for anything (fail if it would)
  # -i <key>: use our freshly created key
  # -n true: no stdin, run a no-op command
  $args = @('-o','StrictHostKeyChecking=accept-new','-o','BatchMode=yes','-i', $PrivKeyPath,'-p','22','-n','root@{0}' -f $Ip,'true')
  $p = Start-Process -FilePath $ssh -ArgumentList $args -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -eq 0 -or (Test-Path -LiteralPath $knownHosts -PathType Leaf)) {
    return $true
  }

  # 2) Fallback: ssh-keyscan (if available)
  if ($scan) {
    $lines = & $scan $Ip 2>$null
    if ($lines) {
      # Also add [ip]:22 form for completeness
      $br = (& $scan -p 22 $Ip 2>$null)
      $all = @()
      $all += ($lines -split "`r?`n") | Where-Object { $_ -and ($_ -notmatch '^\s*#') }
      $all += ($br    -split "`r?`n") | Where-Object { $_ -and ($_ -notmatch '^\s*#') }
      $all = $all | Sort-Object -Unique
      if ($all.Count -gt 0) {
        Add-Content -LiteralPath $knownHosts -Value ($all -join [Environment]::NewLine)
        try { & $sshgen -H -f $knownHosts 1>$null 2>$null } catch {}
        return $true
      }
    }
  }

  return $false
}

# Quote helper for remote shell
Add-Type -TypeDefinition @"
using System;
public static class Quote {
  public static string Single(string s) {
    if (string.IsNullOrEmpty(s)) return "''";
    return "'" + s.Replace("'", "'\"'\"'") + "'";
  }
}
"@ -ErrorAction Stop

function Invoke-Sudo {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $SshSession,
    [Parameter(Mandatory)][string]$CommandText,
    [Parameter(Mandatory)][string]$SvcPassword
  )
  $wrapped = 'echo ' + [Regex]::Escape($SvcPassword) + ' | sudo -S -p "" bash -lc ' + [Quote]::Single($CommandText)
  Invoke-SSHCommand -SSHSession $SshSession -Command $wrapped
}

# -------- Inputs --------
$svcUser     = Read-Host 'Enter service account username (non-root)'
$svcPassSec  = Read-ConfirmedSecret 'service account password'
$rootPassSec = Read-ConfirmedSecret 'root password to set on targets'

# IPv4s (unique)
$ips = @()
$ips += Read-Ip -Label 'Control node 1' -Used $ips
$ips += Read-Ip -Label 'Control node 2' -Used $ips
$ips += Read-Ip -Label 'Control node 3' -Used $ips
$ips += Read-Ip -Label 'Worker node 1'  -Used $ips
$ips += Read-Ip -Label 'Worker node 2'  -Used $ips
$ips += Read-Ip -Label 'Worker node 3'  -Used $ips

# Summary and confirmation
Write-Output ''
Write-Output 'Summary'
Write-Output ("Service account: {0}" -f $svcUser)
Write-Output ("Control nodes: {0}, {1}, {2}" -f $ips[0], $ips[1], $ips[2])
Write-Output ("Worker nodes : {0}, {1}, {2}" -f $ips[3], $ips[4], $ips[5])
Write-Output ''
while ($true) {
  $resp = (Read-Host 'Type YES to continue or EXIT to quit').Trim().ToUpperInvariant()
  if     ($resp -eq 'YES')  { break }
  elseif ($resp -eq 'EXIT') { Write-Output 'Exiting.'; exit 0 }
  else { Write-Output 'Enter YES or EXIT' }
}

# Secrets to plain
$svcPass  = ConvertTo-PlainText $svcPassSec
$rootPass = ConvertTo-PlainText $rootPassSec

# Local SSH key
$sshDir = Join-Path $env:USERPROFILE '.ssh'
if (-not (Test-Path -LiteralPath $sshDir)) { $null = New-Item -ItemType Directory -Path $sshDir -Force }
$privKey = Join-Path $sshDir 'id_ed25519'
Initialize-LocalSshKey -PrivKeyPath $privKey
$pubKey  = "$privKey.pub"
$pubKeyData = Get-Content -LiteralPath $pubKey -Raw

# -------- Remote configuration --------
$results = @()

foreach ($ip in $ips) {
  Write-Output ("=== {0} ===" -f $ip)

  $cred = New-Object System.Management.Automation.PSCredential ($svcUser, $svcPassSec)
  $session  = $null
  $tmpLocal = $null

  try {
    $session = New-SSHSession -ComputerName $ip -Credential $cred -AcceptKey -KeepAliveInterval 15
    if (-not $session -or -not $session.Session.IsConnected) { throw 'SSH session not connected' }

    # Upload public key file into /tmp, get the exact remote filename
    $remoteDir = '/tmp'
    $tmpLocal  = New-TemporaryFile
    Set-Content -LiteralPath $tmpLocal -Value $pubKeyData -NoNewline -Encoding ascii
    $tmpKey    = Upload-RemoteFile -Ip $ip -Credential $cred -LocalPath $tmpLocal -RemoteDir $remoteDir -SvcPassPlain $svcPass

    $cmds = @(
      'mkdir -p /root/.ssh && chmod 700 /root/.ssh && chown root:root /root/.ssh',
      "touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && cat /root/.ssh/authorized_keys $tmpKey | sort -u > /root/.ssh/.auth.tmp && mv /root/.ssh/.auth.tmp /root/.ssh/authorized_keys && chown root:root /root/.ssh/authorized_keys && rm -f $tmpKey",
@'
if grep -q '^[#[:space:]]*PermitRootLogin' /etc/ssh/sshd_config; then
  sed -i 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
else
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
fi
if grep -q '^[#[:space:]]*PubkeyAuthentication' /etc/ssh/sshd_config; then
  sed -i 's/^[#[:space:]]*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
else
  echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
fi
'@,
      ('echo ' + [Quote]::Single("root:$rootPass") + ' | chpasswd'),
      'passwd -u root >/dev/null 2>&1 || true',
      "printf '%s\n' 'root ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/000-root-nopasswd && chmod 440 /etc/sudoers.d/000-root-nopasswd && visudo -cf /etc/sudoers >/dev/null 2>&1",
      'if command -v systemctl >/dev/null 2>&1; then (systemctl restart sshd || systemctl restart ssh); else (service sshd restart || service ssh restart); fi'
    )

    foreach ($c in $cmds) {
      $out = Invoke-Sudo -SshSession $session -CommandText $c -SvcPassword $svcPass
      if ($out.ExitStatus -ne 0) {
        throw ("Remote command failed on {0}: {1}" -f $ip, ($out.Error -join "`n"))
      }
    }

    # Verify key-based root SSH
    $rootKeySession = $null
    try {
      $rootKeySession = New-SSHSession -ComputerName $ip -Credential (New-Object System.Management.Automation.PSCredential ('root',(ConvertTo-SecureString 'x' -AsPlainText -Force))) -KeyFile $privKey -AcceptKey
      if ($rootKeySession -and $rootKeySession.Session.IsConnected) {
        Write-Output ("Root key login OK on {0}" -f $ip)

        # Seed known_hosts using OpenSSH itself (no prompts)
        try {
          if (Seed-KnownHost -Ip $ip -PrivKeyPath $privKey) {
            Write-Output ("Cached SSH fingerprint for {0}" -f $ip)
          } else {
            Write-Output ("Warning: could not cache fingerprint for {0}" -f $ip)
          }
        } catch {
          Write-Output ("Warning: known_hosts cache issue for {0}: {1}" -f $ip, $_)
        }

        $results += [pscustomobject]@{ Host = $ip; Status = 'OK'; Notes = 'Configured, verified, fingerprint cached' }
      } else {
        throw 'Root key login did not connect'
      }
    } catch {
      $results += [pscustomobject]@{ Host = $ip; Status = 'PARTIAL'; Notes = ("Configured but root key login failed: {0}" -f $_) }
    } finally {
      if ($rootKeySession) { $null = Remove-SSHSession -SSHSession $rootKeySession }
    }

  } catch {
    Write-Output ("Error on {0}: {1}" -f $ip, $_)
    $results += [pscustomobject]@{ Host = $ip; Status = 'ERROR'; Notes = ("$_") }
  } finally {
    if ($session)  { $null = Remove-SSHSession -SSHSession $session }
    if ($tmpLocal) { Remove-Item -LiteralPath $tmpLocal -Force }
  }
}

Write-Output ''
Write-Output '==== Summary ===='
$results | Format-Table -AutoSize