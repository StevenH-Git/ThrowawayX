<#
.SYNOPSIS
  AD DC single-action menu:
    1) Show FSMO role owners (netdom query fsmo)
    2) Transfer FSMO roles to a selected DC (discovered from AD/DNS)
    3) Seize FSMO roles to a selected DC (discovered from AD/DNS)
    4) Run DCDIAG /a
    5) Run REPADMIN /summary
    6) Run REPADMIN /syncall /A /d
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-ActiveDirectoryModule {
  if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw "ActiveDirectory module not found. Run this on a DC or install RSAT: Active Directory module."
  }
  Import-Module ActiveDirectory -ErrorAction Stop
}

function Get-DiscoveredDomainControllers {
  # Prefer AD (most reliable for DC inventory). Fallback to DNS SRV lookup.
  $results = @()

  try {
    Import-ActiveDirectoryModule
    $results = Get-ADDomainController -Filter * |
      Sort-Object -Property HostName |
      Select-Object `
        @{n='Name';e={$_.Name}},
        @{n='HostName';e={$_.HostName}},
        @{n='IPv4Address';e={$_.IPv4Address}},
        @{n='Site';e={$_.Site}},
        @{n='IsGlobalCatalog';e={$_.IsGlobalCatalog}}
  } catch {
    # DNS fallback
    try {
      $domain = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).Name
      $srv = Resolve-DnsName -Type SRV -Name "_ldap._tcp.dc._msdcs.$domain" -ErrorAction Stop
      $names = $srv |
        Where-Object { $_.NameTarget } |
        ForEach-Object { $_.NameTarget.TrimEnd('.') } |
        Sort-Object -Unique

      $results = $names | ForEach-Object {
        [pscustomobject]@{
          Name           = $_.Split('.')[0]
          HostName        = $_
          IPv4Address     = $null
          Site            = $null
          IsGlobalCatalog = $null
        }
      }
    } catch {
      throw "Unable to discover domain controllers via AD or DNS. $($_.Exception.Message)"
    }
  }

  if (-not $results -or $results.Count -lt 1) {
    throw "No domain controllers discovered."
  }

  return $results
}

function Select-TargetDomainController {
  param(
    [Parameter(Mandatory)]
    [string]$Prompt
  )

  $dcs = Get-DiscoveredDomainControllers

  Write-Host ""
  Write-Host $Prompt -ForegroundColor Cyan

  for ($i = 0; $i -lt $dcs.Count; $i++) {
    $dc = $dcs[$i]
    $host = if ($dc.HostName) { $dc.HostName } else { $dc.Name }
    $ip   = if ($dc.IPv4Address) { $dc.IPv4Address } else { "-" }
    $site = if ($dc.Site) { $dc.Site } else { "-" }
    $gc   = if ($null -ne $dc.IsGlobalCatalog) { $dc.IsGlobalCatalog } else { "-" }

    Write-Host ("{0}. {1}  (IP: {2}, Site: {3}, GC: {4})" -f ($i + 1), $host, $ip, $site, $gc)
  }

  while ($true) {
    $raw = Read-Host "Select a DC by number (1-$($dcs.Count))"
    if ($raw -match '^\d+$') {
      $n = [int]$raw
      if ($n -ge 1 -and $n -le $dcs.Count) {
        $selected = $dcs[$n - 1]
        return (if ($selected.HostName) { $selected.HostName } else { $selected.Name })
      }
    }
    Write-Host "Invalid selection." -ForegroundColor DarkYellow
  }
}

function Invoke-NetdomFsmoQuery {
  Write-Host "`nRunning: netdom query fsmo`n" -ForegroundColor Cyan

  $netdom = Get-Command netdom.exe -ErrorAction SilentlyContinue
  if (-not $netdom) {
    throw "netdom.exe not found. Run on a DC (RSAT/AD DS tools) or ensure netdom is installed and on PATH."
  }

  & netdom.exe query fsmo
  if ($LASTEXITCODE -ne 0) {
    Write-Host "netdom exited with code $LASTEXITCODE" -ForegroundColor DarkYellow
  }
}

function Invoke-FsmoRoleQueryLoop {
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

  Write-Host "`nTransferring all FSMO roles to $target ..." -ForegroundColor Yellow
  Move-ADDirectoryServerOperationMasterRole `
    -Identity $target `
    -OperationMasterRole SchemaMaster,DomainNamingMaster,PDCEmulator,RIDMaster,InfrastructureMaster `
    -Confirm:$false

  Invoke-FsmoRoleQueryLoop
}

function Invoke-FsmoRoleSeizure {
  Import-ActiveDirectoryModule
  $target = Select-TargetDomainController -Prompt "Seize FSMO roles to which DC?"

  Write-Host "`nWARNING: Seizing FSMO roles is destructive if the old role holder returns." -ForegroundColor Red
  $ack = Read-Host "Type SEIZE to continue, anything else cancels"
  if ($ack -ne 'SEIZE') {
    Write-Host "Cancelled." -ForegroundColor DarkYellow
    return
  }

  Write-Host "`nSeizing all FSMO roles to $target ..." -ForegroundColor Yellow
  Move-ADDirectoryServerOperationMasterRole `
    -Identity $target `
    -OperationMasterRole SchemaMaster,DomainNamingMaster,PDCEmulator,RIDMaster,InfrastructureMaster `
    -Force `
    -Confirm:$false

  Invoke-FsmoRoleQueryLoop
}

function Invoke-DcdiagAll {
  Write-Host "`nRunning: dcdiag /a`n" -ForegroundColor Cyan
  & dcdiag /a
  if ($LASTEXITCODE -ne 0) { Write-Host "dcdiag exited with code $LASTEXITCODE" -ForegroundColor DarkYellow }
}

function Invoke-RepadminSummary {
  Write-Host "`nRunning: repadmin /summary`n" -ForegroundColor Cyan
  & repadmin /summary
  if ($LASTEXITCODE -ne 0) { Write-Host "repadmin exited with code $LASTEXITCODE" -ForegroundColor DarkYellow }
}

function Invoke-RepadminSyncAll {
  Write-Host "`nRunning: repadmin /syncall /A /d`n" -ForegroundColor Cyan
  & repadmin /syncall /A /d
  if ($LASTEXITCODE -ne 0) { Write-Host "repadmin exited with code $LASTEXITCODE" -ForegroundColor DarkYellow }
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
    Write-Host "`nERROR: $($_.Exception.Message)`n" -ForegroundColor Red
  }

  Write-Host ""
  Write-Host "1. Return to menu"
  Write-Host "2. Exit"
  $next = Read-Host "Choose"
  if ($next -eq '2') { break }
}
