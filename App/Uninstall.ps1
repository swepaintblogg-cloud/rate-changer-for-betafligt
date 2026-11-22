$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$target = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'FPV Profiler'))
if ([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ne $target.TrimEnd('\')) {
    throw 'Run the uninstaller from the installed FPV Profiler folder.'
}
$answer = [Windows.Forms.MessageBox]::Show('Close FPV Profiler, then click OK to uninstall. Your saved rates and backups will be kept.','Uninstall FPV Profiler','OKCancel')
if ($answer -ne 'OK') { exit }
try {
    foreach ($name in @('FPV-Profiler.ps1','Start.ps1','Starta-FPV-Profiler.cmd','background.png','logo.png','BurreProfiler.ico','BurreFPV.ico','Launch.vbs')) {
        $file = Join-Path $target $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('Programs'))) {
        $link = Join-Path $folder 'FPV Profiler.lnk'
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
    }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BurreFPVProfiler'
    if (Test-Path $key) { Remove-Item -LiteralPath $key }
    [Windows.Forms.MessageBox]::Show('FPV Profiler was uninstalled. Saved rates and backups were kept.','Uninstall Complete') | Out-Null
} catch {
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Uninstall Failed') | Out-Null
    exit 1
}
