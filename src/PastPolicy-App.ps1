# PastPolicy - Windows local policy manager
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$currentIdentity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    exit
}

$script:workDir = 'C:\PastPolicy'
$script:assetsDir = Join-Path $PSScriptRoot '..\assets'
$script:gpUserPath = 'C:\Windows\System32\GroupPolicyUsers'
$script:policiesFile = Join-Path $PSScriptRoot '..\policies.txt'
$script:logFile = Join-Path $script:workDir 'Logs\PastPolicy_Log.txt'
foreach ($directory in @($script:workDir, (Join-Path $script:workDir 'Logs'), (Join-Path $script:workDir 'States'), (Join-Path $script:workDir 'Deploy'))) {
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:BG = [Drawing.ColorTranslator]::FromHtml('#1E1E1E')
$script:SidebarBG = [Drawing.ColorTranslator]::FromHtml('#252526')
$script:Text = [Drawing.ColorTranslator]::FromHtml('#CCCCCC')
$script:Accent = [Drawing.ColorTranslator]::FromHtml('#007ACC')
$script:BtnBG = [Drawing.ColorTranslator]::FromHtml('#333333')
$script:ErrorColor = [Drawing.ColorTranslator]::FromHtml('#F44747')
$script:Success = [Drawing.ColorTranslator]::FromHtml('#4EC9B0')

$script:Policies = @(foreach ($line in @(Get-Content -LiteralPath $script:policiesFile -ErrorAction SilentlyContinue)) {
    $trimmed = $line.Trim()
    if ($trimmed -and $trimmed -notmatch '^#') {
        $parts = $trimmed -split '\|', 6
        if ($parts.Count -ge 5) {
            [pscustomobject]@{ Name = $parts[0].Trim(); Key = $parts[1].Trim(); ValueName = $parts[2].Trim(); Checked = $parts[3].Trim(); Unchecked = $parts[4].Trim(); Category = if ($parts.Count -ge 6) { $parts[5].Trim() } else { 'Windows' } }
        }
    }
})

function Write-Log {
    param([string]$Message, [ValidateSet('White', 'Red', 'Green', 'Yellow')][string]$Color = 'White')
    $time = Get-Date -Format 'HH:mm:ss'
    $logBox.SelectionColor = switch ($Color) { 'Red' { $script:ErrorColor }; 'Green' { $script:Success }; 'Yellow' { [Drawing.Color]::Gold }; default { $script:Text } }
    $logBox.AppendText("[$time] $Message`r`n"); $logBox.ScrollToCaret()
    Add-Content -LiteralPath $script:logFile -Value "[$time] $Message"
}

function Get-LocalUsers { @(Get-LocalUser | Where-Object { $_.Enabled -and $_.Name -notin @('DefaultAccount', 'Guest', 'WDAGUtilityAccount') }) }

$script:LoadedHives = [Collections.Generic.HashSet[string]]::new()
$script:configDir = Join-Path $script:workDir 'Configurations'
if (-not (Test-Path -LiteralPath $script:configDir)) { [void](New-Item -ItemType Directory -Path $script:configDir -Force) }
$script:BrowserExecutables = @('chrome.exe', 'firefox.exe', 'brave.exe', 'opera.exe', 'vivaldi.exe', 'iexplore.exe')
function Get-UserProfilePath {
    param([string]$Sid)
    $profile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($profile -and $profile.LocalPath) { return $profile.LocalPath }

    $profileKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    $profileValue = Get-ItemProperty -LiteralPath $profileKey -Name ProfileImagePath -ErrorAction SilentlyContinue
    if ($profileValue -and $profileValue.ProfileImagePath) { return [Environment]::ExpandEnvironmentVariables($profileValue.ProfileImagePath) }
    return $null
}

function Load-UserHive {
    param([string]$Sid, [string]$Username)
    $registryPath = "Registry::HKEY_USERS\$Sid"
    if (Test-Path -LiteralPath $registryPath) { return $true }
    $profilePath = Get-UserProfilePath $Sid
    $ntUser = if ($profilePath) { Join-Path $profilePath 'NTUSER.DAT' } else { $null }
    if (-not $ntUser -or -not (Test-Path -LiteralPath $ntUser)) { Write-Log "Profile hive not found for $Username." 'Yellow'; return $false }
    & reg.exe load "HKU\$Sid" $ntUser 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $registryPath)) { throw "Could not load the registry hive for $Username." }
    [void]$script:LoadedHives.Add($Sid); return $true
}
function Unload-UserHive { param([string]$Sid); if ($script:LoadedHives.Contains($Sid)) { & reg.exe unload "HKU\$Sid" 2>$null | Out-Null; [void]$script:LoadedHives.Remove($Sid) } }

