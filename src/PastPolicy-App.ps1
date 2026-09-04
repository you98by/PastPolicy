# src/PastPolicy-App.ps1

# ==========================================
# 1. ADMIN CHECK & SETUP
# ==========================================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$script:assetsDir = "$PSScriptRoot\..\assets"
$script:gpUserPath = "C:\Windows\System32\GroupPolicyUsers"
$script:policyDef = "C:\Windows\PolicyDefinitions"

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

# ==========================================
# 2. MODERN DARK THEME COLORS
# ==========================================
$script:BG = [System.Drawing.ColorTranslator]::FromHtml("#1E1E1E")
$script:SidebarBG = [System.Drawing.ColorTranslator]::FromHtml("#252526")
$script:Text = [System.Drawing.ColorTranslator]::FromHtml("#CCCCCC")
$script:Accent = [System.Drawing.ColorTranslator]::FromHtml("#007ACC")
$script:BtnBG = [System.Drawing.ColorTranslator]::FromHtml("#333333")
$script:Error = [System.Drawing.ColorTranslator]::FromHtml("#F44747")
$script:Success = [System.Drawing.ColorTranslator]::FromHtml("#4EC9B0")

# ==========================================
# 3. MAIN GUI LAYOUT
# ==========================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "PastPolicy - Group Policy Manager"
$form.Size = New-Object System.Drawing.Size(950, 650)
$form.StartPosition = "CenterScreen"
$form.BackColor = $script:BG
$form.ForeColor = $script:Text
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# Sidebar
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = "Left"
$sidebar.Width = 220
$sidebar.BackColor = $script:SidebarBG
$form.Controls.Add($sidebar)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "PastPolicy"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $script:Accent
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20, 25)
$sidebar.Controls.Add($lblTitle)

# Log Panel (Bottom)
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.Dock = "Bottom"
$logBox.Height = 180
$logBox.BackColor = $script:BG
$logBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#D4D4D4")
$logBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$logBox.ScrollBars = "Vertical"
$logBox.BorderStyle = "None"
$form.Controls.Add($logBox)

# Main Content Panel (Right)
$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = "Fill"
$mainPanel.BackColor = $script:BG
$mainPanel.Padding = New-Object System.Windows.Forms.Padding(30)
$form.Controls.Add($mainPanel)

# Welcome Text
$welcomeLbl = New-Object System.Windows.Forms.Label
$welcomeLbl.Text = "Welcome to PastPolicy.`n`nSelect an action from the sidebar to manage local user Group Policies.`n`nVersion 4.0 (Modern Rewrite)"
$welcomeLbl.AutoSize = $true
$welcomeLbl.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$mainPanel.Controls.Add($welcomeLbl)

# ==========================================
# 4. HELPER FUNCTIONS
# ==========================================
function Write-Log($msg, $color = "White") {
    $time = Get-Date -Format "HH:mm:ss"
    $logBox.SelectionColor = switch ($color) {
        "Red" { $script:Error }
        "Green" { $script:Success }
        default { $script:Text }
    }
    $logBox.AppendText("[$time] $msg`r`n")
    $logBox.ScrollToCaret()
}

function Get-LocalUsers {
    Get-LocalUser | Where-Object { $_.Enabled -eq $true -and $_.Name -notin @('DefaultAccount', 'Guest', 'WDAGUtilityAccount') }
}

