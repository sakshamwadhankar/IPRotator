<#
=============================================================================
 stop.ps1 - ends the background rotator, closes Tor, puts your proxy settings
 back and checks that your normal internet works. Run it by double-clicking
 stop.bat. (-Quiet is used by the restart safety net: no output.)
=============================================================================
#>
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

try {
    if (-not $Quiet) { Write-Title 'IP Rotator - stop' }
    $state = Read-JsonFile $STATE_PATH

    # --- 1. End the rotator --------------------------------------------------
    $proc = Get-RotatorProcess
    if ($proc) {
        Stop-Process -Id $proc.ProcessId -Force
        Wait-Process -Id $proc.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
        Remove-Item -Path $PID_PATH -Force -ErrorAction SilentlyContinue
        Write-Log 'Stopped by stop.bat.'
        Say '  [OK] Rotator stopped.' 'Green'
    } else {
        Say '  [OK] The rotator was not running.' 'Green'
    }

    # --- 2. Close Tor and restore the proxy settings -------------------------
    Stop-Tor
    if (Restore-ProxySettings) {
        Write-Log 'Proxy settings restored by stop.bat.'
        Say '  [OK] Your normal proxy settings are back.' 'Green'
    } else {
        Say '  [OK] Proxy settings were already normal.' 'Green'
    }

    # Update the saved status so status.bat shows "stopped".
    if ($state) {
        try {
            $state.status = 'stopped'
            $state.currentIp = $null
            $state.country = $null
            $state.nextRotation = $null
            $state.message = 'Stopped by stop.bat.'
            Write-JsonFile -Path $STATE_PATH -Data $state
        } catch { }
    }
    if ($Quiet) { exit 0 }

    # --- 3. Check your normal internet ---------------------------------------
    Say '  Checking your internet connection...'
    $ip = Get-PublicIp -Via System -Tries 5
    if (-not $ip) {
        Say ''
        Say "  [!!] Couldn't reach the internet yet." 'Red'
        Say '       Wait 10 seconds and run status.bat. If it still fails, see' 'Red'
        Say '       "Internet not working after stop" in README.md.' 'Red'
        exit 1
    }
    $homeIp = if ($state) { $state.homeIp } else { $null }
    if ($homeIp -and $ip -eq $homeIp) {
        Say "  [OK] Internet works. Your IP is back to your normal one: $ip" 'Green'
    } elseif ($homeIp) {
        Say "  [OK] Internet works. Your public IP is now $ip" 'Green'
        Say "       (it was $homeIp before the rotator started; home IPs sometimes change, that's normal)."
    } else {
        Say "  [OK] Internet works. Your public IP is $ip" 'Green'
    }
    exit 0
}
catch {
    if (-not $Quiet) { Show-FriendlyError $_ }
    exit 1
}
