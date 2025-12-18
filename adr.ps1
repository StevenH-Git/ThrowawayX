# Requires PowerShell Version 5.1+

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Import-ActiveDirectoryModule {
  if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw "ActiveDirectory module not found. Run this on a DC or install RSAT (AD DS tools)."
  }
  Import-Module ActiveDirectory -ErrorAction Stop
}

function Get-DiscoveredDomainControllers {
  try {
    Import-ActiveDirectoryModule
    $dcs = @(
      Get-ADDomainController -Filter * |
        Sort-Object -Property HostName |
        Select-Object Name, HostName, IPv4Address, Site, IsGlobalCatalog
    )
  } catch {
    $domain = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).Name

    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
      throw "Unable to query AD for DCs, and Resolve-DnsName is unavailable for DNS fallback."
    }

    $srv = @(
      Resolve-DnsName -Type SRV -Name ("_ldap._tcp.dc._msdcs.{0}" -f $domain) -ErrorAction Stop
    )

    $names = @(
      $srv |
        Where-Object { $_.NameTarget } |
        ForEach-Object { $_.NameTarget.TrimEnd('.') } |
        Sort-Object -Unique
    )

    $dcs = @(
      foreach ($n in $names) {
        [pscustomobject]@{
          Name           = $n.Split('.')[0]
          HostName       = $n
          IPv4Address    = $null
          Site           = $null
          IsGlobalCatalog= $null
        }
      }
    )
  }

  if (@($dcs).Count -lt 1) {
    throw "No domain controllers discovered."
  }

  return $dcs
}

function Select-TargetDomainController {
  param(
    [Parameter(Mandatory)]
    [string]$Prompt
  )

  $dcs   = @(Get-DiscoveredDomainControllers)
  $count = $dcs.Count

  Write-Host ""
  Write-Host $Prompt -ForegroundColor Cyan

  for ($i = 0; $i -lt $count; $i++) {
    $dc = $dcs[$i]

    $displayHost = @($dc.Name, $dc.HostName)[-not [string]::IsNullOrWhiteSpace([string]$dc.HostName)]
    $ip          = @('-', $dc.IPv4Address)[-not [string]::IsNullOrWhiteSpace([string]$dc.IPv4Address)]
    $site        = @('-', $dc.Site)[-not [string]::IsNullOrWhiteSpace([string]$dc.Site)]
    $gc          = @('-', $dc.IsGlobalCatalog)[($null -ne $dc.IsGlobalCatalog)]

    Write-Host ("{0}. {1}  (IP: {2}, Site: {3}, GC: {4})" -f ($i + 1), $displayHost, $ip, $site, $gc)
  }

  while ($true) {
    $raw = Read-Host ("Select a DC by number (1-{0})" -f $count)
    if ($raw -match '^\d+$') {
      $n = [int]$raw
      if ($n -ge 1 -and $n -le $count) {
        $selected = $dcs[$n - 1]
        return @($selected.Name, $selected.HostName)[-not [string]::IsNullOrWhiteSpace([string]$selected.HostName)]
      }
    }
    Write-Host "Invalid selection." -ForegroundColor DarkYellow
  }
}

function Invoke-NetdomFsmoQuery {
  Write-Host "`nRunning: netdom query fsmo`n" -ForegroundColor Cyan

  if (-not (Get-Command netdom.exe -ErrorAction SilentlyContinue)) {
    throw "netdom.exe not found. Install AD DS tools / run on a DC."
  }

  & netdom.exe query fsmo
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("netdom exited with code {0}" -f $LASTEXITCODE) -ForegroundColor DarkYellow
  }
}

function Invoke-FsmoQueryLoop {
  Invoke-NetdomFsmoQuery

  while ($true) {
    Write-Host ""
    Write-Host "1. Continue"
    Write-Host "2. Refresh (rerun netdom query fsmo)"
    $choice = Read-Host "Choose"

    switch ($choice) {
      '1' { return }
      '2' { Invoke-NetdomFsmoQuery }
      default { Write-Host "Invalid choice. Enter 1 or 2." -ForegroundColor DarkYellow }
    }
  }
}

