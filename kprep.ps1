# Requirements & Notes
<# 
=== LAB USE ONLY ===

****** MINIMALLY HARDENED ******

Requires:
- Windows 10/11 with OpenSSH client in PATH (ssh, scp, ssh-keygen) (Add-WindowsCapability 'google it')
- PowerShell 7+, may work on 5+
- Posh-SSH module (script auto-installs if missing) may require a restart of the script
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

Edit at your own risk. This modifies sshd and sudoers.

=== LAB USE ONLY ===
#>

$ErrorActionPreference = 'Stop'

# Fail fast
$ErrorActionPreference = 'Stop'

# Posh-SSH
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
  Install-Module Posh-SSH -Scope CurrentUser -Force -AllowClobber
}
Import-Module Posh-SSH

function Read-Ip {
  param(
    [Parameter(Mandatory)][string]$Label,
    [string[]]$Used = @()
  )
  $rx = '^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)$'
  while ($true) {
    $raw = Read-Host "$Label IP"
    $ip = $raw.Trim()
    if ($ip -notmatch $rx) { Write-Host "Invalid IPv4. Example: 192.168.1.10"; continue }
    if ($Used -contains $ip) { Write-Host "Duplicate IP not allowed. Enter a different IP."; continue }
    return $ip
  }
}

