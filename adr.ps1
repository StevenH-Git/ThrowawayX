function Move-FsmoRoles {
  Import-ActiveDirectoryModule
  $target = Select-TargetDomainController -Prompt "Transfer FSMO roles to which DC?"

  if ([string]::IsNullOrWhiteSpace($target)) {
    throw "No target DC selected."
  }

  Write-Host "`nTransferring all FSMO roles to $target ..." -ForegroundColor Yellow

  $moveParams = @{
    Identity            = $target
    OperationMasterRole = @('SchemaMaster','DomainNamingMaster','PDCEmulator','RIDMaster','InfrastructureMaster')
    Confirm             = $false
  }

  Move-ADDirectoryServerOperationMasterRole @moveParams

  Invoke-FsmoRoleQueryLoop
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

  Write-Host "`nSeizing all FSMO roles to $target ..." -ForegroundColor Yellow

  $seizeParams = @{
    Identity            = $target
    OperationMasterRole = @('SchemaMaster','DomainNamingMaster','PDCEmulator','RIDMaster','InfrastructureMaster')
    Force               = $true
    Confirm             = $false
  }

  Move-ADDirectoryServerOperationMasterRole @seizeParams

  Invoke-FsmoRoleQueryLoop
}
