<#
.SYNOPSIS
Configure six Linux hosts for root SSH with your local RSA key, enable root login, set root password,
and grant passwordless sudo for root. (No known_hosts changes.)

.REQUIRES
- PowerShell 5.1+ or 7+
- OpenSSH client in PATH (ssh, ssh-keygen)
- Posh-SSH 3.2.4 (or compatible)
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
  param([Parameter(Mandatory)][string]$Label, [string[]]$Used=@())
  $ipv4Regex = '^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)$'
  while ($true) {
    $ip = (Read-Host "$Label IP").Trim()
    if ($ip -notmatch $ipv4Regex) { Write-Output 'Invalid IPv4. Example: 192.168.1.10'; continue }
    if ($Used -contains $ip)      { Write-Output 'Duplicate IP not allowed. Enter a different IP.'; continue }
    return $ip
  }
}

function ConvertTo-PlainText {
  [CmdletBinding()] param([Parameter(Mandatory)][Security.SecureString]$Secure)
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Read-ConfirmedSecret {
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Label)
  while ($true) {
    $p1 = Read-Host "Enter $Label" -AsSecureString
    $p2 = Read-Host "Re-enter $Label" -AsSecureString
    if ((ConvertTo-PlainText $p1) -ceq (ConvertTo-PlainText $p2)) { return $p1 }
    Write-Output 'Mismatch. Try again.'
  }
}

# Initialize local RSA key (~/.ssh/id_rsa); derive .pub if missing
function Initialize-LocalRsaKey {
  [CmdletBinding()] param([Parameter(Mandatory)][string]$PrivKeyPath)
  $pub = "$PrivKeyPath.pub"
  $sshgen = (Get-Command ssh-keygen -ErrorAction Stop).Source

  if (Test-Path -LiteralPath $PrivKeyPath -PathType Leaf) {
    if (-not (Test-Path -LiteralPath $pub)) {
      $pubText = & $sshgen -y -f $PrivKeyPath
      if ($LASTEXITCODE -ne 0 -or -not $pubText) { throw "ssh-keygen -y failed for $PrivKeyPath" }
      Set-Content -LiteralPath $pub -Value $pubText -NoNewline -Encoding ascii
    }
    return
  }

  $privEsc = $PrivKeyPath.Replace('"','\"')
  $p = Start-Process -FilePath $sshgen -ArgumentList ("-q -t rsa -b 4096 -N """" -f ""$privEsc""") -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -ne 0) { throw "ssh-keygen failed (exit $($p.ExitCode))" }
  if (-not (Test-Path -LiteralPath $pub -PathType Leaf)) { throw "Public key not created at $pub" }
}

# Prefer Posh-SSH transfers; fallback to SSH.NET SFTP if needed
function Upload-RemoteFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Ip,
    [Parameter(Mandatory)][pscredential]$Credential,
    [Parameter(Mandatory)][string]$LocalPath,
    [Parameter(Mandatory)][string]$RemoteDir,
    [Parameter(Mandatory)][string]$SvcPassPlain
  )
  $fileName = [IO.Path]::GetFileName($LocalPath)
  $remoteFull = ($RemoteDir.TrimEnd('/')) + '/' + $fileName

  if (Get-Command Set-SCPItem -Module Posh-SSH -ErrorAction SilentlyContinue) {
    Set-SCPItem -ComputerName $Ip -Credential $Credential -Path $LocalPath -Destination $RemoteDir -AcceptKey -Force
    return $remoteFull
  }
  if (Get-Command Set-SFTPItem -Module Posh-SSH -ErrorAction SilentlyContinue) {
    $sftp = New-SFTPSession -ComputerName $Ip -Credential $Credential -AcceptKey
    try { Set-SFTPItem -SessionId $sftp.SessionId -Path $LocalPath -Destination $remoteFull -Force }
    finally { if ($sftp) { $null = Remove-SFTPSession -SessionId $sftp.SessionId } }
    return $remoteFull
  }

  Add-Type -AssemblyName Renci.SshNet -ErrorAction SilentlyContinue
  $conn   = New-Object Renci.SshNet.PasswordConnectionInfo($Ip, $Credential.UserName, (ConvertTo-PlainText $Credential.Password))
  $client = New-Object Renci.SshNet.SftpClient($conn)
  try {
    $client.Connect()
    $fs = [System.IO.File]::OpenRead($LocalPath)
    try { $client.UploadFile($fs, $remoteFull, $true) } finally { $fs.Dispose() }
  } finally { $client.Dispose() }
  return $remoteFull
}

# POSIX single-quote helper for remote shell
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
  param([Parameter(Mandatory)]$SshSession, [Parameter(Mandatory)][string]$CommandText, [Parameter(Mandatory)][string]$SvcPassword)
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

