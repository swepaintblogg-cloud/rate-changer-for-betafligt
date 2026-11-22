param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'

$profiles = [ordered]@{
    'Smooth' = @(6, 42, 20)
    'Balanced' = @(9, 60, 15)
    'Freestyle' = @(12, 85, 25)
}

$customProfiles = @{}
$libraryPath = Join-Path $env:LOCALAPPDATA 'FPV Profiler/rates.json'
if (!$SelfTest -and (Test-Path -LiteralPath $libraryPath)) {
    try {
        $library = Get-Content -LiteralPath $libraryPath -Raw | ConvertFrom-Json
        foreach ($entry in $library.PSObject.Properties) {
            $settings = [ordered]@{}
            foreach ($item in $entry.Value.PSObject.Properties) { $settings[$item.Name] = [string]$item.Value }
            $customProfiles[$entry.Name] = $settings
        }
    } catch {
        throw "Could not read your rates library: $($_.Exception.Message)"
    }
}

function Get-ProfileSettings($name) {
    if ($customProfiles.ContainsKey($name)) { return $customProfiles[$name] }
    $values = $profiles[$name]
    if (!$values) { throw 'Select a profile.' }
    $settings = [ordered]@{rates_type = 'ACTUAL'}
    foreach ($axis in 'roll','pitch','yaw') {
        $settings[$axis + '_rc_rate'] = $values[0]
        $settings[$axis + '_srate'] = $values[1]
        $settings[$axis + '_expo'] = $values[2]
    }
    return $settings
}

function Get-SettingValue($reply, $key) {
    $match = [regex]::Match($reply, '(?im)^\s*' + [regex]::Escape($key) + '\s*=\s*([A-Z0-9]+)\s*$')
    if (!$match.Success) { throw "Could not read setting $key." }
    return $match.Groups[1].Value
}

if ($SelfTest) {
    foreach ($name in $profiles.Keys) {
        $settings = Get-ProfileSettings $name
        if ($settings.Count -ne 10 -or $settings.rates_type -ne 'ACTUAL') { throw 'Invalid profile format.' }
        if ($settings.roll_srate -lt $settings.roll_rc_rate) { throw 'Invalid rate.' }
    }
    if ((Get-SettingValue "pitch_srate = 60" 'pitch_srate') -ne '60') { throw 'CLI parsing failed.' }
    $rejected = $false
    try { [void](Get-SettingValue "set pitch_srate = 60" 'pitch_srate') }
    catch { $rejected = $true }
    if (!$rejected) { throw 'Command echo was parsed as a response.' }
    'Self-test passed'
    return
}

Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BurreWindowIdentity {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
}
"@
[void][BurreWindowIdentity]::SetCurrentProcessExplicitAppUserModelID('BurreFPV.Profiler.Desktop')
[Windows.Forms.Application]::EnableVisualStyles()

function Invoke-Cli($serial, [string]$command, [int]$timeout = 3500) {
    if ($command -eq '#') { $serial.Write($command) } else { $serial.Write($command + [char]13) }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $reply = [Text.StringBuilder]::new()
    while ($timer.ElapsedMilliseconds -lt $timeout) {
        try {
            if (!$serial.IsOpen) { throw 'The serial port is closed.' }
            [void]$reply.Append($serial.ReadExisting())
        } catch {
            throw 'USB connection lost. Reconnect the controller, click Scan Ports, and read the drone again. If saving had started, read back the values to check the result.'
        }
        if ($reply.ToString() -match '(?m)(?:^|\n)#\s*$') {
            $result = $reply.ToString()
            if ($result -match '(?im)^\s*(?:###\s*ERROR|ERROR|Unknown command|Invalid (?:name|value))') {
                throw "The controller rejected the command: $command"
            }
            return $result
        }
        Start-Sleep -Milliseconds 20
    }
    throw "Incomplete CLI response to $command. Check the COM port and close Betaflight App."
}

function Connect-Controller($port) {
    $serial = [IO.Ports.SerialPort]::new($port, 115200)
    $serial.WriteTimeout = 1500
    try {
        $serial.Open()
        Start-Sleep -Milliseconds 250
        $serial.DiscardInBuffer()
        [void](Invoke-Cli $serial '#')
        return $serial
    } catch {
        $serial.Dispose()
        throw
    }
}

