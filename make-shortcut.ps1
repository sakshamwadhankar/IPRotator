<#
=============================================================================
 make-shortcut.ps1 - creates Desktop shortcuts for start, stop and status,
 each with its own icon (built-in Windows icons, nothing downloaded).
 Optional - start.bat works fine without shortcuts. To create them:
     powershell -ExecutionPolicy Bypass -File make-shortcut.ps1
 To remove the shortcuts again:
     powershell -ExecutionPolicy Bypass -File make-shortcut.ps1 -Remove
=============================================================================
#>
param([switch]$Remove)

$ErrorActionPreference = 'Stop'

# Your Desktop folder (this also works when OneDrive has moved the Desktop).
$desktop = [Environment]::GetFolderPath('Desktop')
$system32 = Join-Path $env:SystemRoot 'System32'

# Name, the file it opens, its icon (DLL,index) and the tooltip.
$shortcuts = @(
    @{ Name = 'IP Rotator - Start';  File = 'start.bat';  Icon = "$system32\shell32.dll,13";  Tip = 'Start changing your public IP' }
    @{ Name = 'IP Rotator - Stop';   File = 'stop.bat';   Icon = "$system32\shell32.dll,27";  Tip = 'Stop the IP rotator and disconnect the VPN' }
    @{ Name = 'IP Rotator - Status'; File = 'status.bat'; Icon = "$system32\imageres.dll,76"; Tip = 'Show what the IP rotator is doing' }
)

try {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($s in $shortcuts) {
        $lnkPath = Join-Path $desktop "$($s.Name).lnk"
        if ($Remove) {
            if (Test-Path $lnkPath) { Remove-Item -Path $lnkPath -Force; Write-Host "  Removed: $($s.Name)" }
            continue
        }
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath       = Join-Path $PSScriptRoot $s.File
        $lnk.WorkingDirectory = $PSScriptRoot
        $lnk.IconLocation     = $s.Icon
        $lnk.Description      = $s.Tip
        $lnk.Save()
        Write-Host "  Created: $($s.Name)"
    }
}
catch {
    Write-Host "  Couldn't update the Desktop shortcuts: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