function Get-UserPolicyState {
    param([string]$Sid, [string]$Username)
    if (-not (Load-UserHive $Sid $Username)) { return $null }
    try {
        $state = @{}
        foreach ($policy in $script:Policies) {
            $path = "Registry::HKEY_USERS\$Sid\$($policy.Key)"
            $property = Get-ItemProperty -LiteralPath $path -Name $policy.ValueName -ErrorAction SilentlyContinue
            $currentValue = if ($property) { $property.($policy.ValueName) } else { $null }
            $state[$policy.Name] = ($currentValue -eq $policy.Checked -or $currentValue -eq [int]$policy.Checked)
        }
        $domainPath = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"
        $state['BlockedURLs'] = @(if (Test-Path -LiteralPath $domainPath) { Get-ChildItem -LiteralPath $domainPath -ErrorAction SilentlyContinue | ForEach-Object { $property = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue; if ($property.'*' -eq 4) { $_.PSChildName } } })
        $disallowPath = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun"
        $disallow = Get-ItemProperty -LiteralPath $disallowPath -ErrorAction SilentlyContinue
        $state['BlockBrowsers'] = @($disallow.PSObject.Properties | Where-Object { $_.Value -in $script:BrowserExecutables }).Count -gt 0
        return $state
    } finally { Unload-UserHive $Sid }
}

function Set-UserPolicyState {
    param([string]$Sid, [string]$Username, [hashtable]$State)
    if (-not (Load-UserHive $Sid $Username)) { return }
    try {
        foreach ($policy in $script:Policies) {
            $path = "Registry::HKEY_USERS\$Sid\$($policy.Key)"
            if (-not (Test-Path -LiteralPath $path)) { [void](New-Item -Path $path -Force) }
            $value = if ($State[$policy.Name]) { [int]$policy.Checked } else { [int]$policy.Unchecked }
            Set-ItemProperty -LiteralPath $path -Name $policy.ValueName -Value $value -Type DWord -Force
        }
        $domainBase = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"
        if (Test-Path -LiteralPath $domainBase) { Remove-Item -LiteralPath $domainBase -Recurse -Force }
        foreach ($url in @($State['BlockedURLs'])) {
            $domain = ([string]$url).Trim() -replace '^https?://', '' -replace '/.*$', ''
            if ($domain) { $domainPath = Join-Path $domainBase $domain; [void](New-Item -Path $domainPath -Force); Set-ItemProperty -LiteralPath $domainPath -Name '*' -Value 4 -Type DWord -Force }
        }
        # Explorer's DisallowRun supports per-user browser restrictions. Edge is deliberately excluded.
        $disallowPath = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun"
        if (-not (Test-Path -LiteralPath $disallowPath)) { [void](New-Item -Path $disallowPath -Force) }
        $existing = Get-ItemProperty -LiteralPath $disallowPath -ErrorAction SilentlyContinue
        foreach ($property in @($existing.PSObject.Properties | Where-Object { $_.Value -in $script:BrowserExecutables })) { Remove-ItemProperty -LiteralPath $disallowPath -Name $property.Name -Force }
        if ($State['BlockBrowsers']) { $index = 1; foreach ($browser in $script:BrowserExecutables) { Set-ItemProperty -LiteralPath $disallowPath -Name "PastPolicyBrowser$index" -Value $browser -Type String -Force; $index++ } }
    } finally { Unload-UserHive $Sid }
    & gpupdate.exe /target:user /force 2>$null | Out-Null
}