# Local RSA key
$sshDir = Join-Path $env:USERPROFILE '.ssh'
if (-not (Test-Path -LiteralPath $sshDir)) { $null = New-Item -ItemType Directory -Path $sshDir -Force }
$rsaKey = Join-Path $sshDir 'id_rsa'
Initialize-LocalRsaKey -PrivKeyPath $rsaKey
$pubKey  = "$rsaKey.pub"
$pubKeyData = Get-Content -LiteralPath $pubKey -Raw

# -------- Remote configuration --------
$results = @()

foreach ($ip in $ips) {
  Write-Output ("=== {0} ===" -f $ip)
  $cred = New-Object pscredential ($svcUser, $svcPassSec)
  $session = $null; $tmpLocal = $null

  try {
    $session = New-SSHSession -ComputerName $ip -Credential $cred -AcceptKey -KeepAliveInterval 15
    if (-not $session -or -not $session.Session.IsConnected) { throw 'SSH session not connected' }

    # Upload public key into /tmp
    $remoteDir = '/tmp'
    $tmpLocal  = New-TemporaryFile
    Set-Content -LiteralPath $tmpLocal -Value $pubKeyData -NoNewline -Encoding ascii
    $tmpKey    = Upload-RemoteFile -Ip $ip -Credential $cred -LocalPath $tmpLocal -RemoteDir $remoteDir -SvcPassPlain $svcPass

    # Harden sshd; install key; diagnostics; unlock root; restart sshd; nopasswd sudo
    $cmds = @(
      'mkdir -p /root/.ssh && chmod 700 /root/.ssh && chown root:root /root/.ssh',
      "touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && cat /root/.ssh/authorized_keys $tmpKey | awk 'NF' | sort -u > /root/.ssh/.auth.tmp && mv /root/.ssh/.auth.tmp /root/.ssh/authorized_keys && chown root:root /root/.ssh/authorized_keys && rm -f $tmpKey",

      # ALSO support distros that use /etc/ssh/authorized_keys/%u
      'if [ -d /etc/ssh/authorized_keys ]; then mkdir -p /etc/ssh/authorized_keys && install -m 600 -o root -g root /root/.ssh/authorized_keys /etc/ssh/authorized_keys/root; fi',

@'
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-root-pubkey.conf <<'EOF'
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys/%u
EOF
'@,

      # SELinux contexts (if present)
      'if command -v restorecon >/dev/null 2>&1; then restorecon -Rv /root/.ssh >/dev/null 2>&1 || true; fi',

      # Sanity-check sshd config and show effective values
      'sshd -t',
      'sshd -T 2>/dev/null | egrep -i ''^(permitrootlogin|pubkeyauthentication|authorizedkeysfile)\s'' || true',

      # Set/unlock root password
      ('echo ' + [Quote]::Single("root:$rootPass") + ' | chpasswd'),
      'passwd -u root >/dev/null 2>&1 || true',

      # Restart sshd
      'if command -v systemctl >/dev/null 2>&1; then (systemctl restart sshd || systemctl restart ssh); else (service sshd restart || service ssh restart); fi',

      # Passwordless sudo for root
      "printf '%s\n' 'root ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/000-root-nopasswd && chmod 440 /etc/sudoers.d/000-root-nopasswd && visudo -cf /etc/sudoers >/dev/null 2>&1"
    )

    foreach ($c in $cmds) {
      $out = Invoke-Sudo -SshSession $session -CommandText $c -SvcPassword $svcPass
      if ($out.ExitStatus -ne 0) { throw ("Remote command failed on {0}: {1}" -f $ip, ($out.Error -join "`n")) }
    }

    # Verify key-based root SSH using RSA
    $rootKeySession = $null
    try {
      $rootKeySession = New-SSHSession -ComputerName $ip -Credential (New-Object pscredential ('root',(ConvertTo-SecureString 'x' -AsPlainText -Force))) -KeyFile $rsaKey -AcceptKey
      if (-not ($rootKeySession -and $rootKeySession.Session.IsConnected)) { throw 'Root key login did not connect' }
    } finally { if ($rootKeySession) { $null = Remove-SSHSession -SSHSession $rootKeySession } }

    Write-Output ("Root key login OK on {0}" -f $ip)
    $results += [pscustomobject]@{ Host=$ip; Status='OK'; Notes='Configured and RSA root login verified' }

  } catch {
    Write-Output ("Error on {0}: {1}" -f $ip, $_)
    $results += [pscustomobject]@{ Host=$ip; Status='PARTIAL'; Notes=("Configured but RSA root key login failed: {0}" -f $_) }
  } finally {
    if ($session)  { $null = Remove-SSHSession -SSHSession $session }
    if ($tmpLocal) { Remove-Item -LiteralPath $tmpLocal -Force }
  }
}

Write-Output ''
Write-Output '==== Summary ===='
$results | Format-Table -AutoSize