function Move-FsmoRoles {
  Import-ActiveDirectoryModule
  $target = Select-TargetDomainController -Prompt "Transfer FSMO roles to which DC?"

  if ([string]::IsNullOrWhiteSpace($target)) {
    throw "No target DC selected."
  }

  Write-Host ("`nTransferring all FSMO roles to {0} ..." -f $target) -ForegroundColor Yellow

  $params = @{
    Identity            = $target
    OperationMasterRole = @('SchemaMaster','DomainNamingMaster','PDCEmulator','RIDMaster','InfrastructureMaster')
    Confirm             = $false
  }

  Move-ADDirectoryServerOperationMasterRole @params

  Invoke-FsmoQueryLoop
}

function Invoke-FsmoRoleSeizure {
  Import-ActiveDirectoryModule
  $target = Select-TargetDomainController -Prompt "Seize FSMO roles to which DC?"

  if ([string]::IsNullOrWhiteSpace($target)) {
    throw "No target DC selected."
  }

  Write-Host "`nWARNING: Seizing FSMO roles is destructive if the old role holder returns." -ForegroundColor Red
  $ack = Read-Host "Type SEIZE to continue, anything else cancels"
  if ($ack -ne 'SEIZE') {
    Write-Host "Cancelled." -ForegroundColor DarkYellow
    return
  }

  Write-Host ("`nSeizing all FSMO roles to {0} ..." -f $target) -ForegroundColor Yellow

  $params = @{
    Identity            = $target
    OperationMasterRole = @('SchemaMaster','DomainNamingMaster','PDCEmulator','RIDMaster','InfrastructureMaster')
    Force               = $true
    Confirm             = $false
  }

  Move-ADDirectoryServerOperationMasterRole @params

  Invoke-FsmoQueryLoop
}

function Invoke-DcdiagAll {
  Write-Host "`nRunning: dcdiag /a`n" -ForegroundColor Cyan
  & dcdiag.exe /a
  if ($LASTEXITCODE -ne 0) { Write-Host ("dcdiag exited with code {0}" -f $LASTEXITCODE) -ForegroundColor DarkYellow }
}

function Invoke-RepadminSummary {
  Write-Host "`nRunning: repadmin /replsummary`n" -ForegroundColor Cyan
  & repadmin.exe /summary
  if ($LASTEXITCODE -ne 0) { Write-Host ("repadmin exited with code {0}" -f $LASTEXITCODE) -ForegroundColor DarkYellow }
}

function Invoke-RepadminSyncAll {
  Write-Host "`nRunning: repadmin /syncall /A /d`n" -ForegroundColor Cyan
  & repadmin.exe /syncall /A /d
  if ($LASTEXITCODE -ne 0) { Write-Host ("repadmin exited with code {0}" -f $LASTEXITCODE) -ForegroundColor DarkYellow }
}

function Write-AdDcMaintenanceMenu {
  Write-Host "`n=== AD DC Maintenance Menu ===" -ForegroundColor Green
  Write-Host "1. Check which domain controller owns the FSMO roles (netdom query fsmo)"
  Write-Host "2. Move (transfer) the AD FSMO roles to a selected DC"
  Write-Host "3. Seize the AD FSMO roles to a selected DC"
  Write-Host "4. Perform: DCDIAG /a"
  Write-Host "5. Perform: REPADMIN /summary"
  Write-Host "6. Perform: REPADMIN /syncall /A /d"
}

if (-not (Test-IsAdministrator)) {
  Write-Host "WARNING: Not running elevated. Some actions may fail. Open PowerShell as Administrator." -ForegroundColor DarkYellow
}

while ($true) {
  Write-AdDcMaintenanceMenu

  $selection = Read-Host "Select ONE option (1-6)"
  if ($selection -notmatch '^[1-6]$') {
    Write-Host "Invalid selection. Enter a single number 1-6." -ForegroundColor DarkYellow
    continue
  }

  try {
    switch ($selection) {
      '1' { Invoke-NetdomFsmoQuery }
      '2' { Move-FsmoRoles }
      '3' { Invoke-FsmoRoleSeizure }
      '4' { Invoke-DcdiagAll }
      '5' { Invoke-RepadminSummary }
      '6' { Invoke-RepadminSyncAll }
    }
  } catch {
    Write-Host ("`nERROR: {0}`n" -f $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
      Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkYellow
    }
  }

  Write-Host ""
  Write-Host "1. Return to menu"
  Write-Host "2. Exit"
  $next = Read-Host "Choose"
  if ($next -eq '2') { break }
}
