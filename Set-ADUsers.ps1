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
