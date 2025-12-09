<#
.SYNOPSIS
    Remove an offline/unreachable domain controller from AD, clean up metadata, DFSR memberships, and DNS records.

.DESCRIPTION
    - Enumerates all domain controllers, prompts you to pick one (e.g., DC1 or DC2).
    - Assumes the selected DC is dead/unrecoverable (no demotion on that server).
    - Removes:
        * Sites & Services server object (and NTDS Settings / connection objects)
        * DC computer object (OU=Domain Controllers)
        * DFSR SYSVOL membership objects for that DC
        * DNS A, AAAA, PTR, SRV, CNAME, and NS records tied to the DC
    - Optionally scans the domain + config partitions for common attributes referencing the DC
      (FQDN / computer DN) and lets you remove those objects too.

.PARAMETER SkipDnsCleanup
    Skip the DNS record cleanup phase.

.EXAMPLE
    .\Remove-OfflineDC-Metadata.ps1

.EXAMPLE
    .\Remove-OfflineDC-Metadata.ps1 -SkipDnsCleanup

.EXAMPLE
    .\Remove-OfflineDC-Metadata.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$SkipDnsCleanup
)

#region Risk acknowledgment
Write-Host "=== WARNING ===" -ForegroundColor Red
Write-Host "Placeholder Text" -ForegroundColor Yellow
Write-Host ""

while ($true) {
    Write-Host "[1] I understand the risk"
    Write-Host "[2] Quit"
    $choice = Read-Host "Select an option (1 or 2)"

    switch ($choice) {
        '1' {
            Write-Host "Continuing with script execution..." -ForegroundColor Green
            break
        }
        '2' {
            Write-Host "Exiting script by user choice." -ForegroundColor Yellow
            exit 0
        }
        default {
            Write-Host "Invalid selection. Enter 1 or 2." -ForegroundColor Red
        }
    }
}
Write-Host ""
#endregion Risk acknowledgment

#region Pre-flight checks
Write-Host "=== Offline Domain Controller Metadata Cleanup ===" -ForegroundColor Cyan

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
    $idx  = $i + 1
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
    if ([int]::TryParse($inputVal, [ref]0)) {
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
    Write-Error "You selected the DC you are currently running on ($env:COMPUTERNAME). Run this script from another DC to remove this one."
    exit 1
}

Write-Host ""
Write-Host "Target DC to clean up:" -ForegroundColor Yellow
$targetDC | Select-Object Name, HostName, IPv4Address, Site, IsGlobalCatalog | Format-List

$domain  = Get-ADDomain
$forest  = Get-ADForest
$rootDse = Get-ADRootDSE

Write-Host "Current domain: $($domain.DNSRoot)"
Write-Host "Forest root:    $($forest.RootDomain)"
Write-Host ""
Write-Host "This script assumes the target DC is dead/unrecoverable and will perform OFFLINE METADATA CLEANUP only." -ForegroundColor Red

Write-Host ""
Write-Host "You are about to remove this DC's metadata, DFSR membership, and DNS records from AD." -ForegroundColor Red
Write-Host "Domain: $($domain.DNSRoot)"
Write-Host "DC:     $($targetDC.HostName)"
Write-Host ""
$confirm = Read-Host "Type EXACTLY 'REMOVE DC' to continue"
if ($confirm -ne 'REMOVE DC') {
    Write-Host "Confirmation phrase not matched. Aborting."
    exit 1
}
#endregion Pre-flight checks

#region Build working DC object
# Build a normalized DC object
$dcComputer = $null
try {
    # Try to find the computer object; prefer DNSHostName for matching DNS
    $dcComputer = Get-ADComputer -Identity $targetDC.Name -ErrorAction SilentlyContinue -Properties DNSHostName
    if (-not $dcComputer -and $targetDC.HostName) {
        $shortName = ($targetDC.HostName -split '\.')[0]
        $dcComputer = Get-ADComputer -Filter "Name -eq '$shortName'" -ErrorAction SilentlyContinue -Properties DNSHostName
    }
} catch {
    $dcComputer = $null
}

$dc = [PSCustomObject]@{
    Name             = $targetDC.Name
    HostName         = if ($dcComputer -and $dcComputer.DNSHostName) { $dcComputer.DNSHostName } else { $targetDC.HostName }
    ComputerObjectDN = if ($dcComputer) { $dcComputer.DistinguishedName } else { $null }
    IPv4Address      = $targetDC.IPv4Address
    Site             = $targetDC.Site
    IsGlobalCatalog  = $targetDC.IsGlobalCatalog
}

Write-Host ""
Write-Host "Working DC object:" -ForegroundColor Cyan
$dc | Format-List
#endregion Build working DC object

