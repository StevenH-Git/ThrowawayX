function Set-DNSRecords {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Prod','Dev','Test','SiteA','SiteB')]
        [string]$RecordSet,
        [switch]$SkipA,
        [switch]$SkipCName
    )

    $dnsServerMap = @{
        Prod  = 'dns01.corp.local'
        Dev   = 'dns02.corp.local'
        Test  = 'dns03.corp.local'
        SiteA = 'dns-sitea.corp.local'
        SiteB = 'dns-siteb.corp.local'
    }
    if (-not $dnsServerMap.ContainsKey($RecordSet)) { throw "No DNS server mapped for set '$RecordSet'." }
    $DNSServer = $dnsServerMap[$RecordSet]

    # A records
    $desiredA = switch ($RecordSet) {
        'Prod' {
            @(
                @{ Name='app01'; ZoneName='corp.local'; IP='10.0.1.50' }
                @{ Name='db01';  ZoneName='corp.local'; IP='10.0.1.60' }
            )
        }
        'Dev'  { @(@{ Name='app01'; ZoneName='dev.corp.local'; IP='10.10.1.50' }) }
        'Test' { @(@{ Name='app01'; ZoneName='test.corp.local'; IP='10.20.1.50' }) }
        'SiteA'{ @(@{ Name='print'; ZoneName='sitea.corp.local'; IP='10.30.0.20' }) }
        'SiteB'{ @(@{ Name='print'; ZoneName='siteb.corp.local'; IP='10.40.0.20' }) }
    }

    # CNAME records
    $desiredCName = switch ($RecordSet) {
        'Prod' {
            @(
                @{ Name='app';     ZoneName='corp.local'; AliasTarget='app-web.prod.corp.local' }
                @{ Name='files';   ZoneName='corp.local'; AliasTarget='nas01.prod.corp.local' }
                @{ Name='reports'; ZoneName='corp.local'; AliasTarget='bi01.prod.corp.local' }
            )
        }
        'Dev'  { @(@{ Name='app'; ZoneName='dev.corp.local'; AliasTarget='app-web.dev.corp.local' }) }
        'Test' { @(@{ Name='app'; ZoneName='test.corp.local'; AliasTarget='app-web.test.corp.local' }) }
        'SiteA'{ @(@{ Name='print'; ZoneName='sitea.corp.local'; AliasTarget='print01.sitea.corp.local' }) }
        'SiteB'{ @(@{ Name='print'; ZoneName='siteb.corp.local'; AliasTarget='print01.siteb.corp.local' }) }
    }

    function _NormalizeFqdn([string]$fqdn) {
        if ([string]::IsNullOrWhiteSpace($fqdn)) { return $fqdn }
        $fqdn.TrimEnd('.').ToLowerInvariant()
    }

    $changes = @()

    if (-not $SkipA) {
        foreach ($r in $desiredA) {
            $name = $r.Name
            $zone = $r.ZoneName
            $ip   = [ipaddress]$r.IP

            $existing = Get-DnsServerResourceRecord -ComputerName $DNSServer -ZoneName $zone -Name $name -RRType A -ErrorAction SilentlyContinue

            $hasMatch = $false
            if ($existing) {
                foreach ($ex in $existing) {
                    if ($ex.RecordData.IPv4Address -and $ex.RecordData.IPv4Address.ToString() -eq $ip.IPAddressToString) { $hasMatch = $true; break }
                }
            }
            if ($hasMatch) { continue }

            if ($existing) {
                foreach ($ex in $existing) {
                    $cur = if ($ex.RecordData.IPv4Address) { $ex.RecordData.IPv4Address.ToString() } else { '' }
                    if ($PSCmdlet.ShouldProcess("$DNSServer", "Remove stale A $name.$zone -> $cur")) {
                        Remove-DnsServerResourceRecord -ComputerName $DNSServer -ZoneName $zone -InputObject $ex -Force -ErrorAction Stop
                        $changes += [pscustomobject]@{ Type='A'; Action='Removed'; Name="$name.$zone"; Value=$cur; Server=$DNSServer; Zone=$zone }
                    }
                }
            }

            if ($PSCmdlet.ShouldProcess("$DNSServer", "Add A $name.$zone -> $($ip.IPAddressToString)")) {
                Add-DnsServerResourceRecordA -ComputerName $DNSServer -ZoneName $zone -Name $name -IPv4Address $ip.IPAddressToString -ErrorAction Stop
                $changes += [pscustomobject]@{ Type='A'; Action='Added'; Name="$name.$zone"; Value=$ip.IPAddressToString; Server=$DNSServer; Zone=$zone }
            }
        }
    }

    if (-not $SkipCName) {
        foreach ($r in $desiredCName) {
            $name  = $r.Name
            $zone  = $r.ZoneName
            $alias = _NormalizeFqdn $r.AliasTarget

            $existing = Get-DnsServerResourceRecord -ComputerName $DNSServer -ZoneName $zone -Name $name -RRType CNAME -ErrorAction SilentlyContinue

            $match = $null
            if ($existing) {
                foreach ($ex in $existing) {
                    $cur = _NormalizeFqdn $ex.RecordData.HostNameAlias
                    if ($cur -eq $alias) { $match = $ex; break }
                }
            }
            if ($match) { continue }

            if ($existing) {
                foreach ($ex in $existing) {
                    $cur = _NormalizeFqdn $ex.RecordData.HostNameAlias
                    if ($PSCmdlet.ShouldProcess("$DNSServer", "Remove stale CNAME $name.$zone -> $cur")) {
                        Remove-DnsServerResourceRecord -ComputerName $DNSServer -ZoneName $zone -InputObject $ex -Force -ErrorAction Stop
                        $changes += [pscustomobject]@{ Type='CNAME'; Action='Removed'; Name="$name.$zone"; Value=$cur; Server=$DNSServer; Zone=$zone }
                    }
                }
            }

            if ($PSCmdlet.ShouldProcess("$DNSServer", "Add CNAME $name.$zone -> $alias")) {
                Add-DnsServerResourceRecordCName -ComputerName $DNSServer -ZoneName $zone -Name $name -HostNameAlias $alias -ErrorAction Stop
                $changes += [pscustomobject]@{ Type='CNAME'; Action='Added'; Name="$name.$zone"; Value=$alias; Server=$DNSServer; Zone=$zone }
            }
        }
    }

    if ($changes.Count -gt 0) { $changes } else { [pscustomobject]@{ Action='NoChange'; Server=$DNSServer; Set=$RecordSet } }
}
