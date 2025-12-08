<#
SYNOPSIS
    Force-remove an offline/unreachable domain controller, clean up AD metadata, and purge DNS records.

DESCRIPTION
    - Enumerates all domain controllers, prompts you to pick one (e.g., DC1 or DC2).
    - Uses the local DC (the one you're running on) as the DNS server.
    - DOES NOT check reachability; assumes the selected DC is dead/unrecoverable.
    - Uses Remove-ADDomainController -MetadataCleanup where possible.
    - Removes leftover Sites & Services server objects.
    - Removes DNS A and SRV records related to the target DC from the local DNS server.

PARAMETER SkipDnsCleanup
    Skip the DNS record cleanup phase.

EXAMPLE
    .\Remove-OfflineDC.ps1

EXAMPLE
    .\Remove-OfflineDC.ps1 -SkipDnsCleanup

EXAMPLE
    .\Remove-OfflineDC.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$SkipDnsCleanup
)

#region Pre-flight checks
Write-Host "=== Offline Domain Controller Removal ===" -ForegroundColor Cyan

try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "ActiveDirectory module not available. Install RSAT / AD DS tools and rerun."
    exit 1
}

try {
    Import-Module DnsServer -ErrorAction Stop
} catch {
    if (-not $SkipDnsCleanup) {
        Write-Warning "DnsServer module not available. DNS cleanup will not run."
        $SkipDnsCleanup = $true
    }
}

$DnsServer = $env:COMPUTERNAME
Write-Host "DNS server for cleanup will be: $DnsServer" -ForegroundColor Yellow

# Get all DCs in the domain
try {
    $allDCs = Get-ADDomainController -Filter * -ErrorAction Stop | Sort-Object HostName
} catch {
    Write-Error "Failed to enumerate domain controllers: $($_.Exception.Message)"
    exit 1
}

if (-not $allDCs -or $allDCs.Count -eq 0) {
    Write-Error "No domain controllers found in the domain."
    exit 1
}

Write-Host ""
Write-Host "Domain controllers detected:" -ForegroundColor Cyan
for ($i = 0; $i -lt $allDCs.Count; $i++) {
    $idx = $i + 1
    $dcObj = $allDCs[$i]
    Write-Host ("[{0}] {1}  (Site: {2})" -f $idx, $dcObj.HostName, $dcObj.Site)
}

Write-Host ""
Write-Host "You are running this script on: $env:COMPUTERNAME" -ForegroundColor Yellow
Write-Host "Select the DC you want to REMOVE (assumed offline/unreachable)." -ForegroundColor Red

# Prompt until a valid selection is made
$targetIdx = $null
while (-not $targetIdx) {
    $inputVal = Read-Host "Enter the number of the DC to remove"
    if ([int]::TryParse($inputVal, [ref]$null)) {
        $num = [int]$inputVal
        if ($num -ge 1 -and $num -le $allDCs.Count) {
            $targetIdx = $num
        } else {
            Write-Host "Invalid selection. Choose a number between 1 and $($allDCs.Count)." -ForegroundColor Red
        }
    } else {
        Write-Host "Invalid input. Enter a numeric value." -ForegroundColor Red
    }
}

$targetDC = $allDCs[$targetIdx - 1]

# Safety: don't let user remove the DC they are currently on
if ($targetDC.Name -ieq $env:COMPUTERNAME -or $targetDC.HostName -like "$($env:COMPUTERNAME).*") {
    Write-Error "You selected the DC you are currently running on ($env:COMPUTERNAME). Run this script from the OTHER DC to remove this one."
    exit 1
}

Write-Host ""
Write-Host "Target DC to remove:" -ForegroundColor Yellow
$targetDC | Select-Object Name, HostName, IPv4Address, Site, IsGlobalCatalog | Format-List

$domain = Get-ADDomain
$forest = Get-ADForest

Write-Host "Current domain: $($domain.DNSRoot)"
Write-Host "Forest root:    $($forest.RootDomain)"