#region AD metadata cleanup (Sites & computer object)
Write-Host ""
Write-Host "=== Step 1: AD metadata cleanup (Sites & Services + computer object) ===" -ForegroundColor Cyan

# 1. Remove Sites & Services server object (and NTDS Settings) if present
$configNC  = $rootDse.ConfigurationNamingContext
$sitesBase = "CN=Sites,$configNC"
$shortName = ($dc.HostName -split '\.')[0]

Write-Host "Searching Sites & Services for server object '$shortName'..."
try {
    $serverObjects = Get-ADObject -LDAPFilter "(&(objectClass=server)(cn=$shortName))" `
                                  -SearchBase $sitesBase `
                                  -SearchScope Subtree `
                                  -ErrorAction Stop
} catch {
    Write-Warning "Error querying Sites & Services: $($_.Exception.Message)"
    $serverObjects = @()
}

if ($serverObjects -and $serverObjects.Count -gt 0) {
    foreach ($srv in $serverObjects) {
        if ($PSCmdlet.ShouldProcess($srv.DistinguishedName, "Remove Sites & Services server object (and children)")) {
            try {
                Remove-ADObject -Identity $srv.DistinguishedName -Recursive -Confirm:$false -ErrorAction Stop
                Write-Host "Removed Sites & Services server object: $($srv.DistinguishedName)" -ForegroundColor Green
            } catch {
                Write-Warning "Failed to remove server object '$($srv.DistinguishedName)': $($_.Exception.Message)"
            }
        }
    }
} else {
    Write-Host "No Sites & Services server objects found for '$shortName' (may already be removed)." -ForegroundColor DarkGray
}

# 2. Remove DC computer object if still present
if ($dc.ComputerObjectDN) {
    Write-Host "Checking for computer object: $($dc.ComputerObjectDN)"
    try {
        $compCheck = Get-ADComputer -Identity $dc.ComputerObjectDN -ErrorAction Stop
        if ($compCheck) {
            if ($PSCmdlet.ShouldProcess($dc.ComputerObjectDN, "Remove-ADComputer")) {
                Remove-ADComputer -Identity $dc.ComputerObjectDN -Confirm:$false -ErrorAction Stop
                Write-Host "Computer object removed: $($dc.ComputerObjectDN)" -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "Computer object for '$($dc.Name)' not found or already removed."
    }
} else {
    Write-Host "No computer DN recorded for this DC; skipping computer object removal." -ForegroundColor DarkGray
}
#endregion AD metadata cleanup

#region DFSR cleanup (SYSVOL memberships)
Write-Host ""
Write-Host "=== Step 2: DFSR SYSVOL membership cleanup ===" -ForegroundColor Cyan

if ($dc.ComputerObjectDN) {
    $dfsrBase = "CN=DFSR-GlobalSettings,CN=System,$($domain.DistinguishedName)"
    Write-Host "Searching DFSR memberships under: $dfsrBase"

    try {
        # Members use msDFSR-ComputerReference to point at the computer object
        $dfsrMembers = Get-ADObject -LDAPFilter "(msDFSR-ComputerReference=$($dc.ComputerObjectDN))" `
                                    -SearchBase $dfsrBase `
                                    -SearchScope Subtree `
                                    -Properties msDFSR-ComputerReference `
                                    -ErrorAction Stop
    } catch {
        Write-Warning "Error querying DFSR-GlobalSettings: $($_.Exception.Message)"
        $dfsrMembers = @()
    }

    if ($dfsrMembers -and $dfsrMembers.Count -gt 0) {
        foreach ($member in $dfsrMembers) {
            if ($PSCmdlet.ShouldProcess($member.DistinguishedName, "Remove DFSR member (SYSVOL)")) {
                try {
                    Remove-ADObject -Identity $member.DistinguishedName -Recursive -Confirm:$false -ErrorAction Stop
                    Write-Host "Removed DFSR member object: $($member.DistinguishedName)" -ForegroundColor Green
                } catch {
                    Write-Warning "Failed to remove DFSR member '$($member.DistinguishedName)': $($_.Exception.Message)"
                }
            }
        }
    } else {
        Write-Host "No DFSR membership objects found for this DC." -ForegroundColor DarkGray
    }
} else {
    Write-Host "No computer DN available; cannot match DFSR memberships." -ForegroundColor DarkGray
}
#endregion DFSR cleanup

#region DNS cleanup
if (-not $SkipDnsCleanup) {
    Write-Host ""
    Write-Host "=== Step 3: DNS cleanup on server '$DnsServer' ===" -ForegroundColor Cyan

    $dcFqdn      = $dc.HostName.ToLower()
    $dcHostShort = ($dcFqdn -split '\.')[0]
    $dcIp        = $dc.IPv4Address

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

            $matchingRecs = $records | Where-Object {
                $isMatch = $false

                switch ($_.RecordType) {
                    'A' {
                        if ($dcIp -and $_.RecordData.IPv4Address.ToString() -eq $dcIp) { $isMatch = $true }
                        if (-not $isMatch -and $_.HostName -ieq $dcHostShort) { $isMatch = $true }
                    }
                    'AAAA' {
                        if ($_.HostName -ieq $dcHostShort) { $isMatch = $true }
                    }
                    'SRV' {
                        if ($_.RecordData.DomainName.ToLower() -eq $dcFqdn) {
                            $isMatch = $true
                        }
                    }
                    'PTR' {
                        if ($_.RecordData.PtrDomainName.ToLower() -eq $dcFqdn) {
                            $isMatch = $true
                        }
                    }
                    'CNAME' {
                        if ($_.RecordData.HostNameAlias.ToLower() -eq $dcFqdn) {
                            $isMatch = $true
                        }
                    }
                    'NS' {
                        if ($_.RecordData.NameServer.ToLower() -eq $dcFqdn) {
                            $isMatch = $true
                        }
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

#region Reference scan (optional AD search for lingering references)
Write-Host ""
Write-Host "=== Step 4: AD reference scan (FQDN/computer DN) ===" -ForegroundColor Cyan

$dcFqdn = $dc.HostName.ToLower()
$ldapFilters = @()

# Only add DN-based filters if we actually know the computer DN
if ($dc.ComputerObjectDN) {
    $escapedDN = $dc.ComputerObjectDN
    $ldapFilters += "(msDS-ComputerReferenceDN=$escapedDN)"
    $ldapFilters += "(msDFSR-ComputerReference=$escapedDN)"
}

# String-based filters using FQDN
$escapedFqdn = $dcFqdn
$ldapFilters += "(dnsHostName=$escapedFqdn)"
$ldapFilters += "(serviceBindingInformation=*$escapedFqdn*)"
$ldapFilters += "(url=*$escapedFqdn*)"
$ldapFilters += "(targetAddress=*$escapedFqdn*)"

if ($ldapFilters.Count -gt 0) {
    $ldapFilter = "(|" + ($ldapFilters -join '') + ")"

    $searchBases = @(
        $domain.DistinguishedName,
        $rootDse.ConfigurationNamingContext
    )

    $foundObjects = @()

    foreach ($base in $searchBases) {
        Write-Host "Scanning AD for references under: $base"
        try {
            $objs = Get-ADObject -LDAPFilter $ldapFilter `
                                 -SearchBase $base `
                                 -SearchScope Subtree `
                                 -Properties dnsHostName,serviceBindingInformation,msDS-ComputerReferenceDN,msDFSR-ComputerReference,url,targetAddress `
                                 -ErrorAction Stop
            if ($objs) {
                $foundObjects += $objs
            }
        } catch {
            Write-Warning "Error searching '$base': $($_.Exception.Message)"
        }
    }

    # Deduplicate by DN
    if ($foundObjects.Count -gt 0) {
        $foundObjects = $foundObjects | Sort-Object DistinguishedName -Unique

        Write-Host ""
        Write-Host "Found the following AD objects still referencing this DC (by FQDN/DN):" -ForegroundColor Yellow
        $foundObjects | Select-Object DistinguishedName, ObjectClass, dnsHostName, msDS-ComputerReferenceDN, msDFSR-ComputerReference, url, targetAddress |
            Format-Table -AutoSize

        Write-Host ""
        $answer = Read-Host "Do you want to DELETE ALL of these objects as well? Type 'YES DELETE' to proceed, anything else to skip"
        if ($answer -eq 'YES DELETE') {
            foreach ($obj in $foundObjects) {
                if ($PSCmdlet.ShouldProcess($obj.DistinguishedName, "Remove AD object (reference cleanup)")) {
                    try {
                        Remove-ADObject -Identity $obj.DistinguishedName -Confirm:$false -ErrorAction Stop
                        Write-Host "Removed AD object: $($obj.DistinguishedName)" -ForegroundColor Green
                    } catch {
                        Write-Warning "Failed to remove AD object '$($obj.DistinguishedName)': $($_.Exception.Message)"
                    }
                }
            }
        } else {
            Write-Host "Skipping deletion of these additional reference objects." -ForegroundColor Yellow
        }
    } else {
        Write-Host "No additional AD objects found referencing this DC by those attributes." -ForegroundColor Green
    }
} else {
    Write-Host "No usable filters built for reference scan (missing FQDN/DN)." -ForegroundColor DarkGray
}
#endregion Reference scan

Write-Host ""
Write-Host "=== Offline DC metadata cleanup script completed. Review output for any warnings/errors. ===" -ForegroundColor Cyan
