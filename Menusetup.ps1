Add-Type -AssemblyName System.Windows.Forms

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