function Invoke-AutoBackup {
    $backupDir = Join-Path $script:workDir "States\AutoBackup_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"
    [void](New-Item -ItemType Directory -Path $backupDir -Force)
    if (Test-Path -LiteralPath $script:gpUserPath) { Copy-Item -LiteralPath $script:gpUserPath -Destination (Join-Path $backupDir 'GroupPolicyUsers') -Recurse -Force -ErrorAction SilentlyContinue }
    $snapshot = @{}
    foreach ($user in @(Get-LocalUsers)) { $snapshot[$user.Name] = Get-UserPolicyState $user.SID.ToString() $user.Name }
    $snapshot | ConvertTo-Json -Depth 8 | Out-File -LiteralPath (Join-Path $backupDir 'policy_snapshot.json') -Encoding UTF8
    Write-Log "Auto-backup created: $backupDir" 'Green'
}

$form = New-Object Windows.Forms.Form; $form.Text = 'PastPolicy - Local Policy Manager'; $form.Size = New-Object Drawing.Size(1000, 750); $form.MinimumSize = New-Object Drawing.Size(760, 520); $form.StartPosition = 'CenterScreen'; $form.BackColor = $script:BG; $form.ForeColor = $script:Text; $form.Font = New-Object Drawing.Font('Segoe UI', 10)
$sidebar = New-Object Windows.Forms.Panel; $sidebar.Dock = 'Left'; $sidebar.Width = 220; $sidebar.BackColor = $script:SidebarBG
$logBox = New-Object Windows.Forms.RichTextBox; $logBox.Dock = 'Bottom'; $logBox.Height = 150; $logBox.ReadOnly = $true; $logBox.Multiline = $true; $logBox.BackColor = $script:BG; $logBox.ForeColor = $script:Text; $logBox.BorderStyle = 'None'; $logBox.Font = New-Object Drawing.Font('Consolas', 10); $logBox.ScrollBars = 'Vertical'
$mainPanel = New-Object Windows.Forms.Panel; $mainPanel.Dock = 'Fill'; $mainPanel.BackColor = $script:BG; $mainPanel.AutoScroll = $true
[void]$form.Controls.Add($mainPanel); [void]$form.Controls.Add($sidebar); [void]$form.Controls.Add($logBox)

$title = New-Object Windows.Forms.Label; $title.Text = 'PastPolicy'; $title.Dock = 'Top'; $title.Height = 70; $title.Padding = New-Object Windows.Forms.Padding(20, 22, 0, 0); $title.Font = New-Object Drawing.Font('Segoe UI', 18, [Drawing.FontStyle]::Bold); $title.ForeColor = $script:Accent
$nav = New-Object Windows.Forms.FlowLayoutPanel; $nav.Dock = 'Fill'; $nav.FlowDirection = 'TopDown'; $nav.WrapContents = $false; $nav.AutoScroll = $true; $nav.Padding = New-Object Windows.Forms.Padding(10, 10, 10, 0); $nav.BackColor = $script:SidebarBG
[void]$sidebar.Controls.Add($nav); [void]$sidebar.Controls.Add($title)
$script:content = New-Object Windows.Forms.TableLayoutPanel; $script:content.Dock = 'Fill'; $script:content.AutoScroll = $true; $script:content.Padding = New-Object Windows.Forms.Padding(30); $script:content.BackColor = $script:BG; $script:content.ColumnCount = 1; $script:content.RowCount = 0
[void]$script:content.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100))); [void]$mainPanel.Controls.Add($script:content); $script:CheckBoxes = @{}