function Close-Controller($serial, $saved) {
    if ($null -eq $serial) { return }
    try {
        if (!$saved -and $serial.IsOpen) { $serial.Write("exit" + [char]13) }
    } catch {
        # The controller may already have disconnected.
    } finally {
        $serial.Dispose()
    }
}

function New-Label($value, $x, $y, $w, $h) {
    $label = [Windows.Forms.Label]::new()
    $label.Text = $value
    $label.SetBounds($x,$y,$w,$h)
    $form.Controls.Add($label)
    return $label
}
function New-Button($value, $x, $y, $w) {
    $button = [Windows.Forms.Button]::new()
    $button.Text = $value
    $button.SetBounds($x,$y,$w,44)
    $form.Controls.Add($button)
    return $button
}

$form = [Windows.Forms.Form]::new()
$form.Text = 'FPV Profiler'
$form.Icon = [Drawing.Icon]::new((Join-Path $PSScriptRoot 'BurreProfiler.ico'))
$form.ClientSize = [Drawing.Size]::new(660,460)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Segoe UI',10)
[void](New-Label 'Betaflight • Rates Library' 24 20 600 34)
[void](New-Label 'COM-port' 24 62 240 23)
[void](New-Label 'Profile' 330 62 240 23)
$port = [Windows.Forms.ComboBox]::new()
$choice = [Windows.Forms.ComboBox]::new()
foreach ($box in $port,$choice) {
    $box.DropDownStyle = 'DropDownList'
    $form.Controls.Add($box)
}
$port.AccessibleName = 'COM-port'
$choice.AccessibleName = 'Rate profile'
$port.SetBounds(24,88,275,32)
$choice.SetBounds(330,88,300,32)
$choice.Items.AddRange([object[]]@($profiles.Keys))
foreach ($name in ($customProfiles.Keys | Sort-Object)) { [void]$choice.Items.Add($name) }

$preview = [Windows.Forms.TextBox]::new()
$preview.AccessibleName = 'Profile settings'
$preview.Multiline = $true
$preview.ReadOnly = $true
$preview.SetBounds(24,136,606,98)
$form.Controls.Add($preview)
$refresh = New-Button 'Scan Ports' 24 254 135
$apply = New-Button 'Review and Apply…' 175 254 250
$status = New-Label '' 24 318 606 120

