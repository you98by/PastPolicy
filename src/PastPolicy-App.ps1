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
$script:policyDef = "C:\Windows\PolicyDefinitions"

# Create Workspace Folders
@("$script:workDir\Logs", "$script:workDir\States", "$script:workDir\Deploy") | ForEach-Object {
    if (!(Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

# ==========================================
# 2. AUTO-BACKUP ON LAUNCH
# ==========================================
function Invoke-AutoBackup {
    $backupDir = "$script:workDir\States\AutoBackup_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"
    if (Test-Path $script:gpUserPath) {
        $items = Get-ChildItem $script:gpUserPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^S-1-' }
        if ($items) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            foreach ($item in $items) {
                Copy-Item $item.FullName -Destination "$backupDir\$($item.Name)" -Recurse -Force
            }
            Write-Log "Auto-backup created: $backupDir" "Green"
        } else {
            Write-Log "No existing policies found to backup." "Yellow"
        }
    }
}

# ==========================================
# 3. MODERN DARK THEME & UI SETUP
# ==========================================
$script:BG = [System.Drawing.ColorTranslator]::FromHtml("#1E1E1E")
$script:SidebarBG = [System.Drawing.ColorTranslator]::FromHtml("#252526")
$script:Text = [System.Drawing.ColorTranslator]::FromHtml("#CCCCCC")
$script:Accent = [System.Drawing.ColorTranslator]::FromHtml("#007ACC")
$script:BtnBG = [System.Drawing.ColorTranslator]::FromHtml("#333333")
$script:Error = [System.Drawing.ColorTranslator]::FromHtml("#F44747")
$script:Success = [System.Drawing.ColorTranslator]::FromHtml("#4EC9B0")

$form = New-Object System.Windows.Forms.Form
$form.Text = "PastPolicy - Ultimate Group Policy Manager"
$form.Size = New-Object System.Drawing.Size(1050, 700)
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
$form.Controls.Add($mainPanel)

# ==========================================
# 4. HELPER & LOGIC FUNCTIONS
# ==========================================
function Write-Log($msg, $color = "White") {
    $time = Get-Date -Format "HH:mm:ss"
    $logBox.SelectionColor = switch ($color) { "Red" { $script:Error }; "Green" { $script:Success }; "Yellow" { "Yellow" } default { $script:Text } }
    $logBox.AppendText("[$time] $msg`r`n"); $logBox.ScrollToCaret()
    Add-Content -Path "$script:workDir\Logs\PastPolicy_Log.txt" -Value "[$time] $msg"
}

function Get-LocalUsers {
    Get-LocalUser | Where-Object { $_.Enabled -eq $true -and $_.Name -notin @('DefaultAccount', 'Guest', 'WDAGUtilityAccount') }
}

function Load-UserHive($sid, $username) {
    $hive = "HKU\$sid"
    $ntuser = "C:\Users\$username\NTUSER.DAT"
    if (Test-Path $ntuser) { reg load $hive $ntuser 2>$null }
}

function Unload-UserHive($sid) { reg unload "HKU\$sid" 2>$null }

# --- URL BLOCKER LOGIC ---
function Get-BlockedUrls($sid, $username) {
    Load-UserHive $sid $username
    $urls = @()
    $regPath = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"
    if (Test-Path $regPath) {
        Get-ChildItem $regPath -ErrorAction SilentlyContinue | ForEach-Object {
            $val = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($val.'*' -eq 4) { $urls += $_.PSChildName }
        }
    }
    Unload-UserHive $sid
    return $urls
}

function Set-UrlBlock($sid, $username, $url, $block) {
    Load-UserHive $sid $username
    $regPath = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$url"
    if ($block) {
        if (!(Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name "*" -Value 4 -Type DWORD -Force
    } else {
        if (Test-Path $regPath) { Remove-Item -Path $regPath -Recurse -Force }
    }
    Unload-UserHive $sid
}

# --- POLICY MANAGER LOGIC ---
function Deploy-Policy($sid) {
    $src = "$script:workDir\Deploy"; $dest = "$script:gpUserPath\$sid"
    if (!(Get-ChildItem $src -ErrorAction SilentlyContinue)) { Write-Log "Deploy folder is empty. Save a policy first." "Red"; return }
    if (!(Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    robocopy $src $dest /E /COPY:DAT /R:2 /W:1 /NP | Out-Null
    if ($LASTEXITCODE -lt 8) { Write-Log "Policy deployed to $sid. Running gpupdate..." "Green"; gpupdate /force | Out-Null }
    else { Write-Log "Deploy failed. Check file locks." "Red" }
}

function Save-Policy($sid) {
    $src = "$script:gpUserPath\$sid"; $dest = "$script:workDir\Deploy"
    if (!(Test-Path $src)) { Write-Log "No policy found for $sid." "Red"; return }
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    robocopy $src $dest /E /COPY:DAT /R:2 /W:1 /NP | Out-Null
    if ($LASTEXITCODE -lt 8) { Write-Log "Policy saved to $script:workDir\Deploy" "Green" }
    else { Write-Log "Save failed." "Red" }
}

# ==========================================
# 5. UI PAGE BUILDERS
# ==========================================
function Clear-Main { $mainPanel.Controls.Clear(); $script:y = 0 }

function Add-Title($text) {
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = $text
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = $script:Accent; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($lbl); $script:y += 40
}

function Add-UserDropdown {
    $cmb = New-Object System.Windows.Forms.ComboBox; $cmb.Name = "UserCombo"
    $cmb.DropDownStyle = "DropDownList"; $cmb.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $cmb.Location = New-Object System.Drawing.Point(0, $script:y); $cmb.Size = New-Object System.Drawing.Size(350, 30)
    $cmb.BackColor = $script:BtnBG; $cmb.ForeColor = $script:Text; $cmb.FlatStyle = "Flat"
    Get-LocalUsers | ForEach-Object { $cmb.Items.Add("$($_.Name) ($($_.SID))") }
    if ($cmb.Items.Count -gt 0) { $cmb.SelectedIndex = 0 }
    $mainPanel.Controls.Add($cmb); $script:y += 45
    return $cmb
}

function Add-Button($text, $action, $color = $script:Accent) {
    $btn = New-Object System.Windows.Forms.Button; $btn.Text = $text
    $btn.Size = New-Object System.Drawing.Size(140, 35); $btn.Location = New-Object System.Drawing.Point(0, $script:y)
    $btn.FlatStyle = "Flat"; $btn.BackColor = $color; $btn.ForeColor = "White"
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Add_Click($action)
    $mainPanel.Controls.Add($btn); $script:xOffset += 150
    $btn.Location = New-Object System.Drawing.Point($script:xOffset - 150, $script:y)
    return $btn
}

# --- PAGE: DASHBOARD ---
function Show-Dashboard {
    Clear-Main; Add-Title "Dashboard"
    $info = New-Object System.Windows.Forms.Label
    $info.Text = "Welcome to PastPolicy.`n`nWorkspace: $script:workDir`nAuto-Backup: Enabled on Launch`n`nUse the sidebar to manage users, block URLs, or deploy policies."
    $info.Font = New-Object System.Drawing.Font("Segoe UI", 12); $info.AutoSize = $true; $info.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($info)
}

# --- PAGE: URL BLOCKER ---
function Show-UrlBlocker {
    Clear-Main; Add-Title "Dynamic URL Blocker"
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "Select User:"; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($lbl); $script:y += 25
    $cmb = Add-UserDropdown
    
    $script:y += 10
    $lbl2 = New-Object System.Windows.Forms.Label; $lbl2.Text = "Enter URL to block (e.g., facebook.com):"; $lbl2.AutoSize = $true; $lbl2.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($lbl2); $script:y += 25
    
    $txtUrl = New-Object System.Windows.Forms.TextBox; $txtUrl.Location = New-Object System.Drawing.Point(0, $script:y); $txtUrl.Size = New-Object System.Drawing.Size(300, 30)
    $txtUrl.BackColor = $script:BtnBG; $txtUrl.ForeColor = $script:Text; $txtUrl.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $mainPanel.Controls.Add($txtUrl); $script:y += 45
    
    $script:xOffset = 0
    $btnBlock = Add-Button "Block URL" {
        $sel = $cmb.SelectedItem; if (!$sel) { return }
        $name = $sel.Split(' ')[0]; $sid = $sel.Split('(')[1].Trim(')')
        $url = $txtUrl.Text.Trim()
        if ($url) { Set-UrlBlock $sid $name $url $true; Write-Log "Blocked $url for $name" "Green"; Show-UrlBlocker }
    }
    $btnUnblock = Add-Button "Unblock URL" {
        $sel = $cmb.SelectedItem; if (!$sel) { return }
        $name = $sel.Split(' ')[0]; $sid = $sel.Split('(')[1].Trim(')')
        $url = $txtUrl.Text.Trim()
        if ($url) { Set-UrlBlock $sid $name $url $false; Write-Log "Unblocked $url for $name" "Green"; Show-UrlBlocker }
    } $script:Error
    
    $script:y += 50
    $lbl3 = New-Object System.Windows.Forms.Label; $lbl3.Text = "Currently Blocked URLs for Selected User:"; $lbl3.AutoSize = $true; $lbl3.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($lbl3); $script:y += 25
    
    $listBox = New-Object System.Windows.Forms.ListBox; $listBox.Location = New-Object System.Drawing.Point(0, $script:y)
    $listBox.Size = New-Object System.Drawing.Size(400, 200); $listBox.BackColor = $script:BtnBG; $listBox.ForeColor = $script:Text
    $mainPanel.Controls.Add($listBox)
    
    $cmb.Add_SelectedIndexChanged({
        $sel = $this.SelectedItem; if (!$sel) { return }
        $name = $sel.Split(' ')[0]; $sid = $sel.Split('(')[1].Trim(')')
        $listBox.Items.Clear()
        Get-BlockedUrls $sid $name | ForEach-Object { $listBox.Items.Add($_) }
    })
    if ($cmb.Items.Count -gt 0) { $cmb.SelectedIndex = 0 }
}

# --- PAGE: POLICY MANAGER ---
function Show-PolicyManager {
    Clear-Main; Add-Title "Policy Manager"
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "Select User:"; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($lbl); $script:y += 25
    $cmb = Add-UserDropdown
    
    $script:y += 20; $script:xOffset = 0
    Add-Button "Deploy to User" {
        $sel = $cmb.SelectedItem; if (!$sel) { return }
        $sid = $sel.Split('(')[1].Trim(')'); Deploy-Policy $sid
    }
    Add-Button "Save User Policy" {
        $sel = $cmb.SelectedItem; if (!$sel) { return }
        $sid = $sel.Split('(')[1].Trim(')'); Save-Policy $sid
    }
    Add-Button "Edit in MMC" {
        $sel = $cmb.SelectedItem; if (!$sel) { return }
        $name = $sel.Split(' ')[0]; $sid = $sel.Split('(')[1].Trim(')')
        $template = "$script:assetsDir\UserPolicyTemplate.msc"
        if (!(Test-Path $template)) { Write-Log "UserPolicyTemplate.msc missing! See README_MSC.txt" "Red"; return }
        $temp = "$env:TEMP\${name}_Policy.msc"; Copy-Item $template $temp -Force
        powershell -NoProfile -Command "Unblock-File -Path '$temp'" | Out-Null
        Start-Process mmc.exe -ArgumentList "`"$temp`""; Write-Log "Opened MMC for $name" "Green"
    }
    $script:y += 50; $script:xOffset = 0
    Add-Button "Delete User Policy" {
        $sel = $cmb.SelectedItem; if (!$sel) { return }
        $name = $sel.Split(' ')[0]; $sid = $sel.Split('(')[1].Trim(')')
        $path = "$script:gpUserPath\$sid"
        if (Test-Path $path) { Remove-Item $path -Recurse -Force; Write-Log "Deleted policy for $name" "Green" }
        else { Write-Log "No policy found for $name" "Yellow" }
    } $script:Error
}

# --- PAGE: STATES & RESTORE ---
function Show-States {
    Clear-Main; Add-Title "States & Backups"
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "Select a backup to restore:"; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($lbl); $script:y += 25
    
    $listBox = New-Object System.Windows.Forms.ListBox; $listBox.Location = New-Object System.Drawing.Point(0, $script:y)
    $listBox.Size = New-Object System.Drawing.Size(500, 300); $listBox.BackColor = $script:BtnBG; $listBox.ForeColor = $script:Text
    Get-ChildItem "$script:workDir\States" -Directory | Sort-Object Name -Descending | ForEach-Object { $listBox.Items.Add($_.Name) }
    $mainPanel.Controls.Add($listBox)
    
    $script:y += 320; $script:xOffset = 0
    Add-Button "Restore Selected" {
        $sel = $listBox.SelectedItem; if (!$sel) { return }
        $src = "$script:workDir\States\$sel"; $dest = $script:gpUserPath
        Write-Log "Restoring state: $sel..." "Yellow"
        robocopy $src $dest /E /COPY:DAT /R:2 /W:1 /NP /PURGE | Out-Null
        Write-Log "State restored successfully. Run gpupdate..." "Green"
        gpupdate /force | Out-Null
    }
}

# --- PAGE: LOGS ---
function Show-Logs {
    Clear-Main; Add-Title "Live Logs"
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "Viewing: $script:workDir\Logs\PastPolicy_Log.txt"; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(0, $script:y)
    $mainPanel.Controls.Add($lbl); $script:y += 30
    
    $txtLog = New-Object System.Windows.Forms.TextBox; $txtLog.Multiline = $true; $txtLog.ReadOnly = $true
    $txtLog.Location = New-Object System.Drawing.Point(0, $script:y); $txtLog.Size = New-Object System.Drawing.Size(700, 350)
    $txtLog.BackColor = $script:BG; $txtLog.ForeColor = $script:Text; $txtLog.Font = New-Object System.Drawing.Font("Consolas", 10)
    $txtLog.ScrollBars = "Vertical"
    if (Test-Path "$script:workDir\Logs\PastPolicy_Log.txt") { $txtLog.Text = Get-Content "$script:workDir\Logs\PastPolicy_Log.txt" -Raw }
    $mainPanel.Controls.Add($txtLog)
}

# ==========================================
# 6. SIDEBAR NAVIGATION
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
New-SideButton "  URL Blocker"     { Show-UrlBlocker }
New-SideButton "  Policy Manager"  { Show-PolicyManager }
New-SideButton "  States / Restore" { Show-States }
New-SideButton "  View Logs"       { Show-Logs }

# ==========================================
# 7. LAUNCH
# ==========================================
Write-Log "PastPolicy v5.0 Ultimate Started." "Green"
Invoke-AutoBackup
Show-Dashboard

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