function Get-PolicyUsers {
    if (!(Test-Path $script:gpUserPath)) { return @() }
    Get-ChildItem -Path $script:gpUserPath -Directory | Where-Object { $_.Name -match '^S-1-' } | ForEach-Object {
        $sid = $_.Name
        try {
            $user = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value
            [PSCustomObject]@{ SID = $sid; Name = $user.Split('\')[-1] }
        } catch {
            [PSCustomObject]@{ SID = $sid; Name = "Unknown ($sid)" }
        }
    }
}

function Show-ActionUI($title, $users, $onExecute) {
    $mainPanel.Controls.Clear()
    
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $title
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = $script:Accent
    $lbl.AutoSize = $true
    $lbl.Location = New-Object System.Drawing.Point(0, 0)
    $mainPanel.Controls.Add($lbl)
    
    if ($users.Count -eq 0) {
        $noData = New-Object System.Windows.Forms.Label
        $noData.Text = "No users found."
        $noData.ForeColor = $script:Error
        $noData.AutoSize = $true
        $noData.Location = New-Object System.Drawing.Point(0, 60)
        $mainPanel.Controls.Add($noData)
        return
    }

    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.DropDownStyle = "DropDownList"
    $cmb.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $cmb.Location = New-Object System.Drawing.Point(0, 50)
    $cmb.Size = New-Object System.Drawing.Size(400, 30)
    $cmb.BackColor = $script:BtnBG
    $cmb.ForeColor = $script:Text
    $cmb.FlatStyle = "Flat"
    foreach ($u in $users) { $cmb.Items.Add($u.Name) }
    $cmb.SelectedIndex = 0
    $mainPanel.Controls.Add($cmb)
    
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Execute"
    $btn.Size = New-Object System.Drawing.Size(120, 40)
    $btn.Location = New-Object System.Drawing.Point(0, 100)
    $btn.FlatStyle = "Flat"
    $btn.BackColor = $script:Accent
    $btn.ForeColor = "White"
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Add_Click({ 
        if ($cmb.SelectedItem) {
            $selectedUser = $users | Where-Object { $_.Name -eq $cmb.SelectedItem }
            & $onExecute $selectedUser
        }
    })
    $mainPanel.Controls.Add($btn)
}

function New-SideButton($text, $action) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Size = New-Object System.Drawing.Size(200, 45)
    $btn.Location = New-Object System.Drawing.Point(10, $script:y)
    $btn.FlatStyle = "Flat"
    $btn.BackColor = $script:BtnBG
    $btn.ForeColor = $script:Text
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $btn.TextAlign = "MiddleLeft"
    $btn.Padding = New-Object System.Windows.Forms.Padding(15, 0, 0, 0)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Add_MouseEnter({ $this.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#444444") })
    $btn.Add_MouseLeave({ $this.BackColor = $script:BtnBG })
    $btn.Add_Click($action)
    $sidebar.Controls.Add($btn)
    $script:y += 55
}

# ==========================================
# 5. CORE LOGIC (Converted from .bat)
# ==========================================
function Invoke-Install($user) {
    Write-Log "Starting Policy Installation for $($user.Name)..."
    
    # 1. Update Browser Templates
    Write-Log "Updating Browser Policy Templates..."
    foreach ($browser in @('Edge', 'Chrome')) {
        $srcDir = "$script:assetsDir\$browser"
        if (Test-Path $srcDir) {
            Copy-Item "$srcDir\*.admx" -Destination $script:policyDef -Force -ErrorAction SilentlyContinue
            Copy-Item "$srcDir\*.adml" -Destination "$script:policyDef\en-US" -Force -ErrorAction SilentlyContinue
            Write-Log "$browser templates updated." "Green"
        }
    }
    
    # 2. Deploy Policy
    $deploySrc = "$script:assetsDir\Deploy"
    $dest = "$script:gpUserPath\$($user.SID)"
    
    if (!(Test-Path $deploySrc)) {
        Write-Log "ERROR: assets\Deploy folder is empty or missing!" "Red"
        return
    }
    
    if (!(Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    
    Write-Log "Copying policies to $($user.Name)..."
    robocopy $deploySrc $dest /E /COPY:DAT /R:2 /W:1 /NP | Out-Null
    
    if ($LASTEXITCODE -lt 8) {
        Write-Log "Policy files copied successfully." "Green"
        Write-Log "Refreshing Group Policy (gpupdate)..."
        gpupdate /force | Out-Null
        Write-Log "Installation Complete!" "Green"
    } else {
        Write-Log "ERROR: Failed to copy files. Check antivirus or file locks." "Red"
    }
}

function Invoke-Edit($user) {
    Write-Log "Opening Policy Editor for $($user.Name)..."
    $templatePath = "$script:assetsDir\UserPolicyTemplate.msc"
    
    if (!(Test-Path $templatePath)) {
        Write-Log "ERROR: UserPolicyTemplate.msc not found in assets!" "Red"
        Write-Log "Please read assets\README_MSC.txt to create it." "Yellow"
        return
    }
    
    $tempMsc = "$env:TEMP\$($user.Name)_Policy.msc"
    Copy-Item $templatePath $tempMsc -Force
    powershell -NoProfile -Command "Unblock-File -Path '$tempMsc'" | Out-Null
    
    Start-Process mmc.exe -ArgumentList "`"$tempMsc`""
    Write-Log "MMC Opened for $($user.Name)." "Green"
}

function Invoke-Save($user) {
    Write-Log "WARNING: Closing MMC to prevent file locks..." "Yellow"
    taskkill /F /IM mmc.exe /T | Out-Null
    Start-Sleep -Seconds 2
    
    $src = "$script:gpUserPath\$($user.SID)"
    $dest = "$script:assetsDir\Deploy"
    
    if (!(Test-Path $src)) {
        Write-Log "ERROR: No policy found for $($user.Name)." "Red"
        return
    }
    
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    
    Write-Log "Exporting policy for $($user.Name) to assets\Deploy..."
    robocopy $src $dest /E /COPY:DAT /R:2 /W:1 /NP | Out-Null
    
    if ($LASTEXITCODE -lt 8) {
        Write-Log "Export Complete!" "Green"
    } else {
        Write-Log "ERROR: Export failed." "Red"
    }
}

function Invoke-Delete($user) {
    $path = "$script:gpUserPath\$($user.SID)"
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
        Write-Log "Deleted policy for $($user.Name)." "Green"
    } else {
        Write-Log "Policy folder not found for $($user.Name)." "Yellow"
    }
}

# ==========================================
# 6. SIDEBAR BUTTONS & LAUNCH
# ==========================================
$script:y = 90

New-SideButton "  1. Install Policies" { Show-ActionUI "Install Policies" (Get-LocalUsers) { Invoke-Install $args[0] } }
New-SideButton "  2. Edit Policies"    { Show-ActionUI "Edit Policies" (Get-LocalUsers) { Invoke-Edit $args[0] } }
New-SideButton "  3. Save Policies"    { Show-ActionUI "Save Policies" (Get-PolicyUsers) { Invoke-Save $args[0] } }
New-SideButton "  4. Delete Policies"  { Show-ActionUI "Delete Policies" (Get-PolicyUsers) { Invoke-Delete $args[0] } }

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