Write-Host ""
Write-Host "You are about to FORCE REMOVE this domain controller and its metadata." -ForegroundColor Red
Write-Host "Domain: $($domain.DNSRoot)"
Write-Host "DC:     $($targetDC.HostName)"
Write-Host ""
$confirm = Read-Host "Type 'REMOVE DC' to continue"
if ($confirm -ne 'REMOVE DC') {
    Write-Host "Confirmation phrase not matched. Aborting."
    exit 1
}

#endregion Pre-flight checks

#region Build working DC object
# Build working object with computer DN and key properties
$dc = $null
$dcException = $null

try {
    $realDc = Get-ADDomainController -Identity $targetDC.HostName -ErrorAction Stop
} catch {
    $dcException = $_
    $realDc = $null
}

if ($realDc) {
    try {
        $dcComputer = Get-ADComputer -Identity $realDc.Name -ErrorAction Stop
    } catch {
        $dcComputer = $null
    }

    $dc = [PSCustomObject]@{
        Name             = $realDc.Name
        HostName         = $realDc.HostName
        ComputerObjectDN = if ($dcComputer) { $dcComputer.DistinguishedName } else { $null }
        IPv4Address      = $realDc.IPv4Address
        Site             = $realDc.Site
        IsGlobalCatalog  = $realDc.IsGlobalCatalog
    }
} else {
    Write-Warning "Could not find '$($targetDC.HostName)'. Trying computer object by name..."

    try {
        $comp = Get-ADComputer -Identity $targetDC.Name -ErrorAction Stop -Properties DNSHostName
    } catch {
        Write-Error "Could not find a DC or computer object for '$($targetDC.Name)'."
        if ($dcException) { Write-Verbose $dcException.ToString() }
        exit 1
    }

    $dc = [PSCustomObject]@{
        Name             = $comp.Name
        HostName         = if ($comp.DNSHostName) { $comp.DNSHostName } else { $comp.Name }
        ComputerObjectDN = $comp.DistinguishedName
        IPv4Address      = $null
        Site             = $null
        IsGlobalCatalog  = $false
    }
}

Write-Host ""
Write-Host "Working DC object:" -ForegroundColor Cyan
$dc | Format-List
#endregion Build working DC object

#region AD metadata cleanup
Write-Host ""
Write-Host "=== Step 1: AD metadata cleanup ===" -ForegroundColor Cyan

$dcRemovedViaCmdlet = $false

