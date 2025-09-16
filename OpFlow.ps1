Add-Type -AssemblyName System.Windows.Forms #Menu_dep

###################
# ===== DNS ===== #
###################

#Set-DNSRecords -RecordSet "Prod"

function Set-DNSRecords {
    param (
        [Parameter(Mandatory)]
        [ValidateSet("Prod", "Dev", "Test", "SiteA", "SiteB")]
        [string]$RecordSet

    )

# DNS server mapping for each record set
    $dnsServerMap = @{
        "Prod"  = "dns-prod.example.com"
        "Dev"   = "dns-dev.example.com"
        "Test"  = "dns-test.example.com"
        "SiteA" = "192.168.1.1"
        "SiteB" = "192.168.2.1"
    }

    $DNSServer = $dnsServerMap[$RecordSet]

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
            Write-Error "❌ Error processing $name"
        }
    }
}
###################
#== AD Accounts ==#
###################

#prereqs
#invoke-restmethod must work on host machine. test first.

#Store creds in vault, json format; EXAMPLE
#############
#{
#  "data": {
#    "username": "asmith",
#    "password": "P@ssw0rd123"
#  }
#}
##############
#Command
############## 
#Still need a good way to deal with token security. Maybe go cert based and service account?
#$vaultAddr = "https://vault.mycompany.com"
#$vaultToken = "s.xxxxxxxx"  # Load securely in practice!

#Set-ADUsers -UserSet "HR" -VaultAddress $vaultAddr -VaultToken $vaultToken
##############


function Get-VaultSecret {
    param (
        [Parameter(Mandatory)][string]$VaultAddress,
        [Parameter(Mandatory)][string]$VaultToken,
        [Parameter(Mandatory)][string]$SecretPath
    )

    $headers = @{
        "X-Vault-Token" = $VaultToken
    }

    $url = "$VaultAddress/v1/$SecretPath"

    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
        return $response.data.data  # For KV v2, OpenBAO may not use this. Need to verify.
    }
    catch {
        Write-Error "❌ Failed to get secret from Vault: $_"
        return $null
    }
}