# Secure string helpers
function SecureToPlain {
  param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try   { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Read-ConfirmedSecret {
  param([Parameter(Mandatory)][string]$Label)
  while ($true) {
    $p1 = Read-Host "Enter $Label" -AsSecureString
    $p2 = Read-Host "Re-enter $Label" -AsSecureString
    if ((SecureToPlain $p1) -ceq (SecureToPlain $p2)) { return $p1 }
    Write-Host "Mismatch. Try again."
  }
}

$svcUser     = Read-Host "Enter service account username (non-root)"
$svcPassSec  = Read-ConfirmedSecret "service account password"
$rootPassSec = Read-ConfirmedSecret "root password to set on targets"


$ips = @()
$ips += Read-Ip -Label "Control node 1" -Used $ips
$ips += Read-Ip -Label "Control node 2" -Used $ips
$ips += Read-Ip -Label "Control node 3" -Used $ips
$ips += Read-Ip -Label "Worker node 1"  -Used $ips
$ips += Read-Ip -Label "Worker node 2"  -Used $ips
$ips += Read-Ip -Label "Worker node 3"  -Used $ips

Write-Host ""
Write-Host "Summary"
Write-Host "Service account: $svcUser"
Write-Host "Control nodes: $($ips[0]), $($ips[1]), $($ips[2])"
Write-Host "Worker nodes : $($ips[3]), $($ips[4]), $($ips[5])"
Write-Host ""
while ($true) {
  $resp = Read-Host "Type YES to continue or EXIT to quit"
  switch ($resp) {
    'YES'  { break }
    'EXIT' { Write-Host "Exiting by request."; exit 0 }
    default { Write-Host "Enter YES or EXIT" }
  }
}

$svcPass  = SecureToPlain $svcPassSec
$rootPass = SecureToPlain $rootPassSec

# Ensure local SSH key
$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
$privKey = Join-Path $sshDir "id_ed25519"
$pubKey  = "$privKey.pub"
if (-not (Test-Path $privKey -PathType Leaf)) { & ssh-keygen -t ed25519 -N "" -f $privKey | Out-Null }
if (-not (Test-Path $pubKey)) { throw "Missing public key $pubKey" }
$pubKeyData = Get-Content $pubKey -Raw

Add-Type -TypeDefinition @"
using System;
public static class Quote {
  public static string Single(string s) {
    if (string.IsNullOrEmpty(s)) return "''";
    return "'" + s.Replace("'", "'\"'\"'") + "'";
  }
}
"@

function Invoke-Sudo {
  param(
    [Parameter(Mandatory)] $SshSession,
    [Parameter(Mandatory)] [string]$CommandText,
    [Parameter(Mandatory)] [string]$SvcPassword
  )
  $wrapped = "echo " + [Regex]::Escape($SvcPassword) + " | sudo -S bash -lc " + [Quote]::Single($CommandText)
  Invoke-SSHCommand -SSHSession $SshSession -Command $wrapped
}

$results = @()

foreach ($ip in $ips) {
  Write-Host "=== ${ip} ==="

  $cred = New-Object pscredential ($svcUser, $svcPassSec)
  $session = $null
  $tmpLocal = $null
  try {
    $session = New-SSHSession -ComputerName $ip -Credential $cred -AcceptKey -KeepAliveInterval 15 -OperationTimeout 15000
    if (-not $session -or -not $session.Session.IsConnected) { throw "SSH session not connected" }

    $tmpKey = "/tmp/root_pubkey_$([guid]::NewGuid().ToString('N'))"
    $tmpLocal = New-TemporaryFile
    Set-Content -LiteralPath $tmpLocal -Value $pubKeyData -NoNewline -Encoding ascii
    Set-SCPFile -LocalFile $tmpLocal -ComputerName $ip -Credential $cred -RemotePath $tmpKey -AcceptKey

    # Core changes: set and unlock root password explicitly, then allow root SSH and key auth
    $cmds = @(
      "mkdir -p /root/.ssh && chmod 700 /root/.ssh && chown root:root /root/.ssh",
      "touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && cat /root/.ssh/authorized_keys $tmpKey | sort -u > /root/.ssh/.auth.tmp && mv /root/.ssh/.auth.tmp /root/.ssh/authorized_keys && chown root:root /root/.ssh/authorized_keys && rm -f $tmpKey",
@"
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
"@,
      # Set the root password you entered
      ("echo " + [Quote]::Single("root:$rootPass") + " | chpasswd"),
      # Ensure root is unlocked in case it was locked
      "passwd -u root >/dev/null 2>&1 || true",
      # Allow passwordless sudo for root
      "printf '%s\n' 'root ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/000-root-nopasswd && chmod 440 /etc/sudoers.d/000-root-nopasswd && visudo -cf /etc/sudoers >/dev/null 2>&1",
      # Restart SSH
      "if command -v systemctl >/dev/null 2>&1; then (systemctl restart sshd || systemctl restart ssh); else (service sshd restart || service ssh restart); fi"
    )

    foreach ($c in $cmds) {
      $out = Invoke-Sudo -SshSession $session -CommandText $c -SvcPassword $svcPass
      if ($out.ExitStatus -ne 0) {
        throw ("Remote command failed on ${ip}: {0}" -f ($out.Error -join "`n"))
      }
    }

    # Verify key-based root SSH
    $rootKeySession = $null
    try {
      $rootKeySession = New-SSHSession -ComputerName $ip -Credential (New-Object pscredential ('root',(ConvertTo-SecureString 'x' -AsPlainText -Force))) -KeyFile $privKey -AcceptKey -OperationTimeout 10000
      if ($rootKeySession -and $rootKeySession.Session.IsConnected) {
        Write-Host "Root key login OK on ${ip}"
        $results += [pscustomobject]@{ Host=$ip; Status="OK"; Notes="Configured and verified" }
      } else {
        throw "Root key login did not connect"
      }
    } catch {
      $results += [pscustomobject]@{ Host=$ip; Status="PARTIAL"; Notes=("Configured but root key login failed: {0}" -f $_) }
    } finally {
      if ($rootKeySession) { Remove-SSHSession -SSHSession $rootKeySession | Out-Null }
    }

  } catch {
    Write-Host ("Error on ${ip}: {0}" -f $_)
    $results += [pscustomobject]@{ Host=$ip; Status="ERROR"; Notes=("$_") }
  } finally {
    if ($session)  { Remove-SSHSession -SSHSession $session  | Out-Null }
    if ($tmpLocal) { Remove-Item $tmpLocal -Force }
  }
}

Write-Host ""
Write-Host "=== Summary ==="
$results | Format-Table -AutoSize