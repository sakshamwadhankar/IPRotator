<#
=============================================================================
 rotator.ps1 - the background loop that changes your public IP.

 start.bat launches this hidden; you normally never run it yourself.
 Right after starting, and then every IntervalSeconds, it:
   1. disconnects the current Proton server (the free plan allows only one
      connection at a time),
   2. connects to a different, randomly chosen server through OpenVPN GUI,
   3. checks with api.ipify.org that your public IP really changed,
   4. tries the next server if not. If every server fails, it leaves you on
      your normal internet and tries again at the next interval,
   5. writes the change to rotator.log.
 It runs until stop.bat ends it, or until AutoStopHours have passed.
=============================================================================
#>
param(
    # Seconds between IP changes. Always comes from your answer in start.bat.
    [Parameter(Mandatory = $true)]
    [int]$IntervalSeconds,

    # Stop automatically after this many hours. 0 = run until stop.bat.
    [double]$AutoStopHours = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# --- Only one rotator at a time ----------------------------------------------
# start.bat already checks rotator.pid; this named lock is a second safety net.
$mutex = New-Object System.Threading.Mutex($false, 'Local\IPRotator-rotator')
try { $haveLock = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $haveLock = $true }  # the last rotator was ended by stop.bat; the lock is ours now
if (-not $haveLock) {
    Write-Log 'Another rotator is already running, so this copy is exiting.' 'WARN'
    exit 1
}

# Save our process ID: this is the lock file stop.bat and status.bat use.
Set-Content -Path $PID_PATH -Value $PID -Encoding ASCII

# Safety net in case someone runs rotator.ps1 by hand with a tiny interval.
if ($IntervalSeconds -lt $MIN_INTERVAL_SECONDS) {
    Write-Log "Interval of $IntervalSeconds s is below the minimum, using $MIN_INTERVAL_SECONDS s instead." 'WARN'
    $IntervalSeconds = $MIN_INTERVAL_SECONDS
}

# Everything status.bat shows comes from here (saved to state.json).
$startTime = Get-Date
$stopAt = if ($AutoStopHours -gt 0) { $startTime.AddHours($AutoStopHours) } else { $null }
$state = [ordered]@{
    pid             = $PID
    status          = 'starting'      # starting / switching / connected / not connected / stopped
    message         = ''
    intervalSeconds = $IntervalSeconds
    autoStopHours   = $AutoStopHours
    startedAt       = $startTime.ToString('o')
    stopAt          = if ($stopAt) { $stopAt.ToString('o') } else { $null }
    homeIp          = $null           # your normal IP, measured before the first switch
    currentServer   = $null           # e.g. nl-free-12.protonvpn.udp (null = normal internet)
    currentIp       = $null
    lastRotation    = $null
    nextRotation    = $null
    updatedAt       = $null
}
function Save-State {
    $state.updatedAt = (Get-Date).ToString('o')
    Write-JsonFile -Path $STATE_PATH -Data $state
}

function Get-ServerName {
    # "iprot-nl-free-12.protonvpn.udp" -> "nl-free-12.protonvpn.udp"
    param([string]$ConfigName)
    return $ConfigName.Substring($CONFIG_NAME_PREFIX.Length)
}

function Invoke-Rotation {
    # One IP change. Uses $gui and $configNames from the main part below.
    $oldIp = Get-PublicIp
    if (-not $oldIp) { $oldIp = $state.currentIp }
    $current = if ($state.currentServer) { $CONFIG_NAME_PREFIX + $state.currentServer } else { $null }

    # Every config except the one we're on now, in random order.
    $candidates = @($configNames | Where-Object { $_ -ne $current } | Sort-Object { Get-Random })

    # Proton Free allows one connection at a time, so disconnect first.
    if ($current) { Disconnect-Vpn -GuiPath $gui -Name $current }

    $authFailures = 0
    foreach ($name in $candidates) {
        $server = Get-ServerName $name
        $state.message = "Connecting to $server"
        Save-State

        $result = Connect-Vpn -GuiPath $gui -Name $name
        if ($result -eq 'ok') {
            $newIp = Get-PublicIp
            if ($newIp -and $newIp -ne $oldIp -and $newIp -ne $state.homeIp) {
                # Success!
                Write-Log ('old IP {0} -> new IP {1} | server {2}' -f $oldIp, $newIp, $server) 'ROTATE'
                $state.status        = 'connected'
                $state.currentServer = $server
                $state.currentIp     = $newIp
                $state.lastRotation  = (Get-Date).ToString('o')
                $state.message       = ''
                return
            }
            Write-Log "$server connected, but the IP didn't change ($newIp). Trying another server." 'WARN'
        }
        elseif ($result -eq 'auth-failed') {
            $authFailures++
            Write-Log "$server rejected the login (AUTH_FAILED)." 'WARN'
            if ($authFailures -ge 2) {
                Write-Log 'Proton rejected the OpenVPN username/password twice. Run setup.bat to re-enter them (use the OpenVPN/IKEv2 credentials, not your Proton email login). The free plan also refuses logins while you are connected on another device.' 'ERROR'
                Disconnect-Vpn -GuiPath $gui -Name $name
                break
            }
        }
        else {
            Write-Log "$server did not connect ($result). Trying another server." 'WARN'
        }
        Disconnect-Vpn -GuiPath $gui -Name $name
    }

    # Nothing worked: make sure you're back on your normal internet.
    Disconnect-AllRotatorVpns -GuiPath $gui
    $state.status        = 'not connected'
    $state.currentServer = $null
    $state.currentIp     = Get-PublicIp
    $state.message       = 'Every server failed last time; using your normal internet until the next try.'
    Write-Log "Couldn't switch to any server; using your normal internet until the next try in $(Format-Duration $IntervalSeconds)." 'ERROR'
}


# =============================================================================
#  Main part
# =============================================================================
$gui = $null
try {
    Save-State

    # Is everything set up?
    $problems = @(Get-SetupProblems)
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Log $p 'ERROR' }
        $state.message = $problems -join ' '
        exit 1
    }
    $gui = Find-OpenVpnGui

    # Hand your UDP configs to OpenVPN GUI (TCP ones are skipped).
    $configs = Get-SourceConfigs
    foreach ($tcp in $configs.Tcp) { Write-Log "Skipping $($tcp.Name): it's a TCP config, only UDP ones are used." 'WARN' }
    $configNames = @(Sync-VpnConfigs -Files $configs.Udp)
    Start-OpenVpnGui -GuiPath $gui

    # Start from a clean slate, then note your normal IP for later comparison.
    Disconnect-AllRotatorVpns -GuiPath $gui
    $state.homeIp    = Get-PublicIp
    $state.currentIp = $state.homeIp
    $autoStopText = if ($stopAt) { "after $AutoStopHours h (at $($stopAt.ToString('yyyy-MM-dd HH:mm')))" } else { 'off' }
    Write-Log ("Started. Interval {0} s ({1}), auto-stop {2}, {3} UDP configs, normal IP {4}." -f `
        $IntervalSeconds, (Format-Duration $IntervalSeconds), $autoStopText, $configNames.Count, $state.homeIp)

    # The first switch happens right away; after that, every IntervalSeconds.
    $nextRotation = Get-Date
    while ($true) {
        if ($stopAt -and (Get-Date) -ge $stopAt) {
            Write-Log "Auto-stop: $AutoStopHours h have passed."
            $state.message = 'Stopped automatically (auto-stop time reached).'
            break
        }
        if ((Get-Date) -ge $nextRotation) {
            $rotationStart = Get-Date
            $state.status = 'switching'
            $state.nextRotation = $null
            Save-State

            Invoke-Rotation

            # Count the interval from when this switch started. If the switch took
            # longer than the interval (several servers failed), count from now.
            $nextRotation = $rotationStart.AddSeconds($IntervalSeconds)
            if ($nextRotation -le (Get-Date)) { $nextRotation = (Get-Date).AddSeconds($IntervalSeconds) }
            $state.nextRotation = $nextRotation.ToString('o')
            Save-State
        }
        Start-Sleep -Seconds 1
    }
}
catch {
    Write-Log "Stopped because of an unexpected problem: $($_.Exception.Message)" 'ERROR'
    $state.message = "Stopped because of an unexpected problem: $($_.Exception.Message)"
}
finally {
    # However we got here, leave you on your normal internet.
    if ($gui) { try { Disconnect-AllRotatorVpns -GuiPath $gui } catch { } }
    $state.status        = 'stopped'
    $state.currentServer = $null
    $state.nextRotation  = $null
    try { Save-State } catch { }
    # Remove the lock file, but only if it's still ours.
    $lockPid = Get-Content -Path $PID_PATH -Raw -ErrorAction SilentlyContinue
    if ($lockPid -and $lockPid.Trim() -eq "$PID") { Remove-Item -Path $PID_PATH -Force -ErrorAction SilentlyContinue }
    Write-Log 'Rotator stopped.'
    $mutex.ReleaseMutex()
}
