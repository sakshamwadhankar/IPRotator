<#
=============================================================================
 start.ps1 - asks how often to change your IP, then starts rotator.ps1 as a
 hidden background process. Run it by double-clicking start.bat, or from a
 terminal without any questions:
     start.bat 300        change IP every 300 seconds until stop.bat
     start.bat 300 2      ... and stop by itself after 2 hours

 The first time, it downloads Tor (about 20 MB) automatically.
 Because the rotator runs as its own hidden process, pressing Ctrl+C or
 closing this window afterwards does NOT stop it. Use stop.bat for that.
=============================================================================
#>
param(
    [string]$Interval,        # optional: seconds, given on the command line
    [string]$AutoStopHours    # optional: hours, given on the command line
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Test-IntervalText {
    # Returns an explanation if the interval isn't acceptable, or '' if it's fine.
    param([string]$Text)
    if ($Text -notmatch '^\d+$') { return 'Please type a whole number of seconds, for example 120 or 3600.' }
    $number = 0
    if (-not [int]::TryParse($Text, [ref]$number)) { return 'That number is too big. Try something like 3600 (1 hour) or 86400 (1 day).' }
    if ($number -lt $MIN_INTERVAL_SECONDS) {
        return "The minimum is $MIN_INTERVAL_SECONDS seconds: asking Tor for a new IP more often puts extra load on the volunteer-run Tor network."
    }
    return ''
}

function Test-HoursText {
    # Returns the number of hours, or -1 if the text isn't a valid number of hours.
    param([string]$Text)
    $hours = 0.0
    $ok = [double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$hours)
    if ($ok -and $hours -gt 0 -and $hours -le 8760) { return $hours }
    return -1
}

try {
    Write-Title 'IP Rotator - start'

    # --- Refuse to start a second copy ---------------------------------------
    $running = Get-RotatorProcess
    if ($running) {
        Write-Host "  IP Rotator is already running (process $($running.ProcessId))." -ForegroundColor Yellow
        Write-Host '  Run stop.bat first, then start.bat again.' -ForegroundColor Yellow
        exit 1
    }

    # If the last run didn't stop cleanly (e.g. the PC was switched off),
    # quietly put your normal proxy settings back first.
    if (Test-Path $PROXY_BACKUP_PATH) { [void](Restore-ProxySettings) }
    Stop-Tor

    # --- Interval and auto-stop ----------------------------------------------
    if ($Interval) {
        # Given on the command line: no questions.
        $problem = Test-IntervalText $Interval
        if ($problem) { Write-Host "  $problem" -ForegroundColor Yellow; exit 1 }
        $seconds = [int]$Interval
        $hours = 0
        if ($AutoStopHours) {
            $hours = Test-HoursText $AutoStopHours
            if ($hours -lt 0) { Write-Host '  Auto-stop hours must be a number above 0, for example 2 or 1.5.' -ForegroundColor Yellow; exit 1 }
        }
    } else {
        # Ask. The last interval you used is offered as the default (just press Enter).
        $settings = Read-JsonFile $SETTINGS_PATH
        $lastInterval = 0
        if ($settings -and "$($settings.lastIntervalSeconds)" -match '^\d+$') { $lastInterval = [int]$settings.lastIntervalSeconds }
        if ($lastInterval -lt $MIN_INTERVAL_SECONDS) { $lastInterval = 0 }

        $seconds = 0
        while ($seconds -eq 0) {
            $question = 'Change IP every how many seconds?'
            if ($lastInterval) { $question += " [press Enter for $lastInterval]" }
            $answer = Read-Answer $question
            if (-not $answer -and $lastInterval) { $answer = "$lastInterval" }
            $problem = Test-IntervalText $answer
            if ($problem) { Write-Host "  $problem" -ForegroundColor Yellow; continue }
            if (Read-YesNo ('{0} seconds = {1}. Start? (Y/N)' -f $answer, (Format-Duration ([int]$answer)))) {
                $seconds = [int]$answer
            } else {
                Write-Host '  OK, enter a different interval (or close this window to cancel).'
            }
        }

        $hours = -1
        while ($hours -lt 0) {
            $answer = Read-Answer 'Auto-stop after how many hours? (press Enter = run until I stop it)'
            if (-not $answer) { $hours = 0; break }
            $hours = Test-HoursText $answer
            if ($hours -lt 0) { Write-Host '  Please type a number of hours above 0 (for example 2 or 1.5), or just press Enter.' -ForegroundColor Yellow }
        }
    }

    # Remember the interval for next time.
    Write-JsonFile -Path $SETTINGS_PATH -Data ([ordered]@{ lastIntervalSeconds = $seconds })

    # --- Tor: downloaded automatically the first time ------------------------
    if (-not (Get-TorExe)) {
        Write-Host ''
        Write-Host '  First run: downloading Tor (about 20 MB) from torproject.org...'
        $version = Install-Tor
        Write-Host "  [OK] Tor $version downloaded and checked." -ForegroundColor Green
    }

    # --- Launch the rotator hidden -------------------------------------------
    # A separate, hidden PowerShell process: it has no link to this window, so
    # Ctrl+C or closing this window can't stop it. "-ExecutionPolicy Bypass"
    # applies to that one process only; your system setting is never changed.
    $rotatorPath = Join-Path $PSScriptRoot 'rotator.ps1'
    $powershell  = Join-Path $PSHOME 'powershell.exe'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -IntervalSeconds {1}' -f $rotatorPath, $seconds
    if ($hours -gt 0) { $argLine += ' -AutoStopHours ' + ([double]$hours).ToString([Globalization.CultureInfo]::InvariantCulture) }
    $proc = Start-Process -FilePath $powershell -ArgumentList $argLine -WindowStyle Hidden -PassThru

    # Show progress until the first new IP is in place (usually 10-40 seconds).
    Write-Host ''
    Write-Host '  Connecting to Tor' -NoNewline
    $state = $null
    $deadline = (Get-Date).AddSeconds($TOR_START_TIMEOUT_SECONDS + 60)
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        $state = Read-JsonFile $STATE_PATH
        if ($state -and $state.pid -eq $proc.Id -and $state.lastRotation) { break }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 2
    }
    Write-Host ''

    if ($proc.HasExited) {
        Write-Host ''
        Write-Host '  The rotator stopped right after starting. Last lines of rotator.log:' -ForegroundColor Red
        if (Test-Path $LOG_PATH) { Get-Content -Path $LOG_PATH -Tail 5 | ForEach-Object { Write-Host "    $_" } }
        exit 1
    }

    Write-Host ''
    if ($state -and $state.lastRotation) {
        Write-Host "  Your IP is now $($state.currentIp) ($($state.country)). Your normal IP is $($state.homeIp)." -ForegroundColor Green
    } else {
        Write-Host '  Still connecting in the background; status.bat shows when the first new IP is ready.' -ForegroundColor Yellow
    }
    Write-Host "  Running in background, changing IP every $seconds seconds. Use stop.bat to stop." -ForegroundColor Green
    if ($hours -gt 0) {
        Write-Host ("  It will stop by itself after {0} h (at {1})." -f $hours, (Get-Date).AddHours($hours).ToString('HH:mm, ddd d MMM'))
    }
    Write-Host '  You can close this window.'
    exit 0
}
catch {
    Show-FriendlyError $_
    exit 1
}
