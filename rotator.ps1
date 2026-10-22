<#
=============================================================================
 rotator.ps1 - the background loop that changes your public IP.

 start.bat launches this hidden; you normally never run it yourself.
 It:
   1. notes your normal IP,
   2. starts Tor (hidden) and waits until it's connected,
   3. points Windows' proxy settings at Tor, so your browser's traffic
      leaves the internet from a Tor exit with a different IP,
   4. every IntervalSeconds asks Tor for a new route (= a new IP), checks
      the IP really changed (api.ipify.org) and logs it to rotator.log,
   5. when stopped, puts your proxy settings back and closes Tor.
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
    status          = 'starting'      # starting / connecting / running / changing / stopped
    message         = ''
    intervalSeconds = $IntervalSeconds
    autoStopHours   = $AutoStopHours
    startedAt       = $startTime.ToString('o')
    stopAt          = if ($stopAt) { $stopAt.ToString('o') } else { $null }
    homeIp          = $null           # your normal IP, measured before Tor starts
    currentIp       = $null
    country         = $null           # country of the current Tor exit
    torPid          = $null
    lastRotation    = $null
    nextRotation    = $null
    updatedAt       = $null
}
function Save-State {
    $state.updatedAt = (Get-Date).ToString('o')
    Write-JsonFile -Path $STATE_PATH -Data $state
}

function Set-NewIp {
    # One IP change. On the very first one Tor's routes are already new, so
    # there's no need to ask for fresh ones.
    param([switch]$First)
    $oldIp = $state.currentIp
    for ($try = 1; $try -le $NEW_IP_TRIES; $try++) {
        if (-not $First -or $try -gt 1) { Request-NewTorIdentity }
        $newIp = Get-PublicIp -Via Tor
        if ($newIp -and $newIp -ne $oldIp -and $newIp -ne $state.homeIp) {
            $country = Get-TorCountry $newIp
            Write-Log ('old IP {0} -> new IP {1} | {2}' -f $oldIp, $newIp, $country) 'ROTATE'
            $state.currentIp    = $newIp
            $state.country      = $country
            $state.lastRotation = (Get-Date).ToString('o')
            $state.message      = ''
            return
        }
        if ($newIp) { Write-Log "Tor gave the same IP again ($newIp), asking for another (try $try of $NEW_IP_TRIES)." 'WARN' }
        else        { Write-Log "Couldn't reach the internet through Tor (try $try of $NEW_IP_TRIES)." 'WARN' }
        # Tor hands out a new route at most once every 10 seconds.
        if ($try -lt $NEW_IP_TRIES) { Start-Sleep -Seconds 10 }
    }
    $state.message = "Couldn't get a new IP last time; trying again at the next change."
    Write-Log "Couldn't get a new IP this time; trying again in $(Format-Duration $IntervalSeconds)." 'ERROR'
}


# =============================================================================
#  Main part
# =============================================================================
$tor = $null
try {
    Save-State
    if (-not (Get-TorExe)) { throw 'Tor is missing. Run start.bat, which downloads it automatically.' }

    # Close a Tor left over from an earlier run, then note your normal IP.
    Stop-Tor
    $state.homeIp    = Get-PublicIp -Via Direct
    $state.currentIp = $state.homeIp

    # Start Tor and wait until it's connected (usually 5-30 seconds).
    $state.status  = 'connecting'
    $state.message = 'Connecting to the Tor network'
    Save-State
    $tor = Start-Tor -OwnerPid $PID
    $state.torPid = $tor.Id
    if (-not (Wait-TorReady -TorProcess $tor -TimeoutSeconds $TOR_START_TIMEOUT_SECONDS)) {
        throw "Tor couldn't connect within $TOR_START_TIMEOUT_SECONDS seconds. Your network may be blocking Tor."
    }

    # Send your browser's traffic through Tor.
    Set-TorProxy
    $autoStopText = if ($stopAt) { "after $AutoStopHours h (at $($stopAt.ToString('yyyy-MM-dd HH:mm')))" } else { 'off' }
    Write-Log ("Started. Interval {0} s ({1}), auto-stop {2}, normal IP {3}." -f `
        $IntervalSeconds, (Format-Duration $IntervalSeconds), $autoStopText, $state.homeIp)

    # The first change happens right away; after that, every IntervalSeconds.
    $first = $true
    $nextRotation = Get-Date
    while ($true) {
        if ($tor.HasExited) { throw 'Tor stopped unexpectedly.' }
        if ($stopAt -and (Get-Date) -ge $stopAt) {
            Write-Log "Auto-stop: $AutoStopHours h have passed."
            $state.message = 'Stopped automatically (auto-stop time reached).'
            break
        }
        if ((Get-Date) -ge $nextRotation) {
            $rotationStart = Get-Date
            $state.status = 'changing'
            $state.nextRotation = $null
            Save-State

            Set-NewIp -First:$first
            $first = $false

            # Count the interval from when this change started. If the change took
            # longer than the interval, count from now.
            $nextRotation = $rotationStart.AddSeconds($IntervalSeconds)
            if ($nextRotation -le (Get-Date)) { $nextRotation = (Get-Date).AddSeconds($IntervalSeconds) }
            $state.status = 'running'
            $state.nextRotation = $nextRotation.ToString('o')
            Save-State
        }
        Start-Sleep -Seconds 1
    }
}
catch {
    Write-Log "Stopped because of a problem: $($_.Exception.Message)" 'ERROR'
    $state.message = "Stopped because of a problem: $($_.Exception.Message)"
}
finally {
    # However we got here, give you your normal internet back.
    try { [void](Restore-ProxySettings) } catch { }
    try { if ($tor -and -not $tor.HasExited) { Stop-Process -Id $tor.Id -Force } } catch { }
    try { Stop-Tor } catch { }
    $state.status       = 'stopped'
    $state.currentIp    = $null
    $state.country      = $null
    $state.nextRotation = $null
    try { Save-State } catch { }
    # Remove the lock file, but only if it's still ours.
    $lockPid = Get-Content -Path $PID_PATH -Raw -ErrorAction SilentlyContinue
    if ($lockPid -and $lockPid.Trim() -eq "$PID") { Remove-Item -Path $PID_PATH -Force -ErrorAction SilentlyContinue }
    Write-Log 'Rotator stopped. Normal internet restored.'
    $mutex.ReleaseMutex()
}
