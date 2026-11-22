$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
try {
    $target = Join-Path $env:LOCALAPPDATA 'FPV Profiler'
    [void][IO.Directory]::CreateDirectory($target)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'App/FPV-Profiler.ps1') -Destination $target -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'App/Start.ps1') -Destination $target -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'App/Starta-FPV-Profiler.cmd') -Destination $target -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'App/background.png') -Destination $target -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'App/logo.png') -Destination $target -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'App/BurreProfiler.ico') -Destination $target -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'App/Launch.vbs') -Destination $target -Force
    $shell = New-Object -ComObject WScript.Shell
    $powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        $shortcut = $shell.CreateShortcut((Join-Path $folder 'FPV Profiler.lnk'))
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32/wscript.exe'
        $shortcut.Arguments = '"' + (Join-Path $target 'Launch.vbs') + '"'
        $shortcut.IconLocation = (Join-Path $target 'BurreProfiler.ico') + ',0'
        $shortcut.WorkingDirectory = $target
        $shortcut.Description = 'Betaflight rates library'
        $shortcut.Save()
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'App/Uninstall.ps1') -Destination $target -Force
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BurreFPVProfiler'
    [void](New-Item -Path $key -Force)
    $uninstall = '"' + $powershell + '" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $target 'Uninstall.ps1') + '"'
    $properties = @{
        DisplayName = 'BURRE FPV Profiler'
        DisplayVersion = '1.0.0'
        Publisher = 'BURRE FPV'
        InstallLocation = $target
        DisplayIcon = (Join-Path $target 'BurreProfiler.ico')
        UninstallString = $uninstall
    }
    foreach ($name in $properties.Keys) {
        New-ItemProperty -Path $key -Name $name -Value $properties[$name] -PropertyType String -Force | Out-Null
    }
    New-ItemProperty -Path $key -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
    [void][Windows.Forms.MessageBox]::Show('FPV Profiler is installed. Open it using the desktop or Start menu shortcut.','Installation Complete')
} catch {
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Installation Failed')
    exit 1
}

