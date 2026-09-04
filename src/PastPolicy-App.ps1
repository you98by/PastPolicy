# src/PastPolicy-App.ps1

# ==========================================
# 1. ADMIN CHECK & WORKSPACE SETUP
# ==========================================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$script:workDir = "C:\PastPolicy"
$script:assetsDir = "$PSScriptRoot\..\assets"
$script:gpUserPath = "C:\Windows\System32\GroupPolicyUsers"

@("$script:workDir\Logs", "$script:workDir\States") | ForEach-Object {
    if (!(Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

# ==========================================
# 2. THEME & POLICY DEFINITIONS
# ==========================================
$script:BG = [System.Drawing.ColorTranslator]::FromHtml("#1E1E1E")
$script:SidebarBG = [System.Drawing.ColorTranslator]::FromHtml("#252526")
$script:Text = [System.Drawing.ColorTranslator]::FromHtml("#CCCCCC")
$script:Accent = [System.Drawing.ColorTranslator]::FromHtml("#007ACC")
$script:BtnBG = [System.Drawing.ColorTranslator]::FromHtml("#333333")
$script:ErrorColor = [System.Drawing.ColorTranslator]::FromHtml("#F44747") # FIXED VARIABLE NAME
$script:Success = [System.Drawing.ColorTranslator]::FromHtml("#4EC9B0")

# Define the policies we can toggle via checkboxes
$script:Policies = @(
    @{ Name = "Disable Task Manager"; Key = "Software\Microsoft\Windows\CurrentVersion\Policies\System"; ValueName = "DisableTaskMgr"; Checked = 1; Unchecked = 0 },
    @{ Name = "Disable Registry Editor"; Key = "Software\Microsoft\Windows\CurrentVersion\Policies\System"; ValueName = "DisableRegistryTools"; Checked = 1; Unchecked = 0 },
    @{ Name = "Disable Command Prompt"; Key = "Software\Microsoft\Windows\CurrentVersion\Policies\System"; ValueName = "DisableCMD"; Checked = 2; Unchecked = 0 },
    @{ Name = "Disable Control Panel"; Key = "Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; ValueName = "NoControlPanel"; Checked = 1; Unchecked = 0 }
)

# ==========================================
# 3. MAIN GUI LAYOUT
# ==========================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "PastPolicy - Ultimate Policy Manager"
$form.Size = New-Object System.Drawing.Size(1000, 750)
$form.StartPosition = "CenterScreen"
$form.BackColor = $script:BG
$form.ForeColor = $script:Text
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = "Left"; $sidebar.Width = 220; $sidebar.BackColor = $script:SidebarBG
$form.Controls.Add($sidebar)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "PastPolicy"; $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $script:Accent; $lblTitle.AutoSize = $true; $lblTitle.Location = New-Object System.Drawing.Point(20, 25)
$sidebar.Controls.Add($lblTitle)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.Dock = "Bottom"; $logBox.Height = 150
$logBox.BackColor = $script:BG; $logBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#D4D4D4")
$logBox.Font = New-Object System.Drawing.Font("Consolas", 10); $logBox.ScrollBars = "Vertical"; $logBox.BorderStyle = "None"
$form.Controls.Add($logBox)

$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = "Fill"; $mainPanel.BackColor = $script:BG; $mainPanel.Padding = New-Object System.Windows.Forms.Padding(30)
$mainPanel.AutoScroll = $true # FIX: Prevents overlapping by adding a scrollbar if content is too long
$form.Controls.Add($mainPanel)

# ==========================================
# 4. HELPER & REGISTRY FUNCTIONS
# ==========================================
function Write-Log($msg, $color = "White") {
    $time = Get-Date -Format "HH:mm:ss"
    $logBox.SelectionColor = switch ($color) { "Red" { $script:ErrorColor }; "Green" { $script:Success }; "Yellow" { "Yellow" } default { $script:Text } }
    $logBox.AppendText("[$time] $msg`r`n"); $logBox.ScrollToCaret()
    Add-Content -Path "$script:workDir\Logs\PastPolicy_Log.txt" -Value "[$time] $msg"
}

function Get-LocalUsers {
    Get-LocalUser | Where-Object { $_.Enabled -eq $true -and $_.Name -notin @('DefaultAccount', 'Guest', 'WDAGUtilityAccount') }
}

function Load-UserHive($sid, $username) {
    $hive = "HKU\$sid"
    $ntuser = "C:\Users\$username\NTUSER.DAT"
    if (!(Test-Path "Registry::$hive") -and (Test-Path $ntuser)) { reg load $hive $ntuser 2>$null }
}

function Unload-UserHive($sid) { reg unload "HKU\$sid" 2>$null }

function Get-UserPolicyState($sid, $username) {
    Load-UserHive $sid $username
    $state = @{}
    foreach ($pol in $script:Policies) {
        $path = "Registry::HKEY_USERS\$sid\$($pol.Key)"
        $val = Get-ItemProperty -Path $path -Name $pol.ValueName -ErrorAction SilentlyContinue
        $state[$pol.Name] = ($val.($pol.ValueName) -eq $pol.Checked)
    }
    $urlPath = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"
    $urls = @()
    if (Test-Path $urlPath) {
        Get-ChildItem $urlPath -ErrorAction SilentlyContinue | ForEach-Object {
            $v = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($v.'*' -eq 4) { $urls += $_.PSChildName }
        }
    }
    $state["BlockedURLs"] = $urls
    Unload-UserHive $sid
    return $state
}

function Set-UserPolicyState($sid, $username, $state) {
    Load-UserHive $sid $username
    foreach ($pol in $script:Policies) {
        $path = "Registry::HKEY_USERS\$sid\$($pol.Key)"
        if (!(Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        $val = if ($state[$pol.Name]) { $pol.Checked } else { $pol.Unchecked }
        Set-ItemProperty -Path $path -Name $pol.ValueName -Value $val -Type DWORD -Force
    }
    $urlBase = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"
    if (Test-Path $urlBase) { Remove-Item -Path $urlBase -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($url in $state["BlockedURLs"]) {
        if ($url.Trim()) {
            $urlPath = "$urlBase\$($url.Trim())"
            New-Item -Path $urlPath -Force | Out-Null
            Set-ItemProperty -Path $urlPath -Name "*" -Value 4 -Type DWORD -Force
        }
    }
    Unload-UserHive $sid
}

# ==========================================
# 5. AUTO BACKUP (Now includes JSON Snapshot)
# ==========================================
function Invoke-AutoBackup {
    $backupDir = "$script:workDir\States\AutoBackup_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    
    if (Test-Path $script:gpUserPath) {
        Copy-Item $script:gpUserPath -Destination "$backupDir\GroupPolicyUsers" -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    $snapshot = @{}
    Get-LocalUsers | ForEach-Object {
        $snapshot[$_.Name] = Get-UserPolicyState $_.SID $_.Name
    }
    $snapshot | ConvertTo-Json -Depth 5 | Out-File "$backupDir\policy_snapshot.json" -Encoding UTF8
    Write-Log "Auto-backup created: $backupDir" "Green"
}

# ==========================================
# 6. UI BUILDERS
# ==========================================
function Clear-Main { 
    $mainPanel.Controls.Clear()
    $script:y = 0 
    $script:CheckBoxes = @{}
}

function Add-Title($text) {
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = $text
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = $script:Accent; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($lbl); $script:y += 40
}

function Add-UserDropdown() {
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "Target User:"; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($lbl); $script:y += 25
    
    $cmb = New-Object System.Windows.Forms.ComboBox; $cmb.Name = "UserCombo"
    $cmb.DropDownStyle = "DropDownList"; $cmb.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $cmb.Location = New-Object System.Drawing.Point(0, $script:y); $cmb.Size = New-Object System.Drawing.Size(350, 30)
    $cmb.BackColor = $script:BtnBG; $cmb.ForeColor = $script:Text; $cmb.FlatStyle = "Flat"
    Get-LocalUsers | ForEach-Object { $cmb.Items.Add("$($_.Name) ($($_.SID))") }
    if ($cmb.Items.Count -gt 0) { $cmb.SelectedIndex = 0 }
    $mainPanel.Controls.Add($cmb); $script:y += 45
    return $cmb
}

function Add-Button($text, $action, $color = $script:Accent, $width = 140) {
    $btn = New-Object System.Windows.Forms.Button; $btn.Text = $text
    $btn.Size = New-Object System.Drawing.Size($width, 35); $btn.Location = New-Object System.Drawing.Point($script:xOffset, $script:y)
    $btn.FlatStyle = "Flat"; $btn.BackColor = $color; $btn.ForeColor = "White"
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Add_Click($action)
    $mainPanel.Controls.Add($btn)
    $script:xOffset += ($width + 15)
    return $btn
}

# ==========================================
# 7. PAGES
# ==========================================
function Show-Dashboard {
    Clear-Main; Add-Title "Dashboard"
    $info = New-Object System.Windows.Forms.Label
    $info.Text = "Welcome to PastPolicy.`n`nWorkspace: $script:workDir`nAuto-Backup: Enabled on Launch`n`nUse the 'Policy Workspace' to manage users, block URLs, or deploy policies.`nChanges are applied directly to the user's registry hive instantly."
    $info.Font = New-Object System.Drawing.Font("Segoe UI", 12); $info.AutoSize = $true; $info.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($info)
}

function Show-PolicyWorkspace {
    Clear-Main; Add-Title "Policy Workspace"
    $cmb = Add-UserDropdown
    
    $script:y += 10
    $lblPol = New-Object System.Windows.Forms.Label; $lblPol.Text = "System Policies:"; $lblPol.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $lblPol.AutoSize = $true; $lblPol.Location = New-Object System.Drawing.Point(0, $script:y); $mainPanel.Controls.Add($lblPol); $script:y += 30
    
    foreach ($pol in $script:Policies) {
        $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $pol.Name
        $cb.Location = New-Object System.Drawing.Point(10, $script:y); $cb.AutoSize = $true
        $cb.ForeColor = $script:Text; $cb.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        $mainPanel.Controls.Add($cb)
        $script:CheckBoxes[$pol.Name] = $cb
        $script:y += 30
    }
    
    $script:y += 15
    $lblUrls = New-Object System.Windows.Forms.Label; $lblUrls.Text = "Blocked Websites (One per line):"; $lblUrls.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $lblUrls.AutoSize = $true; $lblUrls.Location = New-Object System.Drawing.Point(0, $script:y); $mainPanel.Controls.Add($lblUrls); $script:y += 30
    
    $txtUrls = New-Object System.Windows.Forms.TextBox; $txtUrls.Name = "TxtUrls"
    $txtUrls.Multiline = $true; $txtUrls.Location = New-Object System.Drawing.Point(10, $script:y)
    $txtUrls.Size = New-Object System.Drawing.Size(400, 100); $txtUrls.BackColor = $script:BtnBG; $txtUrls.ForeColor = $script:Text
    $txtUrls.Font = New-Object System.Drawing.Font("Consolas", 10)
    $mainPanel.Controls.Add($txtUrls); $script:y += 120
    
    $script:y += 20; $script:xOffset = 0
    Add-Button "Apply Changes" {
        $sel = $cmb.SelectedItem; if (!$sel) { return }
        $name = $sel.Split(' ')[0]; $sid = $sel.Split('(')[1].Trim(')')
        $state = @{}
        foreach ($pol in $script:Policies) { $state[$pol.Name] = $script:CheckBoxes[$pol.Name].Checked }
        $state["BlockedURLs"] = $txtUrls.Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        Set-UserPolicyState $sid $name $state
        Write-Log "Policies applied to $name." "Green"
    }
    
    Add-Button "Discard" {
        Load-CurrentState $cmb
    } $script:BtnBG
    
    Add-Button "Restore State" {
        Show-RestoreDialog $cmb
    } $script:ErrorColor
    
    # Load initial state when user is selected
    $cmb.Add_SelectedIndexChanged({ Load-CurrentState $this })
    if ($cmb.Items.Count -gt 0) { Load-CurrentState $cmb }
}

function Load-CurrentState($cmb) {
    $sel = $cmb.SelectedItem; if (!$sel) { return }
    $name = $sel.Split(' ')[0]; $sid = $sel.Split('(')[1].Trim(')')
    $state = Get-UserPolicyState $sid $name
    foreach ($pol in $script:Policies) {
        if ($script:CheckBoxes.ContainsKey($pol.Name)) {
            $script:CheckBoxes[$pol.Name].Checked = $state[$pol.Name]
        }
    }
    $txtUrls = $mainPanel.Controls.Find("TxtUrls", $true)[0]
    if ($txtUrls) { $txtUrls.Text = ($state["BlockedURLs"] -join "`r`n") }
}

function Show-RestoreDialog($cmb) {
    $sel = $cmb.SelectedItem; if (!$sel) { return }
    $name = $sel.Split(' ')[0]; $sid = $sel.Split('(')[1].Trim(')')
    
    $backups = Get-ChildItem "$script:workDir\States" -Directory | Sort-Object Name -Descending
    if ($backups.Count -eq 0) { Write-Log "No backups found." "Yellow"; return }
    
    $formRestore = New-Object System.Windows.Forms.Form
    $formRestore.Text = "Restore State"; $formRestore.Size = New-Object System.Drawing.Size(400, 300)
    $formRestore.StartPosition = "CenterScreen"; $formRestore.BackColor = $script:BG; $formRestore.ForeColor = $script:Text
    
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "Select Backup for $name :"; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(20, 20)
    $formRestore.Controls.Add($lbl)
    
    $lst = New-Object System.Windows.Forms.ListBox; $lst.Location = New-Object System.Drawing.Point(20, 50)
    $lst.Size = New-Object System.Drawing.Size(340, 150); $lst.BackColor = $script:BtnBG; $lst.ForeColor = $script:Text
    $backups | ForEach-Object { $lst.Items.Add($_.Name) }
    $formRestore.Controls.Add($lst)
    
    $btnOk = New-Object System.Windows.Forms.Button; $btnOk.Text = "Restore"; $btnOk.Size = New-Object System.Drawing.Size(100, 30)
    $btnOk.Location = New-Object System.Drawing.Point(260, 210); $btnOk.FlatStyle = "Flat"; $btnOk.BackColor = $script:Accent; $btnOk.ForeColor = "White"
    $btnOk.Add_Click({
        if ($lst.SelectedItem) {
            $jsonPath = "$script:workDir\States\$($lst.SelectedItem)\policy_snapshot.json"
            if (Test-Path $jsonPath) {
                $snapshot = Get-Content $jsonPath -Raw | ConvertFrom-Json
                if ($snapshot.PSObject.Properties.Name -contains $name) {
                    $state = @{}
                    $userState = $snapshot.$name
                    foreach ($pol in $script:Policies) {
                        $state[$pol.Name] = $userState.($pol.Name)
                    }
                    $state["BlockedURLs"] = @($userState.BlockedURLs)
                    Set-UserPolicyState $sid $name $state
                    Write-Log "Restored state for $name from $($lst.SelectedItem)." "Green"
                    Load-CurrentState $cmb
                } else { Write-Log "User $name not found in backup." "Red" }
            }
            $formRestore.Close()
        }
    })
    $formRestore.Controls.Add($btnOk)
    [void]$formRestore.ShowDialog()
}

function Show-States {
    Clear-Main; Add-Title "States & Backups"
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "All system backups are stored in: $script:workDir\States"; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($lbl); $script:y += 30
    
    $listBox = New-Object System.Windows.Forms.ListBox; $listBox.Location = New-Object System.Drawing.Point(0, $script:y)
    $listBox.Size = New-Object System.Drawing.Size(500, 300); $listBox.BackColor = $script:BtnBG; $listBox.ForeColor = $script:Text
    Get-ChildItem "$script:workDir\States" -Directory | Sort-Object Name -Descending | ForEach-Object { $listBox.Items.Add($_.Name) }
    $mainPanel.Controls.Add($listBox)
}

function Show-Logs {
    Clear-Main; Add-Title "Live Logs"
    $txtLog = New-Object System.Windows.Forms.TextBox; $txtLog.Multiline = $true; $txtLog.ReadOnly = $true
    $txtLog.Location = New-Object System.Drawing.Point(0, 0); $txtLog.Size = New-Object System.Drawing.Size(700, 450)
    $txtLog.BackColor = $script:BG; $txtLog.ForeColor = $script:Text; $txtLog.Font = New-Object System.Drawing.Font("Consolas", 10)
    $txtLog.ScrollBars = "Vertical"
    if (Test-Path "$script:workDir\Logs\PastPolicy_Log.txt") { $txtLog.Text = Get-Content "$script:workDir\Logs\PastPolicy_Log.txt" -Raw }
    $mainPanel.Controls.Add($txtLog)
}

# ==========================================
# 8. SIDEBAR NAVIGATION
# ==========================================
function New-SideButton($text, $action) {
    $btn = New-Object System.Windows.Forms.Button; $btn.Text = $text
    $btn.Size = New-Object System.Drawing.Size(200, 45); $btn.Location = New-Object System.Drawing.Point(10, $script:y)
    $btn.FlatStyle = "Flat"; $btn.BackColor = $script:BtnBG; $btn.ForeColor = $script:Text
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10); $btn.TextAlign = "MiddleLeft"
    $btn.Padding = New-Object System.Windows.Forms.Padding(15, 0, 0, 0); $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Add_MouseEnter({ $this.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#444444") })
    $btn.Add_MouseLeave({ $this.BackColor = $script:BtnBG })
    $btn.Add_Click($action)
    $sidebar.Controls.Add($btn); $script:y += 55
}

$script:y = 90
New-SideButton "  Dashboard"       { Show-Dashboard }
New-SideButton "  Policy Workspace" { Show-PolicyWorkspace }
New-SideButton "  View Backups"    { Show-States }
New-SideButton "  View Logs"       { Show-Logs }

# ==========================================
# 9. LAUNCH
# ==========================================
Write-Log "PastPolicy v6.0 Ultimate Started." "Green"
Invoke-AutoBackup
Show-Dashboard

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
