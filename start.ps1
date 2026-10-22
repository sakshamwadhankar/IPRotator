<#
=============================================================================
 start.ps1 - asks how often to change your IP, then starts rotator.ps1 as a
 hidden background process and returns. Run it by double-clicking start.bat.

 Because the rotator runs as its own hidden process, pressing Ctrl+C or
 closing this window afterwards does NOT stop it. Use stop.bat for that.
=============================================================================
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    Write-Title 'IP Rotator - start'

    # --- Refuse to start a second copy ---------------------------------------
    $running = Get-RotatorProcess
    if ($running) {
        Write-Host "  IP Rotator is already running (process $($running.ProcessId))." -ForegroundColor Yellow
        Write-Host '  Run stop.bat first, then start.bat again.' -ForegroundColor Yellow
        exit 1
    }

    # --- Make sure setup is done ---------------------------------------------
    $problems = @(Get-SetupProblems)
    if ($problems.Count -gt 0) {
        Write-Host "  IP Rotator can't start yet:" -ForegroundColor Yellow
        foreach ($p in $problems) { Write-Host "   - $p" -ForegroundColor Yellow }
        exit 1
    }

    # --- Question 1: the interval --------------------------------------------
    # The last interval you used is offered as the default (just press Enter).
    $settings = Read-JsonFile $SETTINGS_PATH
    $lastInterval = 0
    if ($settings -and "$($settings.lastIntervalSeconds)" -match '^\d+$') { $lastInterval = [int]$settings.lastIntervalSeconds }
    if ($lastInterval -lt $MIN_INTERVAL_SECONDS) { $lastInterval = 0 }

    $interval = 0
    while ($interval -eq 0) {
        $question = 'Change IP every how many seconds?'
        if ($lastInterval) { $question += " [press Enter for $lastInterval]" }
        $answer = Read-Answer $question
        if (-not $answer -and $lastInterval) { $answer = "$lastInterval" }

        # Whole numbers only.
        $number = 0
        if ($answer -notmatch '^\d+$') {
            Write-Host '  Please type a whole number of seconds, for example 120 or 3600.' -ForegroundColor Yellow
            continue
        }
        if (-not [int]::TryParse($answer, [ref]$number)) {
            Write-Host '  That number is too big. Try something like 3600 (1 hour) or 86400 (1 day).' -ForegroundColor Yellow
            continue
        }
        # Enforce the minimum, and explain why.
        if ($number -lt $MIN_INTERVAL_SECONDS) {
            Write-Host "  The minimum is $MIN_INTERVAL_SECONDS seconds. Each switch takes 10-30 seconds to reconnect," -ForegroundColor Yellow
            Write-Host '  and reconnecting very often can get a free Proton account throttled.' -ForegroundColor Yellow
            continue
        }
        # Echo it back in readable form and confirm.
        if (Read-YesNo ('{0} seconds = {1}. Start? (Y/N)' -f $number, (Format-Duration $number))) {
            $interval = $number
        } else {
            Write-Host '  OK, enter a different interval (or close this window to cancel).'
        }
    }

    # --- Question 2: auto-stop -----------------------------------------------
    $autoStopHours = -1
    while ($autoStopHours -lt 0) {
        $answer = Read-Answer 'Auto-stop after how many hours? (press Enter = run until I stop it)'
        if (-not $answer) { $autoStopHours = 0; break }
        $hours = 0.0
        $isNumber = [double]::TryParse($answer, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$hours)
        if ($isNumber -and $hours -gt 0 -and $hours -le 8760) { $autoStopHours = $hours }
        else { Write-Host '  Please type a number of hours above 0 (for example 2 or 1.5), or just press Enter.' -ForegroundColor Yellow }
    }

    # Remember the interval for next time.
    Write-JsonFile -Path $SETTINGS_PATH -Data ([ordered]@{ lastIntervalSeconds = $interval })

    # --- Launch the rotator hidden -------------------------------------------
    # A separate, hidden PowerShell process: it has no link to this window, so
    # Ctrl+C or closing this window can't stop it. "-ExecutionPolicy Bypass"
    # applies to that one process only; your system setting is never changed.
    $rotatorPath = Join-Path $PSScriptRoot 'rotator.ps1'
    $powershell  = Join-Path $PSHOME 'powershell.exe'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -IntervalSeconds {1}' -f $rotatorPath, $interval
    if ($autoStopHours -gt 0) {
        $argLine += ' -AutoStopHours ' + $autoStopHours.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    $proc = Start-Process -FilePath $powershell -ArgumentList $argLine -WindowStyle Hidden -PassThru

    # Wait until the rotator has written its lock file, then a few seconds more:
    # setup problems make it quit almost immediately, and we want to report that.
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        $lockPid = Get-Content -Path $PID_PATH -Raw -ErrorAction SilentlyContinue
        if ($lockPid -and $lockPid.Trim() -eq "$($proc.Id)") { break }
        Start-Sleep -Milliseconds 300
    }
    for ($i = 0; $i -lt 10 -and -not $proc.HasExited; $i++) { Start-Sleep -Milliseconds 300 }
    if ($proc.HasExited) {
        Write-Host ''
        Write-Host '  The rotator stopped right after starting. Last lines of rotator.log:' -ForegroundColor Red
        if (Test-Path $LOG_PATH) { Get-Content -Path $LOG_PATH -Tail 5 | ForEach-Object { Write-Host "    $_" } }
        exit 1
    }

    Write-Host ''
    Write-Host "  Running in background, changing IP every $interval seconds. Use stop.bat to stop." -ForegroundColor Green
    if ($autoStopHours -gt 0) {
        Write-Host ("  It will stop by itself after {0} h (at {1})." -f $autoStopHours, (Get-Date).AddHours($autoStopHours).ToString('HH:mm, ddd d MMM'))
    }
    Write-Host '  The first switch is happening now and takes about 10-30 seconds.'
    Write-Host '  status.bat shows what it is doing. You can close this window.'
    exit 0
}
catch {
    Show-FriendlyError $_
    exit 1
}
