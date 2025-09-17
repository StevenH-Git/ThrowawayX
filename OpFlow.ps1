Add-Type -AssemblyName System.Windows.Forms #Menu_dep

##################
# = CMD SYNTAX = #
##################

#Set-DNSRecords -RecordSet "Prod"
#Set-ADUsers -UserSet "HR" -VaultAddress $vaultAddr -VaultToken $vaultToken

###################
# === General === #
###################

# Error Logging

$Error.Clear()

function Send-Error {
    param (
        [string]$ErrorMessage
    )

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $FormattedMessageTime = "$TimeStamp - ERROR: $ErrorMessage"
    $DateString = Get-Date -Format "yyyy-MM-dd"
    $LogFilePath = "C:\logging\OpsFlow_ERR_$DateString.txt"
    $FormattedMessageTime | Out-File -Append $LogFilePath
}
#This causes more issues than it fixes in other foreach loops that need logging. Just call the function when you want and clear out the err.
#foreach ($err in $Error) {
#    $ErrorMessage = $err.Exception.Message
#    Send-Error $ErrorMessage
#}

###################
# ===== DNS ===== #
###################

function Set-DNSRecords {
    param (
        [Parameter(Mandatory)]
        [ValidateSet("Prod", "Dev", "Test", "SiteA", "SiteB")]
        [string]$DNSRecordSet

    )

# DNS server mapping for each record set
    $DNSServerMap = @{
        "Prod"  = "dns-prod.example.com"
        "Dev"   = "dns-dev.example.com"
        "Test"  = "dns-test.example.com"
        "SiteA" = "192.168.1.1"
        "SiteB" = "192.168.2.1"
    }

    $DNSServer = $DNSServerMap[$DNSRecordSet]

# Define multiple record sets
    $DNSRecordSets = @{
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
    $DNSRecords = $DNSRecordSets[$DNSRecordSet]

    if (-not $DNSRecords) {
        $Error.Clear()
        Write-Error "No DNS records found for RecordSet '$DNSRecordSet'."
        Send-Error
        return
    }

    foreach ($DNSEntry in $DNSRecords) {
        $DNSRecordName = $DNSEntry.RecordName
        $IPv4 = $DNSEntry.IPAddress
        $DNSZone = $DNSEntry.ZoneName

        try {
            Write-Host "`n🔍 Checking: $DNSRecordName.$DNSZone => $IPv4" -ForegroundColor White

            $DNSExistingRecords = Get-DnsServerResourceRecord -Name $DNSRecordName -ZoneName $DNSZone -ComputerName $DNSServer -ErrorAction SilentlyContinue |
                Where-Object { $_.RecordType -eq 'A' }

            $DNSMatchFound = $false

            foreach ($DNSRecord in $DNSExistingRecords) {
                $CurrentIPv4 = $DNSRecord.RecordData.IPv4Address.IPAddressToString

                if ($CurrentIPv4 -eq $IPv4) {
                    Write-Host "✔ A record for '$DNSRecordName.$DNSZone' with IP '$IPv4' already exists." -ForegroundColor Green
                    $DNSMatchFound = $true
                }
                else {
                    Write-Host "⚠ Found '$DNSRecordName.$DNSZone' with incorrect IP '$CurrentIPv4'. Deleting..." -ForegroundColor Yellow
                    Remove-DnsServerResourceRecord -ZoneName $DNSZone -RRType "A" -Name $DNSRecordName -RecordData $CurrentIPv4 -ComputerName $DNSServer -Force
                }
            }

            if (-not $DNSMatchFound) {
                Write-Host "➕ Creating A record '$DNSRecordName.$DNSZone' with IP '$IPv4'..." -ForegroundColor Cyan
                Add-DnsServerResourceRecordA -Name $DNSRecordName -ZoneName $DNSZone -IPv4Address $IPv4 -ComputerName $DNSServer
                Write-Host "✅ Record created." -ForegroundColor Green
            }
        }
        catch {
            Write-Error "❌ Error processing $DNSRecordName in $DNSZone at $IPv4"
        }
    }
}

###################
#== AD Accounts ==#
###################

#$vaultAddr = "https://vault.mycompany.com"
#$vaultToken = "s.xxxxxxxx"

function Get-VaultSecret {
    param (
        [Parameter(Mandatory)][string]$VaultAddress,
        [Parameter(Mandatory)][string]$VaultToken,
        [Parameter(Mandatory)][string]$SecretPath
    )

    $Headers = @{
        "X-Vault-Token" = $VaultToken
    }

    $URL = "$VaultAddress/v1/$SecretPath"

    try {
        $Response = Invoke-RestMethod -Uri $URL -Method Get -Headers $Headers
        return $Response.data.data  # For KV v2, OpenBAO may not use this. Need to verify.
    }
    catch {
        Write-Error "❌ Failed to get secret from Vault: $_"
        return $NULL
    }
}

function Set-ADUsers {
    param (
        [Parameter(Mandatory)]
        [ValidateSet("HR", "IT", "Finance")]
        [string]$ADUserSet,

        [Parameter(Mandatory)]
        [string]$VaultAddress,

        [Parameter(Mandatory)]
        [string]$VaultToken
    )

    # Define user structure (username and OU only)
    $ADUserSets = @{
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

    $ADUsers = $ADUserSets[$ADUserSet]

    if (-not $ADUsers) {
        $Error.Clear()
        Write-Error "No user vault found for $ADUserSet at $VaultAddress"
        return
    }

    foreach ($ADUser in $ADUsers) {
        $VaultKey = $ADUser.VaultKey
        $ADUserName = $ADUser.Name
        $OU = $ADUser.OU

        $VaultData = Get-VaultSecret -VaultAddress $VaultAddress -VaultToken $VaultToken -SecretPath $VaultKey

        if (-not $VaultData) {
            Write-Warning "⚠️ Skipping user at $VaultKey due to missing Vault data."
            continue
        }

        $SAM = $VaultData.username
        $PasswPlain = $VaultData.password
        $Passw = ConvertTo-SecureString $PasswPlain -AsPlainText -Force

        Write-Host "`n🔍 Checking AD user: $SAM ($ADUserName)" -ForegroundColor White

        $ExistingUser = Get-ADUser -Filter { SamAccountName -eq $SAM } -Properties DistinguishedName -ErrorAction SilentlyContinue

        if ($ExistingUser) {
            $CorrectOU = ($ExistingUser.DistinguishedName -like "*$OU*")

            if ($CorrectOU) {
                Write-Host "✔ User '$SAM' exists in correct OU." -ForegroundColor Green
                continue
            }
            else {
                Write-Host "⚠ User '$SAM' exists but is in the wrong OU. Deleting..." -ForegroundColor Yellow
                Remove-ADUser -Identity $ExistingUser.DistinguishedName -Confirm:$false
            }
        }
        else {
            Write-Host "❌ User '$SAM' not found." -ForegroundColor DarkYellow
        }

        # Create user
        try {
            Write-Host "➕ Creating user '$SAM' in '$OU'" -ForegroundColor Cyan
            New-ADUser `
                -SamAccountName $SAM `
                -Name $ADUserName `
                -UserPrincipalName "$SAM@example.com" ` #Here#ADdomain var needed
                -Path $OU `
                -AccountPassword $Passw `
                -Enabled $true `
                -PasswordNeverExpires $true

            Write-Host "✅ User '$SAM' created." -ForegroundColor Green
        }
        catch {
            Write-Host "❌ Failed to create user '$SAM': $_ [Logged]"
            Write-Error "Failed to create user '$SAM': $_"
            Send-Error
            $Error.Clear()
        }
    }
}
$Error.Clear()

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
    Write-Output "Running '$Choice' from '$MainSelection'"
    $ScriptBlock = $Menu[$MainSelection][$Choice]
    & $ScriptBlock
}




# NOTES #

#Store creds in vault, json format; EXAMPLE

#############
#{
#  "data": {
#    "username": "asmith",
#    "password": "P@ssw0rd123"
#  }
#}
##############