function Set-ADUsers {
    param (
        [Parameter(Mandatory)]
        [ValidateSet("HR", "IT", "Finance")]
        [string]$UserSet,

        [Parameter(Mandatory)]
        [string]$VaultAddress,

        [Parameter(Mandatory)]
        [string]$VaultToken
    )

    # Define user structure (username and OU only)
    $userSets = @{
        "HR" = @(
            @{ VaultKey = "secret/data/ad_users/hr/asmith"; OU = "OU=HR,DC=example,DC=com"; Name = "Alice Smith" },
            @{ VaultKey = "secret/data/ad_users/hr/bjones"; OU = "OU=HR,DC=example,DC=com"; Name = "Bob Jones" }
        )
        "IT" = @(
            @{ VaultKey = "secret/data/ad_users/it/cadmin"; OU = "OU=IT,DC=example,DC=com"; Name = "Charlie Admin" }
        )
        "Finance" = @(
            @{ VaultKey = "secret/data/ad_users/finance/dcash"; OU = "OU=Finance,DC=example,DC=com"; Name = "Dana Cash" }
        )
    }

    $users = $userSets[$UserSet]

    if (-not $users) {
        Write-Error "No user set found for '$UserSet'"
        return
    }

    foreach ($user in $users) {
        $vaultKey = $user.VaultKey
        $name = $user.Name
        $ou = $user.OU

        $vaultData = Get-VaultSecret -VaultAddress $VaultAddress -VaultToken $VaultToken -SecretPath $vaultKey

        if (-not $vaultData) {
            Write-Warning "⚠️ Skipping user at $vaultKey due to missing Vault data."
            continue
        }

        $sam = $vaultData.username
        $passwPlain = $vaultData.password
        $passw = ConvertTo-SecureString $passwPlain -AsPlainText -Force

        Write-Host "`n🔍 Checking AD user: $sam ($name)" -ForegroundColor White

        $existing = Get-ADUser -Filter { SamAccountName -eq $sam } -Properties DistinguishedName -ErrorAction SilentlyContinue

        if ($existing) {
            $correctOU = ($existing.DistinguishedName -like "*$ou*")

            if ($correctOU) {
                Write-Host "✔ User '$sam' exists in correct OU." -ForegroundColor Green
                continue
            }
            else {
                Write-Host "⚠ User '$sam' exists but is in the wrong OU. Deleting..." -ForegroundColor Yellow
                Remove-ADUser -Identity $existing.DistinguishedName -Confirm:$false
            }
        }
        else {
            Write-Host "❌ User '$sam' not found." -ForegroundColor DarkYellow
        }

        # Create user
        try {
            Write-Host "➕ Creating user '$sam' in '$ou'" -ForegroundColor Cyan
            New-ADUser `
                -SamAccountName $sam `
                -Name $name `
                -UserPrincipalName "$sam@example.com" `
                -Path $ou `
                -AccountPassword $passw `
                -Enabled $true `
                -PasswordNeverExpires $true

            Write-Host "✅ User '$sam' created." -ForegroundColor Green
        }
        catch {
            Write-Error "❌ Failed to create user '$sam': $_"
        }
    }
}


####################
#====== Menu ======#
####################

#Define categories and sub-options with corresponding script/actions
$Menu = @{
    "Site1" = @{ "IP Config" = { ipconfig }; "Flush DNS" = { ipconfig /flushdns } }
    "Site2" = @{ "Get OS Version" = { Get-CimInstance Win32_OperatingSystem }; "Get CPU Info" = { Get-CimInstance Win32_Processor } }
    "Site3" = @{ "Check Disk Space" = { Get-PSDrive -PSProvider 'FileSystem' }; "Run CHKDSK" = { chkdsk } }
    "Site4" = @{ "List Users" = { Get-LocalUser }; "Check Logged-In User" = { whoami } }
    "Site5" = @{ "List Services" = { Get-Service }; "Restart Spooler" = { Restart-Service spooler } }
    "Site6" = @{ "List Processes" = { Get-Process }; "Kill Notepad" = { Stop-Process -Name notepad -ErrorAction SilentlyContinue } }
    "Site7" = @{ "Check Updates" = { UsoClient StartScan }; "Install Updates" = { UsoClient StartInstall } }
    "Site8" = @{ "Shutdown" = { Show-SingleSelectMenu }; "Restart" = { Restart-Computer } }
}

#Show a single-selection dialog (returns selected item)
function Show-SingleSelectMenu {
    param(
        [string]$Title,
        [string[]]$Options
    )
    $Form = New-Object Windows.Forms.Form
    $Form.Text = $Title
    $Form.Size = New-Object Drawing.Size(300,200)
    $Form.StartPosition = "CenterScreen"

    $Combo = New-Object Windows.Forms.ComboBox
    $Combo.Location = New-Object Drawing.Point(10,20)
    $Combo.Size = New-Object Drawing.Size(260,20)
    $Combo.DropDownStyle = 'DropDownList'
    $Combo.Items.AddRange($Options)
    $Combo.SelectedIndex = 0
    $Form.Controls.Add($Combo)

    $ConfirmButton = New-Object Windows.Forms.Button
    $ConfirmButton.Text = "Confirm"
    $ConfirmButton.DialogResult = [Windows.Forms.DialogResult]::OK
    $ConfirmButton.Location = New-Object Drawing.Point(100,70)
    $Form.Controls.Add($ConfirmButton)
    $Form.AcceptButton = $ConfirmButton

    if ($Form.ShowDialog() -eq "OK") {
        return $Combo.SelectedItem
    } else {
        return $NULL
    }
}

#Multi-select checklist dialog
function Show-MultiSelectMenu {
    param(
        [string]$Title,
        [string[]]$Options
    )
    $Form = New-Object Windows.Forms.Form
    $Form.Text = $Title
    $Form.Size = New-Object Drawing.Size(300,300)
    $Form.StartPosition = "CenterScreen"

    $CheckedListBox = New-Object Windows.Forms.CheckedListBox
    $CheckedListBox.Location = New-Object Drawing.Point(10,10)
    $CheckedListBox.Size = New-Object Drawing.Size(260,200)
    $CheckedListBox.CheckOnClick = $true
    $CheckedListBox.Items.AddRange($Options)
    $Form.Controls.Add($CheckedListBox)

    $ConfirmButton = New-Object Windows.Forms.Button
    $ConfirmButton.Text = "Execute"
    $ConfirmButton.DialogResult = [Windows.Forms.DialogResult]::OK
    $ConfirmButton.Location = New-Object Drawing.Point(100,220)
    $Form.Controls.Add($ConfirmButton)
    $Form.AcceptButton = $ConfirmButton

    if ($Form.ShowDialog() -eq "OK") {
        return $CheckedListBox.CheckedItems
    } else {
        return @()
    }
}

# Step 1: Show main menu
$MainSelection = Show-SingleSelectMenu -Title "Select a System" -Options $Menu.Keys
if (-not $MainSelection) { exit
#Triggers if users cancels, need to write an if elseif for this;   [System.Windows.Forms.MessageBox]::Show("You must select a target.", "NO TARGET SELECTED...", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}


# Step 2: Show multi-select sub-options
$SubOptions = $Menu[$MainSelection].Keys
$SubSelection = Show-MultiSelectMenu -Title "Select Action(s) for $MainSelection" -Options $SubOptions

if ($SubSelection.Count -eq 0)  {
    [System.Windows.Forms.MessageBox]::Show("You must select at least one action.", "NO ACTION(s) SELECTED...", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}

# Step 3: Run selected scripts
foreach ($Choice in $SubSelection) {
    Write-Host "`n--- Running '$Choice' from '$MainSelection' ---"
    $ScriptBlock = $Menu[$MainSelection][$Choice]
    & $ScriptBlock
}