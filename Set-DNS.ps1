#Set-DNSRecords -RecordSet "Prod"

function Set-DNSRecords {
    param (
        [Parameter(Mandatory)]
        [ValidateSet("Prod", "Dev", "Test", "SiteA", "SiteB")]
        [string]$RecordSet,

        [string]$DNSServer = 'localhost' #need to be able to point this to different DNSServers based on switch, something like Set-DNSRecords -DNSServer "Prod" -Recordset "ProdA"
    )

    # Define multiple record sets
    $recordSets = @{
        "Prod" = @(
            @{ RecordName = "prod-web01"; IPAddress = "10.0.0.10"; ZoneName = "prod.example.com" }
            @{ RecordName = "prod-db01";  IPAddress = "10.0.0.11"; ZoneName = "prod.example.com" }
        )
        "Dev" = @(
            @{ RecordName = "dev-web01"; IPAddress = "10.0.1.10"; ZoneName = "dev.example.com" }
            @{ RecordName = "dev-db01";  IPAddress = "10.0.1.11"; ZoneName = "dev.example.com" }
        )
        "Test" = @(
            @{ RecordName = "test-web01"; IPAddress = "10.0.2.10"; ZoneName = "test.example.com" }
            @{ RecordName = "test-db01";  IPAddress = "10.0.2.11"; ZoneName = "test.example.com" }
        )
        "SiteA" = @(
            @{ RecordName = "sitea-app01"; IPAddress = "192.168.1.100"; ZoneName = "sitea.local" }
        )
        "SiteB" = @(
            @{ RecordName = "siteb-app01"; IPAddress = "192.168.2.100"; ZoneName = "siteb.local" }
        )
    }

    # Retrieve the selected record set
    $dnsRecords = $recordSets[$RecordSet]

    if (-not $dnsRecords) {
        Write-Error "No DNS records found for RecordSet '$RecordSet'."
        return
    }

    foreach ($entry in $dnsRecords) {
        $name = $entry.RecordName
        $ip = $entry.IPAddress
        $zone = $entry.ZoneName

        try {
            Write-Host "`n🔍 Checking: $name.$zone => $ip" -ForegroundColor White

            $existingRecords = Get-DnsServerResourceRecord -Name $name -ZoneName $zone -ComputerName $DNSServer -ErrorAction SilentlyContinue |
                Where-Object { $_.RecordType -eq 'A' }

            $matchFound = $false

            foreach ($record in $existingRecords) {
                $currentIP = $record.RecordData.IPv4Address.IPAddressToString

                if ($currentIP -eq $ip) {
                    Write-Host "✔ A record for '$name.$zone' with IP '$ip' already exists." -ForegroundColor Green
                    $matchFound = $true
                }
                else {
                    Write-Host "⚠ Found '$name.$zone' with incorrect IP '$currentIP'. Deleting..." -ForegroundColor Yellow
                    Remove-DnsServerResourceRecord -ZoneName $zone -RRType "A" -Name $name -RecordData $currentIP -ComputerName $DNSServer -Force
                }
            }

            if (-not $matchFound) {
                Write-Host "➕ Creating A record '$name.$zone' with IP '$ip'..." -ForegroundColor Cyan
                Add-DnsServerResourceRecordA -Name $name -ZoneName $zone -IPv4Address $ip -ComputerName $DNSServer
                Write-Host "✅ Record created." -ForegroundColor Green
            }
        }
        catch {
            Write-Error "❌ Error processing $name.$zone: $_"
        }
    }
}
