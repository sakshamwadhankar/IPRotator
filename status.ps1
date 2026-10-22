<#
=============================================================================
 status.ps1 - shows whether the rotator is running, the interval in use, your
 current public IP and its country, the time until the next change and the
 last 10 log lines. Run it by double-clicking status.bat.
=============================================================================
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Show-Row {
    # Prints one "Label : value" line.
    param([string]$Label, [string]$Value, [string]$Color = 'Gray')
    Write-Host ('  {0,-19}: ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

try {
    Write-Title 'IP Rotator - status'
    $proc  = Get-RotatorProcess
    $state = Read-JsonFile $STATE_PATH

    if ($proc) {
        Show-Row 'Running' "YES (process $($proc.ProcessId))" 'Green'
    } else {
        Show-Row 'Running' 'NO (start it with start.bat)' 'Yellow'
        if (Test-Path $PROXY_BACKUP_PATH) {
            Show-Row 'Note' 'Windows is still set to use Tor. Run stop.bat to fix your internet.' 'Red'
        }
    }

    if ($proc -and $state) {
        Show-Row 'Interval' ('{0} seconds ({1})' -f $state.intervalSeconds, (Format-Duration $state.intervalSeconds))
        $startedAt = ConvertTo-DateTime $state.startedAt
        if ($startedAt) { Show-Row 'Started' $startedAt.ToString('yyyy-MM-dd HH:mm:ss') }

        $stopAt = ConvertTo-DateTime $state.stopAt
        if ($stopAt) {
            Show-Row 'Auto-stop' ('at {0} (in {1})' -f $stopAt.ToString('yyyy-MM-dd HH:mm'), (Format-Duration ($stopAt - (Get-Date)).TotalSeconds))
        } else {
            Show-Row 'Auto-stop' 'off (runs until you use stop.bat)'
        }

        if ($state.country) { Show-Row 'Tor exit country' $state.country 'Green' }

        $next = ConvertTo-DateTime $state.nextRotation
        if ($state.status -eq 'connecting') {
            Show-Row 'Next change' 'connecting to Tor...' 'Cyan'
        } elseif ($state.status -eq 'changing') {
            Show-Row 'Next change' 'changing right now...' 'Cyan'
        } elseif ($next) {
            Show-Row 'Next change' ('in {0} (at {1})' -f (Format-Duration ($next - (Get-Date)).TotalSeconds), $next.ToString('HH:mm:ss'))
        }
        if ($state.message) { Show-Row 'Note' $state.message 'Yellow' }
    }

    # What websites see right now (through Windows' proxy settings, like your browser).
    $ip = Get-PublicIp -Via System
    if (-not $ip) {
        Show-Row 'Current public IP' "can't reach the internet right now" 'Red'
    } else {
        $label = $ip
        if ($state -and $state.homeIp -and $ip -eq $state.homeIp) { $label += '  (your normal IP)' }
        elseif ($proc) { $label += '  (via Tor)' }
        Show-Row 'Current public IP' $label 'Green'
    }

    # Last 10 lines of the log.
    Write-Host ''
    Write-Host '  Last 10 log lines (rotator.log):' -ForegroundColor Cyan
    if (Test-Path $LOG_PATH) {
        Get-Content -Path $LOG_PATH -Tail 10 | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host '    (no log yet)'
    }
    exit 0
}
catch {
    Show-FriendlyError $_
    exit 1
}