$choice.Add_SelectedIndexChanged({
    if ($null -eq $choice.SelectedItem) { return }
    if ($customProfiles.ContainsKey([string]$choice.SelectedItem)) {
        $settings = Get-ProfileSettings ([string]$choice.SelectedItem)
        $preview.Text = (($settings.Keys | ForEach-Object { "$_ = $($settings[$_])" }) -join '; ')
        return
    }
    $values = $profiles[[string]$choice.SelectedItem]
    $preview.Text = "Actual Rates for roll, pitch, and yaw in the active rate profile." +
        "`r`nCenter sensitivity: $($values[0] * 10) °/s. Max rate: $($values[1] * 10) °/s. Expo: $($values[2]) %." +
        "`r`nApplies to rates in the active profile."
})
$choice.SelectedIndex = 0
$refreshPorts = {
    $port.Items.Clear()
    $ports = [IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    foreach ($name in $ports) { [void]$port.Items.Add($name) }
    $apply.Enabled = $port.Items.Count -gt 0
    if ($apply.Enabled) {
        $port.SelectedIndex = 0
        $status.Text = 'Select the COM port. Close Betaflight App before connecting.'
    } else {
        $status.Text = 'No COM ports found. Connect the flight controller with a USB data cable.'
    }
}
$refresh.Add_Click($refreshPorts)
& $refreshPorts

$apply.Add_Click({
    $serial = $null
    $saveSent = $false
    $apply.Enabled = $false
    $refresh.Enabled = $false
    try {
        $status.Text = 'Reading flight controller…'
        $form.Update()
        $serial = Connect-Controller ([string]$port.SelectedItem)
        $versionReply = Invoke-Cli $serial 'version'
        $version = [regex]::Match($versionReply, '(?im)^#\s*Betaflight /[^\r\n]*')
        if (!$version.Success) { throw 'The controller did not identify itself as Betaflight.' }
        $activeReply = Invoke-Cli $serial 'rateprofile'
        $active = [regex]::Match($activeReply, '(?im)^\s*rateprofile\s+(\d+)\s*$')
        if (!$active.Success) { throw 'Could not identify the active rate profile.' }

        $settings = Get-ProfileSettings ([string]$choice.SelectedItem)
        $changes = foreach ($key in $settings.Keys) {
            $old = Get-SettingValue (Invoke-Cli $serial "get $key") $key
            "$key   $old → $($settings[$key])"
        }
        $message = "$($version.Value)`r`nActive profile: $([int]$active.Groups[1].Value + 1)`r`n`r`n" +
            ($changes -join "`r`n") + "`r`n`r`nRemove propellers before bench testing. Back up and write these settings?"
        $answer = [Windows.Forms.MessageBox]::Show($form,$message,'Confirm changes','YesNo','Question','Button2')
        if ($answer -ne 'Yes') { $status.Text = 'Canceled.'; return }

        $status.Text = 'Saving backup…'
        $form.Update()
        $backup = Invoke-Cli $serial 'diff all' 12000
        if ($backup -notmatch '(?im)^#\s*Betaflight /' -or $backup -notmatch '(?im)^\s*save\s*$') {
            throw 'The backup appears incomplete. Writing was canceled.'
        }
        $clean = $backup -replace '(?m)^\s*(?:#\s*)?diff all\s*\r?$\n?', '' -replace '(?m)(?:^|\n)#\s*$', ''
        $backupDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'FPV Profiler Backups'
        [void][IO.Directory]::CreateDirectory($backupDir)
        $backupFile = Join-Path $backupDir ("Betaflight-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt')
        [IO.File]::WriteAllText($backupFile,$clean,[Text.Encoding]::ASCII)

        $status.Text = 'Writing and checking rates…'
        $form.Update()
        foreach ($key in $settings.Keys) {
            [void](Invoke-Cli $serial "set $key = $($settings[$key])")
        }
        foreach ($key in $settings.Keys) {
            $actual = Get-SettingValue (Invoke-Cli $serial "get $key") $key
            if ($actual -ne [string]$settings[$key]) { throw "Verification of $key failed." }
        }
        $serial.Write("save" + [char]13)
        $saveSent = $true
        $serial.Dispose()
        $serial = $null
        $status.Text = 'Checking saved rates after restart…'
        $form.Update()
        Start-Sleep -Seconds 3
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while (!$serial -and [DateTime]::UtcNow -lt $deadline) {
            try { $serial = Connect-Controller ([string]$port.SelectedItem) }
            catch { Start-Sleep -Milliseconds 500 }
        }
        if (!$serial) { throw "Could not reconnect. Save status is unknown. Backup: $backupFile" }
        $saveSent = $false
        $afterVersion = Invoke-Cli $serial 'version'
        if (!$afterVersion.Contains($version.Value)) { throw 'Controller information changed after restart.' }
        $afterProfile = Invoke-Cli $serial 'rateprofile'
        if ($afterProfile -notmatch ('(?im)^\s*rateprofile\s+' + $active.Groups[1].Value + '\s*$')) { throw 'The active rate profile changed after restart.' }
        foreach ($key in $settings.Keys) {
            $stored = Get-SettingValue (Invoke-Cli $serial "get $key") $key
            if ($stored -ne [string]$settings[$key]) { throw "Saving $key could not be verified. Backup: $backupFile" }
        }
        $status.Text = "Saved and verified after restart. Backup: $backupFile"
    } catch {
        $status.Text = "Canceled: $($_.Exception.Message)"
    } finally {
        Close-Controller $serial $saveSent
        $apply.Enabled = $true
        $refresh.Enabled = $true
    }
})
$form.ClientSize = [Drawing.Size]::new(660,750)
$lastReadSettings = $null
$read = New-Button 'Read Drone' 445 254 185
$details = [Windows.Forms.TextBox]::new()
$details.AccessibleName = 'Settings read from the drone'
$details.Multiline = $true
$details.ReadOnly = $true
$details.ScrollBars = 'Vertical'
$details.SetBounds(24,445,606,180)
$details.Text = 'Connect via USB and click Read Drone to view current settings.'
$form.Controls.Add($details)
$read.Add_Click({
    $serial = $null
    $read.Enabled = $false
    $apply.Enabled = $false
    $refresh.Enabled = $false
    $choice.Enabled = $false
    $port.Enabled = $false
    try {
        if (!$port.SelectedItem) { throw 'Select a COM port first.' }
        $script:lastReadSettings = $null
        $status.Text = 'Reading version, controller information, and current rates…'
        $form.Update()
        $serial = Connect-Controller ([string]$port.SelectedItem)
        $versionReply = Invoke-Cli $serial 'version'
        if ($versionReply -notmatch '(?im)^#\s*Betaflight /') {
            throw 'The controller did not identify itself as Betaflight.'
        }
        $output = [Collections.Generic.List[string]]::new()
        foreach ($line in ($versionReply -split "\r?\n")) {
            if ($line -match '^#\s+\S|^board_name |^manufacturer_id ') {
                $output.Add($line)
            }
        }
        $activeReply = Invoke-Cli $serial 'rateprofile'
        $active = [regex]::Match($activeReply, '(?im)^\s*rateprofile\s+(\d+)\s*$')
        if (!$active.Success) { throw 'Could not read the active rate profile.' }
        $output.Add('')
        $output.Add("Active rate profile: $([int]$active.Groups[1].Value + 1)")
        $settings = Get-ProfileSettings ([string]$choice.SelectedItem)
        foreach ($key in $settings.Keys) {
            $value = Get-SettingValue (Invoke-Cli $serial "get $key") $key
            $output.Add("$key = $value")
        }
        $script:lastReadSettings = [ordered]@{}
        foreach ($key in $settings.Keys) {
            $script:lastReadSettings[$key] = Get-SettingValue (Invoke-Cli $serial "get $key") $key
        }
        $details.Text = $output -join [Environment]::NewLine
        $status.Text = 'Read complete. Values appear below. The controller exits CLI and restarts.'
    } catch {
        $details.Text = ''
        $status.Text = "Read canceled: $($_.Exception.Message)"
    } finally {
        Close-Controller $serial $false
        $read.Enabled = $true
        $apply.Enabled = $port.Items.Count -gt 0
        $refresh.Enabled = $true
        $choice.Enabled = $true
        $port.Enabled = $true
    }
})
[void](New-Label 'Custom profile name (saves the values in the table)' 24 639 580 24)
$profileName = [Windows.Forms.TextBox]::new()
$profileName.SetBounds(24,670,330,30)
$profileName.AccessibleName = 'Custom rate profile name'
$form.Controls.Add($profileName)
$saveOwn = New-Button 'Save My Rates' 375 665 255
$saveOwn.Add_Click({
    try {
        if ($grid.Rows.Count -ne 10) { throw 'Click Read Drone first.' }
        [void]$grid.EndEdit()
        $edited = [ordered]@{}
        foreach ($row in $grid.Rows) {
            $key = [string]$row.Tag
            $value = Get-EditorValue $row
            if ($key -eq 'rates_type') {
                if ($value -notin @('ACTUAL','BETAFLIGHT','RACEFLIGHT','KISS','QUICK')) { throw 'Select a valid rate type.' }
            } else {
                $maximum = 255
                $minimum = 0
                if ($key.EndsWith('_expo')) { $maximum = 100 }
                if ($key.EndsWith('_rc_rate')) { $minimum = 1 }
                if ($value -notmatch '^\d+$' -or [int]$value -lt $minimum -or [int]$value -gt $maximum) { throw "Invalid value for $key" }
            }
            $edited[$key] = $value
        }
        $name = $profileName.Text.Trim()
        if (!$name -or $name.Length -gt 60) { throw 'Enter a name with 1–60 characters.' }
        if ($profiles.Contains($name)) { throw 'Choose a name different from the built-in profiles.' }
        if ($customProfiles.ContainsKey($name)) {
            if ([Windows.Forms.MessageBox]::Show($form,'Replace the saved profile?','Save Rates','YesNo') -ne 'Yes') { return }
        }
        $updated = @{}
        foreach ($key in $customProfiles.Keys) { $updated[$key] = $customProfiles[$key] }
        $updated[$name] = $edited
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($libraryPath))
        $temporary = $libraryPath + '.tmp'
        [IO.File]::WriteAllText($temporary,($updated | ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
        if (Test-Path -LiteralPath $libraryPath) {
            [IO.File]::Replace($temporary,$libraryPath,($libraryPath + '.bak'))
        } else { [IO.File]::Move($temporary,$libraryPath) }
        $customProfiles[$name] = $edited
        if (!$choice.Items.Contains($name)) { [void]$choice.Items.Add($name) }
        $choice.SelectedItem = $name
        $status.Text = "Your rates have been saved as $name. Select the profile in the list to apply it."
    } catch {
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Save Rates')
    }
})
$form.AutoScroll = $true
$form.ClientSize = [Drawing.Size]::new(660,820)
$importButton = New-Button 'Import' 24 727 140
$exportButton = New-Button 'Export' 179 727 140
$renameButton = New-Button 'Rename' 334 727 140
$deleteButton = New-Button 'Delete' 489 727 140
function Save-OwnLibrary($updated) {
    $temporary = $libraryPath + '.tmp'
    [IO.File]::WriteAllText($temporary,($updated | ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($libraryPath))
    if (Test-Path $libraryPath) { [IO.File]::Replace($temporary,$libraryPath,($libraryPath + '.bak')) }
    else { [IO.File]::Move($temporary,$libraryPath) }
    $script:customProfiles = $updated
    $choice.Items.Clear()
    $choice.Items.AddRange([object[]]@($profiles.Keys))
    foreach ($name in ($updated.Keys | Sort-Object)) { [void]$choice.Items.Add($name) }
    $choice.SelectedIndex = 0
}
$importButton.Add_Click({
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Filter = 'Rate profile (*.json)|*.json'
    try {
        if ($dialog.ShowDialog() -ne 'OK') { return }
        $file = Get-Content -LiteralPath $dialog.FileName -Raw | ConvertFrom-Json
        $name = [string]$file.name
        if (!$name.Trim() -or $name.Length -gt 60 -or $profiles.Contains($name)) { throw 'Invalid name.' }
        $settings = [ordered]@{}
        $expected = (Get-ProfileSettings 'Smooth').Keys
        foreach ($key in $expected) {
            $value = [string]$file.settings.$key
            if ($key -eq 'rates_type') {
                if ($value -notin @('ACTUAL','BETAFLIGHT','KISS','QUICK','RACEFLIGHT')) { throw 'Invalid rate type.' }
            } else {
                $maximum = 255
                if ($key.EndsWith('_expo')) { $maximum = 100 }
                if ($value -notmatch '^\d+$' -or [int]$value -gt $maximum) { throw "Invalid value for $key" }
            }
            $settings[$key] = $value
        }
        if ($customProfiles.ContainsKey($name) -and [Windows.Forms.MessageBox]::Show('Replace this profile?','Import','YesNo') -ne 'Yes') { return }
        $updated = $customProfiles.Clone()
        $updated[$name] = $settings
        Save-OwnLibrary $updated
        $choice.SelectedItem = $name
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Import') }
    finally { $dialog.Dispose() }
})
$exportButton.Add_Click({
    $dialog = [Windows.Forms.SaveFileDialog]::new()
    $dialog.Filter = 'Rate profile (*.json)|*.json'
    $dialog.FileName = 'rates.json'
    try {
        if ($dialog.ShowDialog() -ne 'OK') { return }
        $data = @{name=[string]$choice.SelectedItem; settings=(Get-ProfileSettings ([string]$choice.SelectedItem)); format=1}
        [IO.File]::WriteAllText($dialog.FileName,($data | ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Export') }
    finally { $dialog.Dispose() }
})
$renameButton.Add_Click({
    try {
        $old = [string]$choice.SelectedItem
        $name = $profileName.Text.Trim()
        if (!$customProfiles.ContainsKey($old)) { throw 'Select a custom profile.' }
        if (!$name -or $name.Length -gt 60 -or $profiles.Contains($name) -or $customProfiles.ContainsKey($name)) { throw 'Enter an unused name in the name field.' }
        $updated = $customProfiles.Clone()
        $updated[$name] = $updated[$old]
        $updated.Remove($old)
        Save-OwnLibrary $updated
        $choice.SelectedItem = $name
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Rename') }
})
$deleteButton.Add_Click({
    try {
        $name = [string]$choice.SelectedItem
        if (!$customProfiles.ContainsKey($name)) { throw 'Select a custom profile.' }
        if ([Windows.Forms.MessageBox]::Show("Delete $name?",'Delete','YesNo') -ne 'Yes') { return }
        $updated = $customProfiles.Clone()
        $updated.Remove($name)
        Save-OwnLibrary $updated
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Delete') }
})
$form.ClientSize = [Drawing.Size]::new(660,900)
$details.Visible = $false
$grid = [Windows.Forms.DataGridView]::new()
$grid.SetBounds(24,445,606,180)
$grid.AccessibleName = 'Edit rates read from the controller'
$grid.EditMode = 'EditOnEnter'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = 'Fill'
[void]$grid.Columns.Add('Setting','Setting')
[void]$grid.Columns.Add('Value','Value')
$grid.Columns[0].ReadOnly = $true
$grid.DefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(26,25,21)
$grid.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(142,255,36)
$grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(50,65,30)
$grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
$form.Controls.Add($grid)
function Show-Rates($settings) {
    $script:loadingRates = $true
    try {
        $grid.Rows.Clear()
        $type = [string]$settings['rates_type']
        $script:displayRateType = $type
        if ($type -eq 'ACTUAL') { $rateType.SelectedIndex = 1 }
        elseif ($type -eq 'BETAFLIGHT') { $rateType.SelectedIndex = 0 }
        else { $rateType.SelectedIndex = -1 }
        $index = $grid.Rows.Add('rates_type',$type)
        $grid.Rows[$index].Tag = 'rates_type'
        $grid.Rows[$index].Visible = $false
        foreach ($axis in 'roll','pitch','yaw') {
            foreach ($suffix in 'rc_rate','srate','expo') {
                $key = $axis + '_' + $suffix
                $raw = [double]$settings[$key]
                $label = $axis.ToUpperInvariant() + ' — '
                if ($type -eq 'ACTUAL') {
                    switch ($suffix) {
                        'rc_rate' { $label += 'Center Sensitivity (°/s)'; $number = $raw * 10 }
                        'srate' { $label += 'Max Rate (°/s)'; $number = $raw * 10 }
                        'expo' { $label += 'Expo'; $number = $raw / 100 }
                    }
                } elseif ($type -eq 'BETAFLIGHT') {
                    switch ($suffix) {
                        'rc_rate' { $label += 'RC Rate' }
                        'srate' { $label += 'Super Rate' }
                        'expo' { $label += 'RC Expo' }
                    }
                    $number = $raw / 100
                } else { $label += $suffix + ' (CLI)'; $number = $raw }
                $index = $grid.Rows.Add($label,$number.ToString('0.##',[Globalization.CultureInfo]::GetCultureInfo('en-US')))
                $grid.Rows[$index].Tag = $key
            }
        }
    } finally { $script:loadingRates = $false }
}
function Get-EditorValue($row) {
    $key = [string]$row.Tag
    if ($key -eq 'rates_type') { return [string]$row.Cells[1].Value }
    $text = ([string]$row.Cells[1].Value).Trim().Replace(',','.')
    $number = 0.0
    if (![double]::TryParse($text,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw "Enter a number for $key." }
    if ($script:displayRateType -eq 'BETAFLIGHT' -or ($script:displayRateType -eq 'ACTUAL' -and $key.EndsWith('_expo'))) { $number *= 100 }
    elseif ($script:displayRateType -eq 'ACTUAL') { $number /= 10 }
    $rounded = [Math]::Round($number)
    if ([Math]::Abs($number - $rounded) -gt 0.00001) { throw "The value for $key has too many decimal places. Actual angular rates use increments of 10 deg/s." }
    return $rounded.ToString('0',[Globalization.CultureInfo]::InvariantCulture)
}
$status.SetBounds(24,310,606,90)
$rateLabel = New-Label 'Rate Type' 24 415 130 23
$rateLabel.BringToFront()
$rateType = [Windows.Forms.ComboBox]::new()
$rateType.AccessibleName = 'Choose Betaflight Rates or Actual Rates'
$rateType.DropDownStyle = 'DropDownList'
$rateType.SetBounds(160,410,470,30)
$rateType.Items.AddRange([object[]]@('Betaflight Rates','Actual Rates'))
$form.Controls.Add($rateType)
$rateType.BringToFront()
$rateType.Add_SelectedIndexChanged({
    if ($script:loadingRates -or $rateType.SelectedIndex -lt 0) { return }
    $type = @('BETAFLIGHT','ACTUAL')[$rateType.SelectedIndex]
    if ($script:displayRateType -eq $type) { return }
    $settings = [ordered]@{rates_type=$type}
    foreach ($axis in 'roll','pitch','yaw') {
        if ($type -eq 'ACTUAL') { $settings[$axis+'_rc_rate']=7; $settings[$axis+'_srate']=67; $settings[$axis+'_expo']=0 }
        else { $settings[$axis+'_rc_rate']=100; $settings[$axis+'_srate']=70; $settings[$axis+'_expo']=0 }
    }
    Show-Rates $settings
    $status.Text = 'Rate type selected. Starter values loaded. Edit them and review the changes before writing.'
})
$details.Add_TextChanged({
    $settings = [ordered]@{}
    foreach ($line in ($details.Text -split '\r?\n')) {
        if ($line -match '^([a-z_]+) = ([A-Z0-9]+)$') { $settings[$matches[1]] = $matches[2] }
    }
    if ($settings.Count -eq 10) { Show-Rates $settings }
})
$writeEdited = New-Button 'Review and Write Edited Rates' 24 790 606
$writeEdited.Add_Click({
    try {
        [void]$grid.EndEdit()
        $settings = [ordered]@{}
        foreach ($row in $grid.Rows) {
            $key = [string]$row.Tag
            $value = Get-EditorValue $row
            if ($key -eq 'rates_type') {
                if ($value -notin @('ACTUAL','BETAFLIGHT','RACEFLIGHT','KISS','QUICK')) { throw 'Rate type must be ACTUAL, BETAFLIGHT, RACEFLIGHT, KISS, or QUICK.' }
            } else {
                $maximum = 255
                $minimum = 0
                if ($key.EndsWith('_expo')) { $maximum = 100 }
                if ($key.EndsWith('_rc_rate')) { $minimum = 1 }
                if ($value -notmatch '^\d+$' -or [int]$value -lt $minimum -or [int]$value -gt $maximum) {
                    throw "The value for $key must be a whole number between $minimum and $maximum."
                }
            }
            $settings[$key] = $value
        }
        if ($settings.Count -ne 10) { throw 'Click Read Drone first to populate the table.' }
        $temporaryName = 'Edited values (temporary)'
        $previous = $choice.SelectedItem
        $hadPrevious = $customProfiles.ContainsKey($temporaryName)
        $previousSettings = $customProfiles[$temporaryName]
        try {
            $customProfiles[$temporaryName] = $settings
            if (!$choice.Items.Contains($temporaryName)) { [void]$choice.Items.Add($temporaryName) }
            $choice.SelectedItem = $temporaryName
            $apply.PerformClick()
        } finally {
            if ($hadPrevious) { $customProfiles[$temporaryName] = $previousSettings }
            else { $customProfiles.Remove($temporaryName); $choice.Items.Remove($temporaryName) }
            $choice.SelectedItem = $previous
        }
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Edit Rates') }
})
$loadSelected = New-Button 'Edit Selected Profile' 24 842 606
$form.ClientSize = [Drawing.Size]::new(660,960)
$loadSelected.Add_Click({
    try {
        $settings = Get-ProfileSettings ([string]$choice.SelectedItem)
        $lines = foreach ($key in $settings.Keys) { "$key = $($settings[$key])" }
        $details.Text = ''
        $details.Text = $lines -join [Environment]::NewLine
        $status.Text = 'Choose a rate type and edit the values. Switching types loads starter values.'
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Edit Profile') }
})
$form.Text = 'BURRE FPV Profiler 1.0.0'
$form.BackColor = [Drawing.Color]::FromArgb(22,20,17)
$form.ForeColor = [Drawing.Color]::FromArgb(142,255,36)
$backgroundPath = Join-Path $PSScriptRoot 'background.png'
$backgroundImage = $null
if (Test-Path -LiteralPath $backgroundPath) {
    $backgroundImage = [Drawing.Image]::FromFile($backgroundPath)
    $form.BackgroundImage = $backgroundImage
    $form.BackgroundImageLayout = 'Stretch'
}
foreach ($control in $form.Controls) {
    $control.ForeColor = [Drawing.Color]::FromArgb(142,255,36)
    $control.BackColor = [Drawing.Color]::FromArgb(26,25,21)
    if ($control -is [Windows.Forms.Button]) {
        $control.FlatStyle = 'Flat'
        $control.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(104,143,49)
        $control.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(49,61,30)
        $control.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(66,83,37)
    }
}
$form.Controls[0].Text = 'BURRE FPV  /  PROFILE LIBRARY'
$form.Controls[0].Font = [Drawing.Font]::new('Segoe UI',15,[Drawing.FontStyle]::Bold)
$preview.BorderStyle = 'FixedSingle'
$form.Add_FormClosed({
    if ($backgroundImage) { $backgroundImage.Dispose() }
})
$grid.BackgroundColor = [Drawing.Color]::FromArgb(26,25,21)
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(42,44,30)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(142,255,36)
$grid.BorderStyle = 'FixedSingle'
foreach ($control in $form.Controls) {
    if ($control -is [Windows.Forms.Label] -and $control.Text -match 'Betaflight.*Rates Library|BURRE FPV  /') {
        $control.Text = 'BURRE FPV  /  PROFILE LIBRARY'
        $control.Font = [Drawing.Font]::new('Segoe UI',15,[Drawing.FontStyle]::Bold)
    }
}
Show-Rates (Get-ProfileSettings ([string]$choice.SelectedItem))
$status.Text = 'The table shows the selected library profile. Click Read Drone to read the current drone rates.'
$choice.Add_SelectedIndexChanged({
    if ($choice.SelectedItem -and !$script:loadingRates) {
        Show-Rates (Get-ProfileSettings ([string]$choice.SelectedItem))
    }
})
$brand = [Windows.Forms.PictureBox]::new()
$brand.SetBounds(250,900,160,50)
$brand.SizeMode = 'Zoom'
$brand.BackColor = [Drawing.Color]::FromArgb(26,25,21)
$brand.AccessibleName = 'BURRE FPV'
$logoPath = Join-Path $PSScriptRoot 'logo.png'
if (Test-Path -LiteralPath $logoPath) { $brand.Image = [Drawing.Image]::FromFile($logoPath) }
$form.Controls.Add($brand)
$form.Add_FormClosed({ if ($brand.Image) { $brand.Image.Dispose() } })
foreach ($combo in @($port,$choice,$rateType)) {
    $combo.FlatStyle = 'Flat'
    $combo.DrawMode = 'OwnerDrawFixed'
    $combo.ItemHeight = 25
    $combo.BackColor = [Drawing.Color]::FromArgb(26,25,21)
    $combo.ForeColor = [Drawing.Color]::FromArgb(142,255,36)
    $combo.Add_DrawItem({
        param($sender,$eventArgs)
        $background = [Drawing.Color]::FromArgb(26,25,21)
        if (($eventArgs.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0) {
            $background = [Drawing.Color]::FromArgb(49,61,30)
        }
        $brush = [Drawing.SolidBrush]::new($background)
        try { $eventArgs.Graphics.FillRectangle($brush,$eventArgs.Bounds) }
        finally { $brush.Dispose() }
        if ($eventArgs.Index -ge 0) {
            $bounds = $eventArgs.Bounds
            $bounds.X += 4
            $bounds.Width -= 4
            [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,[string]$sender.Items[$eventArgs.Index],$sender.Font,$bounds,[Drawing.Color]::FromArgb(142,255,36),([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
        }
    })
}
$profileName.BorderStyle = 'FixedSingle'
$profileName.BackColor = [Drawing.Color]::FromArgb(26,25,21)
$profileName.ForeColor = [Drawing.Color]::FromArgb(142,255,36)
$grid.ScrollBars = 'None'
$grid.Height = 225
$grid.RowTemplate.Height = 20
foreach ($row in $grid.Rows) { $row.Height = 20 }
$grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$grid.ColumnHeadersHeight = 23
foreach ($control in @($profileName,$saveOwn)) { $control.Top += 45 }
foreach ($control in $form.Controls) {
    if ($control -is [Windows.Forms.Label] -and $control.Text -like 'Custom profile name*') { $control.Top += 45 }
}
foreach ($control in @($importButton,$exportButton,$renameButton,$deleteButton,$writeEdited,$loadSelected,$brand)) { $control.Top += 45 }
$form.ClientSize = [Drawing.Size]::new(660,1005)
[void]$form.ShowDialog()