function Clear-Content { $script:content.Controls.Clear(); $script:content.RowStyles.Clear(); $script:content.RowCount = 0; $script:CheckBoxes = @{} }
function Add-ContentControl {
    param([Windows.Forms.Control]$Control, [int]$Height = 0)
    $row = $script:content.RowCount; [void]$script:content.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))); $script:content.RowCount++
    $Control.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 10); if ($Height -gt 0) { $Control.Height = $Height }; $Control.Dock = 'Top'; $Control.Anchor = 'Left, Top, Right'; [void]$script:content.Controls.Add($Control, 0, $row); return $Control
}
function New-PageTitle([string]$Text) { $label = New-Object Windows.Forms.Label; $label.Text = $Text; $label.AutoSize = $true; $label.Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold); $label.ForeColor = $script:Accent; [void](Add-ContentControl $label); return $label }
function New-Button([string]$Text, [scriptblock]$Action, [Drawing.Color]$Color = $script:Accent) { $button = New-Object Windows.Forms.Button; $button.Text = $Text; $button.Width = 145; $button.Height = 35; $button.FlatStyle = 'Flat'; $button.BackColor = $Color; $button.ForeColor = [Drawing.Color]::White; $button.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold); $button.Cursor = [Windows.Forms.Cursors]::Hand; [void]$button.Add_Click($Action); return $button }
function Get-SelectedUser($ComboBox) { return $ComboBox.SelectedItem }

function Load-CurrentState($ComboBox) {
    $user = Get-SelectedUser $ComboBox; if (-not $user) { return }; $state = Get-UserPolicyState $user.SID.ToString() $user.Name; if (-not $state) { return }
    foreach ($policy in $script:Policies) { $script:CheckBoxes[$policy.Name].Checked = [bool]$state[$policy.Name] }
    $urlBox = $script:content.Controls.Find('BlockedUrls', $true) | Select-Object -First 1; if ($urlBox) { $urlBox.Text = @($state['BlockedURLs']) -join "`r`n" }
    $browserBox = $script:content.Controls.Find('BlockBrowsers', $true) | Select-Object -First 1; if ($browserBox) { $browserBox.Checked = [bool]$state['BlockBrowsers'] }
}

