<#
=============================================================================
 stop.ps1 - ends the background rotator, disconnects the VPN and checks that
 your normal internet works again. Run it by double-clicking stop.bat.
=============================================================================
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    Write-Title 'IP Rotator - stop'
    $state = Read-JsonFile $STATE_PATH

    # --- 1. End the rotator --------------------------------------------------
    $proc = Get-RotatorProcess
    if ($proc) {
        Stop-Process -Id $proc.ProcessId -Force
        Wait-Process -Id $proc.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
        Remove-Item -Path $PID_PATH -Force -ErrorAction SilentlyContinue
        Write-Log 'Stopped by stop.bat.'
        Write-Host '  [OK] Rotator stopped.' -ForegroundColor Green
    } else {
        Write-Host '  [OK] The rotator was not running.' -ForegroundColor Green
    }

    # --- 2. Disconnect the VPN -----------------------------------------------
    $connected = @(Get-ConnectedRotatorConfigs)
    if ($connected.Count -gt 0) {
        Write-Host '  Disconnecting the VPN...'
        Disconnect-AllRotatorVpns -GuiPath (Find-OpenVpnGui)
    }
    if (@(Get-ConnectedRotatorConfigs).Count -gt 0) {
        Write-Host '  [!!] A VPN connection is still open. Right-click the OpenVPN GUI icon' -ForegroundColor Red
        Write-Host '       in the system tray and choose Disconnect.' -ForegroundColor Red
    } else {
        Write-Host '  [OK] VPN disconnected.' -ForegroundColor Green
    }

    # Update the saved status so status.bat shows "stopped".
    if ($state) {
        try {
            $state.status = 'stopped'
            $state.currentServer = $null
            $state.nextRotation = $null
            $state.message = 'Stopped by stop.bat.'
            Write-JsonFile -Path $STATE_PATH -Data $state
        } catch { }
    }

    # --- 3. Check your normal internet ---------------------------------------
    Write-Host '  Checking your internet connection...'
    $ip = Get-PublicIp -Tries 5
    if (-not $ip) {
        Write-Host ''
        Write-Host "  [!!] Couldn't reach the internet yet." -ForegroundColor Red
        Write-Host '       Wait 10 seconds and run status.bat. If it still fails, see' -ForegroundColor Red
        Write-Host '       "Internet not working after stop" in README.md.' -ForegroundColor Red
        exit 1
    }
    $homeIp = if ($state) { $state.homeIp } else { $null }
    if ($homeIp -and $ip -eq $homeIp) {
        Write-Host "  [OK] Internet works. Your IP is back to your normal one: $ip" -ForegroundColor Green
    } elseif ($homeIp) {
        Write-Host "  [OK] Internet works. Your public IP is now $ip" -ForegroundColor Green
        Write-Host "       (it was $homeIp before the rotator started; home IPs sometimes change, that's normal)."
    } else {
        Write-Host "  [OK] Internet works. Your public IP is $ip" -ForegroundColor Green
    }
    exit 0
}
catch {
    Show-FriendlyError $_
    exit 1
}
