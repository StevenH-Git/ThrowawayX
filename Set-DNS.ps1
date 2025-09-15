function Set-DNSRecords {
    param (
        [string]$DNSServer = 'localhost'
    )

    # Define the list of desired DNS records here
    $dnsRecords = @(
        @{ RecordName = "web01"; IPAddress = "192.168.10.11"; ZoneName = "example.com" }
        @{ RecordName = "db01";  IPAddress = "192.168.10.12"; ZoneName = "example.com" }
        @{ RecordName = "mail";  IPAddress = "192.168.10.13"; ZoneName = "example.com" }
    )

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
            Write-Error "❌ Error processing $name"
        }
    }
}