function Get-WorkspaceState {
    $state = @{}
    foreach ($policy in $script:Policies) { $state[$policy.Name] = $script:CheckBoxes[$policy.Name].Checked }
    $urlBox = $script:content.Controls.Find('BlockedUrls', $true) | Select-Object -First 1
    $browserBox = $script:content.Controls.Find('BlockBrowsers', $true) | Select-Object -First 1
    $state['BlockedURLs'] = @($urlBox.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $state['BlockBrowsers'] = [bool]$browserBox.Checked
    return $state
}
function Set-WorkspaceState($State) {
    foreach ($policy in $script:Policies) { $script:CheckBoxes[$policy.Name].Checked = [bool]$State.($policy.Name) }
    ($script:content.Controls.Find('BlockedUrls', $true) | Select-Object -First 1).Text = @($State.BlockedURLs) -join "`r`n"
    ($script:content.Controls.Find('BlockBrowsers', $true) | Select-Object -First 1).Checked = [bool]$State.BlockBrowsers
}
function Save-Configuration {
    $dialog = New-Object Windows.Forms.SaveFileDialog; $dialog.InitialDirectory = $script:configDir; $dialog.Filter = 'PastPolicy configuration (*.json)|*.json'; $dialog.FileName = 'policy-configuration.json'
    if ($dialog.ShowDialog() -eq 'OK') { $state = Get-WorkspaceState; [pscustomobject]@{ Format = 'PastPolicyConfiguration'; Version = 1; Created = (Get-Date).ToString('o'); Policies = $state } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8; Write-Log "Configuration saved: $($dialog.FileName)" 'Green' }
}
function Load-Configuration {
    $dialog = New-Object Windows.Forms.OpenFileDialog; $dialog.InitialDirectory = $script:configDir; $dialog.Filter = 'PastPolicy configuration (*.json)|*.json'
    if ($dialog.ShowDialog() -eq 'OK') { try { $config = Get-Content -LiteralPath $dialog.FileName -Raw | ConvertFrom-Json; if ($config.Format -ne 'PastPolicyConfiguration') { throw 'This is not a PastPolicy configuration file.' }; Set-WorkspaceState $config.Policies; Write-Log "Configuration loaded: $($dialog.FileName)" 'Green' } catch { Write-Log $_.Exception.Message 'Red' } }
}

function Show-Dashboard { Clear-Content; [void](New-PageTitle 'Dashboard'); $info = New-Object Windows.Forms.Label; $info.AutoSize = $true; $info.Text = "Welcome to PastPolicy.`r`n`r`nWorkspace: $script:workDir`r`nPolicies loaded: $($script:Policies.Count)`r`n`r`nUse Policy Workspace to manage local users and registry-backed policies."; $info.Font = New-Object Drawing.Font('Segoe UI', 12); [void](Add-ContentControl $info) }

function Show-PolicyWorkspace {
    Clear-Content; [void](New-PageTitle 'Policy Workspace')
    $userLabel = New-Object Windows.Forms.Label; $userLabel.Text = 'Target user'; $userLabel.AutoSize = $true; [void](Add-ContentControl $userLabel)
    $combo = New-Object Windows.Forms.ComboBox; $combo.DropDownStyle = 'DropDownList'; $combo.DisplayMember = 'DisplayName'; $combo.Height = 32
    $script:workspaceCombo = $combo
    foreach ($user in @(Get-LocalUsers)) { [void]$combo.Items.Add([pscustomobject]@{ Name = $user.Name; SID = $user.SID; DisplayName = "$($user.Name) ($($user.SID))" }) }; [void](Add-ContentControl $combo)
    foreach ($category in @($script:Policies.Category | Sort-Object -Unique)) {
        $policyLabel = New-Object Windows.Forms.Label; $policyLabel.Text = $category; $policyLabel.AutoSize = $true; $policyLabel.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold); $policyLabel.ForeColor = $script:Accent; [void](Add-ContentControl $policyLabel)
        foreach ($policy in @($script:Policies | Where-Object { $_.Category -eq $category })) { $checkBox = New-Object Windows.Forms.CheckBox; $checkBox.Text = $policy.Name; $checkBox.AutoSize = $true; $checkBox.ForeColor = $script:Text; $script:CheckBoxes[$policy.Name] = $checkBox; [void](Add-ContentControl $checkBox) }
    }
    $urlLabel = New-Object Windows.Forms.Label; $urlLabel.Text = 'Blocked websites (one per line)'; $urlLabel.AutoSize = $true; $urlLabel.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold); [void](Add-ContentControl $urlLabel)
    $urlBox = New-Object Windows.Forms.TextBox; $urlBox.Name = 'BlockedUrls'; $urlBox.Multiline = $true; $urlBox.ScrollBars = 'Vertical'; $urlBox.Height = 100; $urlBox.BackColor = $script:BtnBG; $urlBox.ForeColor = $script:Text; $urlBox.Font = New-Object Drawing.Font('Consolas', 10); [void](Add-ContentControl $urlBox)
    $browserBox = New-Object Windows.Forms.CheckBox; $browserBox.Name = 'BlockBrowsers'; $browserBox.Text = 'Block common browsers for this user (Chrome, Firefox, Brave, Opera, Vivaldi, Internet Explorer) — Edge remains allowed'; $browserBox.AutoSize = $true; $browserBox.ForeColor = $script:Text; [void](Add-ContentControl $browserBox)
    $actions = New-Object Windows.Forms.FlowLayoutPanel; $actions.AutoSize = $true; $actions.WrapContents = $false; $actions.FlowDirection = 'LeftToRight'; $actions.Dock = 'Top'
    $apply = New-Button 'Apply Changes' { $user = Get-SelectedUser $script:workspaceCombo; if (-not $user) { [Windows.Forms.MessageBox]::Show('Select a target user first.'); return }; try { Set-UserPolicyState $user.SID.ToString() $user.Name (Get-WorkspaceState); Write-Log "Policies applied to $($user.Name)." 'Green' } catch { Write-Log $_.Exception.Message 'Red' } }
    $discard = New-Button 'Discard' { Load-CurrentState $script:workspaceCombo } $script:BtnBG; $restore = New-Button 'Restore State' { Show-RestoreDialog $script:workspaceCombo } $script:ErrorColor
    $save = New-Button 'Save Config' { Save-Configuration } $script:Success; $load = New-Button 'Load Config' { Load-Configuration } $script:BtnBG
    [void]$actions.Controls.Add($apply); [void]$actions.Controls.Add($discard); [void]$actions.Controls.Add($restore); [void]$actions.Controls.Add($save); [void]$actions.Controls.Add($load); [void](Add-ContentControl $actions)
    [void]$combo.Add_SelectedIndexChanged({ Load-CurrentState $this }); if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0; Load-CurrentState $combo }
}