try {
    $realDcAgain = $null
    try {
        $realDcAgain = Get-ADDomainController -Identity $dc.HostName -ErrorAction Stop
    } catch {
        $realDcAgain = $null
    }

    if ($realDcAgain) {
        if ($PSCmdlet.ShouldProcess($dc.HostName, "Remove-ADDomainController metadata (offline cleanup)")) {
            Remove-ADDomainController -Identity $dc.HostName `
                                      -MetadataCleanup `
                                      -Force `
                                      -Confirm:$false
            $dcRemovedViaCmdlet = $true
            Write-Host "Remove-ADDomainController -MetadataCleanup completed." -ForegroundColor Green
        }
    } else {
        Write-Warning "DC '$($dc.HostName)' is no longer recognized as a domain controller object. Skipping Remove-ADDomainController."
    }
} catch {
    Write-Warning "Remove-ADDomainController failed: $($_.Exception.Message)"
    Write-Warning "Continuing with manual AD object cleanup."
}

# Remove computer object if still present
if ($dc.ComputerObjectDN) {
    Write-Host "Checking for computer object: $($dc.ComputerObjectDN)"
    try {
        $compCheck = Get-ADComputer -Identity $dc.ComputerObjectDN -ErrorAction Stop
        if ($compCheck) {
            if ($PSCmdlet.ShouldProcess($dc.ComputerObjectDN, "Remove-ADComputer")) {
                Remove-ADComputer -Identity $dc.ComputerObjectDN -Confirm:$false
                Write-Host "Computer object removed: $($dc.ComputerObjectDN)" -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "Computer object for '$($dc.Name)' not found or already removed."
    }
} else {
    Write-Host "No computer DN recorded for this DC; skipping computer object removal."
}

# Extra: ensure Sites & Services server object is gone
Write-Host "Verifying Sites & Services cleanup..."
$configNC = "CN=Configuration,$($domain.DistinguishedName)"
$sitesBase = "CN=Sites,$configNC"

try {
    $serverObjects = Get-ADObject -LDAPFilter "(objectClass=server)" -SearchBase $sitesBase -SearchScope Subtree -ErrorAction Stop |
        Where-Object { $_.Name -ieq $dc.Name -or $_.Name -ieq ($dc.HostName -split '\.')[0] }

    foreach ($srv in $serverObjects) {
        if ($PSCmdlet.ShouldProcess($srv.DistinguishedName, "Remove Sites & Services server object")) {
            Remove-ADObject -Identity $srv.DistinguishedName -Recursive -Confirm:$false
            Write-Host "Removed Sites & Services server object: $($srv.DistinguishedName)" -ForegroundColor Green
        }
    }

    if (-not $serverObjects) {
        Write-Host "No remaining Sites & Services server objects found for this DC." -ForegroundColor Green
    }
} catch {
    Write-Warning "Error while verifying Sites & Services: $($_.Exception.Message)"
}
#endregion AD metadata cleanup

#region DNS cleanup
if (-not $SkipDnsCleanup) {
    Write-Host ""
    Write-Host "=== Step 2: DNS cleanup on server '$DnsServer' ===" -ForegroundColor Cyan

    $dcFqdn = $dc.HostName.ToLower()
    $dcHostShort = ($dcFqdn -split '\.')[0]
    $dcIp = $dc.IPv4Address

    Write-Host "Target FQDN: $dcFqdn"
    if ($dcIp) { Write-Host "Target IPv4: $dcIp" }

    try {
        $zones = Get-DnsServerZone -ComputerName $DnsServer -ErrorAction Stop
    } catch {
        Write-Warning "Failed to enumerate zones on DNS server '$DnsServer': $($_.Exception.Message)"
        $zones = @()
    }

    if (-not $zones) {
        Write-Warning "No zones found or unable to query DNS server. Skipping DNS cleanup."
    } else {
        foreach ($zone in $zones) {
            Write-Host "Scanning zone: $($zone.ZoneName)" -ForegroundColor DarkCyan
            try {
                $records = Get-DnsServerResourceRecord -ZoneName $zone.ZoneName -ComputerName $DnsServer -ErrorAction Stop
            } catch {
                Write-Warning "Failed to read records in zone $($zone.ZoneName): $($_.Exception.Message)"
                continue
            }

            # Filter for A and SRV records tied to this DC
            $matchingRecs = $records | Where-Object {
                $isMatch = $false

                if ($_.RecordType -eq 'A') {
                    if ($dcIp -and $_.RecordData.IPv4Address.ToString() -eq $dcIp) { $isMatch = $true }
                    if (-not $isMatch -and $_.HostName -eq $dcHostShort) { $isMatch = $true }
                }

                if ($_.RecordType -eq 'SRV') {
                    if ($_.RecordData.DomainName.ToLower() -eq $dcFqdn) {
                        $isMatch = $true
                    }
                }

                $isMatch
            }

            if ($matchingRecs) {
                foreach ($rec in $matchingRecs) {
                    $target = "$($zone.ZoneName): $($rec.HostName) [$($rec.RecordType)]"
                    if ($PSCmdlet.ShouldProcess($target, "Remove DNS record")) {
                        try {
                            Remove-DnsServerResourceRecord -ZoneName $zone.ZoneName `
                                                           -ComputerName $DnsServer `
                                                           -InputObject $rec `
                                                           -Force `
                                                           -ErrorAction Stop
                            Write-Host "Removed DNS record => $target" -ForegroundColor Green
                        } catch {
                            Write-Warning "Failed to remove DNS record '$target': $($_.Exception.Message)"
                        }
                    }
                }
            } else {
                Write-Host "No matching DNS records for this DC in zone $($zone.ZoneName)." -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ""
    Write-Host "DNS cleanup phase completed." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "DNS cleanup skipped by request (-SkipDnsCleanup)." -ForegroundColor Yellow
}
#endregion DNS cleanup

Write-Host ""
Write-Host "=== Offline DC removal script completed. Review output for any warnings/errors. ===" -ForegroundColor Cyan
