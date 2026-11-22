$ErrorActionPreference = 'Stop'
try {
    $app = Join-Path $PSScriptRoot 'FPV-Profiler.ps1'
    if (!(Test-Path -LiteralPath $app)) {
        throw 'Extract the entire ZIP file before starting the app.'
    }
    & $app
} catch {
    $details = $_ | Out-String
    Write-Host $details -ForegroundColor Red
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($details, 'FPV Profiler – Startup Error')
    Read-Host 'Press Enter to close'
    exit 1
}