function Show-RestoreDialog($ComboBox) {
    $user = Get-SelectedUser $ComboBox; if (-not $user) { return }; $backups = @(Get-ChildItem (Join-Path $script:workDir 'States') -Directory | Sort-Object Name -Descending); if ($backups.Count -eq 0) { Write-Log 'No backups found.' 'Yellow'; return }
    $dialog = New-Object Windows.Forms.Form; $dialog.Text = 'Restore State'; $dialog.Size = New-Object Drawing.Size(430, 330); $dialog.StartPosition = 'CenterParent'; $dialog.BackColor = $script:BG; $dialog.ForeColor = $script:Text
    $layout = New-Object Windows.Forms.TableLayoutPanel; $layout.Dock = 'Fill'; $layout.Padding = New-Object Windows.Forms.Padding(15); $layout.ColumnCount = 1; $layout.RowCount = 3
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100))); [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))); [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100))); [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $label = New-Object Windows.Forms.Label; $label.Text = "Select a backup for $($user.Name)"; $label.AutoSize = $true
    $list = New-Object Windows.Forms.ListBox; $list.Dock = 'Fill'; $list.BackColor = $script:BtnBG; $list.ForeColor = $script:Text; foreach ($backup in $backups) { [void]$list.Items.Add($backup.Name) }
    $ok = New-Button 'Restore' { if (-not $list.SelectedItem) { return }; $json = Join-Path (Join-Path $script:workDir 'States') "$($list.SelectedItem)\policy_snapshot.json"; if (-not (Test-Path $json)) { return }; $snapshot = Get-Content $json -Raw | ConvertFrom-Json; $saved = $snapshot.PSObject.Properties[$user.Name].Value; if (-not $saved) { Write-Log "User $($user.Name) not found in backup." 'Red'; return }; $state = @{}; foreach ($policy in $script:Policies) { $state[$policy.Name] = [bool]$saved.($policy.Name) }; $state['BlockedURLs'] = @($saved.BlockedURLs); try { Set-UserPolicyState $user.SID.ToString() $user.Name $state; Write-Log "Restored state for $($user.Name)." 'Green'; Load-CurrentState $ComboBox } catch { Write-Log $_.Exception.Message 'Red' }; $dialog.Close() }
    $buttonRow = New-Object Windows.Forms.FlowLayoutPanel; $buttonRow.FlowDirection = 'RightToLeft'; $buttonRow.Dock = 'Fill'; [void]$buttonRow.Controls.Add($ok)
    [void]$layout.Controls.Add($label, 0, 0); [void]$layout.Controls.Add($list, 0, 1); [void]$layout.Controls.Add($buttonRow, 0, 2); [void]$dialog.Controls.Add($layout); [void]$dialog.ShowDialog($form)
}

function Show-States { Clear-Content; [void](New-PageTitle 'States & Backups'); $label = New-Object Windows.Forms.Label; $label.Text = "Backups: $(Join-Path $script:workDir 'States')"; $label.AutoSize = $true; [void](Add-ContentControl $label); $list = New-Object Windows.Forms.ListBox; $list.Height = 350; $list.BackColor = $script:BtnBG; $list.ForeColor = $script:Text; foreach ($backup in @(Get-ChildItem (Join-Path $script:workDir 'States') -Directory | Sort-Object Name -Descending)) { [void]$list.Items.Add($backup.Name) }; [void](Add-ContentControl $list) }
function Show-Logs { Clear-Content; [void](New-PageTitle 'Live Logs'); $text = New-Object Windows.Forms.TextBox; $text.Multiline = $true; $text.ReadOnly = $true; $text.ScrollBars = 'Vertical'; $text.Height = 450; $text.BackColor = $script:BG; $text.ForeColor = $script:Text; $text.Font = New-Object Drawing.Font('Consolas', 10); if (Test-Path $script:logFile) { $text.Text = Get-Content $script:logFile -Raw }; [void](Add-ContentControl $text) }

function Use-Preset([string]$Name) {
    Show-PolicyWorkspace
    $state = @{}; foreach ($policy in $script:Policies) { $state[$policy.Name] = $false }; $state['BlockedURLs'] = @(); $state['BlockBrowsers'] = $false
    switch ($Name) {
        'Focused workstation' { foreach ($policy in @('Disable Task Manager','Disable Registry Editor','Disable Command Prompt','Disable Control Panel','Disable Run Command','Disable Taskbar Context Menu')) { $state[$policy] = $true }; $state['BlockBrowsers'] = $true }
        'Privacy' { foreach ($policy in @('Disable Location','Disable Advertising ID','Disable Tailored Experiences','Disable Windows Consumer Features','Edge: Block third-party cookies')) { $state[$policy] = $true } }
        'Shared device' { foreach ($policy in @('Hide Recent Documents','Clear Recent Documents on Exit','Prevent Changes to Desktop Background','Disable Changing the Desktop Theme','Disable Changing Display Settings')) { $state[$policy] = $true } }
    }
    Set-WorkspaceState ([pscustomobject]$state); Write-Log "Loaded '$Name' preset. Review and apply it to the selected user." 'Green'
}
function Show-Presets {
    Clear-Content; [void](New-PageTitle 'Scenario Presets')
    $help = New-Object Windows.Forms.Label; $help.Text = 'Presets fill the Policy Workspace but do not change a user until Apply Changes is selected.'; $help.AutoSize = $true; [void](Add-ContentControl $help)
    foreach ($name in @('Focused workstation','Privacy','Shared device')) { $button = New-Button "Use $name preset" { Use-Preset $name } $script:Success; [void](Add-ContentControl $button) }
}
function Show-EdgeTemplates {
    Clear-Content; [void](New-PageTitle 'Microsoft Edge ADMX templates')
    $info = New-Object Windows.Forms.Label; $info.Text = 'Edge registry policies in PastPolicy work immediately. Download the official ADMX/ADML files if you also want the Edge settings to appear in Local Group Policy Editor. Extract the policy files and copy msedge.admx plus its matching language folder to C:\Windows\PolicyDefinitions.'; $info.AutoSize = $true; $info.MaximumSize = New-Object Drawing.Size(700, 0); [void](Add-ContentControl $info)
    $download = New-Button 'Install Edge policy templates' { $installer = Join-Path $PSScriptRoot '..\Install-EdgePolicyTemplates.ps1'; if (Test-Path -LiteralPath $installer) { Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $installer + '"')) } else { Write-Log 'Edge policy installer was not found.' 'Red' } } $script:Accent; [void](Add-ContentControl $download)
}

function New-NavigationButton([string]$Text, [scriptblock]$Action) { $button = New-Object Windows.Forms.Button; $button.Text = $Text; $button.Width = 190; $button.Height = 42; $button.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8); $button.TextAlign = 'MiddleLeft'; $button.Padding = New-Object Windows.Forms.Padding(15, 0, 0, 0); $button.FlatStyle = 'Flat'; $button.BackColor = $script:BtnBG; $button.ForeColor = $script:Text; [void]$button.Add_Click($Action); [void]$nav.Controls.Add($button) }
New-NavigationButton 'Dashboard' { Show-Dashboard }; New-NavigationButton 'Policy Workspace' { Show-PolicyWorkspace }; New-NavigationButton 'Scenario Presets' { Show-Presets }; New-NavigationButton 'Edge ADMX Templates' { Show-EdgeTemplates }; New-NavigationButton 'View Backups' { Show-States }; New-NavigationButton 'View Logs' { Show-Logs }

Write-Log "PastPolicy started. Loaded $($script:Policies.Count) policies." 'Green'
try { Invoke-AutoBackup } catch { Write-Log "Auto-backup failed: $($_.Exception.Message)" 'Red' }
Show-Dashboard
[void]$form.Add_Shown({ $form.Activate() }); [void]$form.ShowDialog()
