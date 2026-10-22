# =============================================================================
#  common.ps1 - helper functions shared by all IP Rotator scripts.
#  Every other script loads this file first. You don't run it directly.
# =============================================================================

# Load the settings (paths, minimum interval, timeouts).
. (Join-Path $PSScriptRoot 'config.ps1')

# api.ipify.org needs TLS 1.2, which Windows PowerShell 5.1 doesn't always
# switch on by itself.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12


# -----------------------------------------------------------------------------
#  Log, settings and state files
# -----------------------------------------------------------------------------

function Write-Log {
    # Adds one line to rotator.log, e.g.
    #   2026-01-31 14:05:00 | ROTATE | old IP ... -> new IP ... | server ...
    param([string]$Message, [string]$Level = 'INFO')
    try {
        # Keep the log small: when it gets too big, keep one old copy and start fresh.
        if ((Test-Path $LOG_PATH) -and (Get-Item $LOG_PATH).Length -gt $LOG_MAX_BYTES) {
            Move-Item -Path $LOG_PATH -Destination "$LOG_PATH.1" -Force
        }
        $line = '{0} | {1,-6} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path $LOG_PATH -Value $line -Encoding UTF8
    } catch {
        # A logging hiccup must never stop the rotator.
    }
}

function Read-JsonFile {
    # Returns the contents of a small JSON file, or $null if it's missing or broken.
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonFile {
    # Saves data as JSON. Writes a temporary file first and then swaps it in,
    # so status.bat never reads a half-written file.
    param([string]$Path, $Data)
    $tmp = "$Path.tmp"
    $Data | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    for ($try = 1; $try -le 5; $try++) {
        try { Move-Item -Path $tmp -Destination $Path -Force -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 200 }   # someone was reading it; try again
    }
}

function Get-RotatorProcess {
    # Returns the running rotator process, or $null if it isn't running.
    # Also deletes a leftover lock file from a rotator that is no longer running.
    if (-not (Test-Path $PID_PATH)) { return $null }
    $raw = Get-Content -Path $PID_PATH -Raw -ErrorAction SilentlyContinue
    $procId = 0
    if ($raw -and [int]::TryParse($raw.Trim(), [ref]$procId) -and $procId -gt 0) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue
        # Windows reuses process IDs, so check it really is our rotator.
        if ($proc -and $proc.CommandLine -like '*rotator.ps1*') { return $proc }
    }
    Remove-Item -Path $PID_PATH -Force -ErrorAction SilentlyContinue
    return $null
}

function Format-Duration {
    # 7200 -> "2 h 0 m",  150 -> "2 m 30 s",  45 -> "45 s"
    param([double]$Seconds)
    $t = [TimeSpan]::FromSeconds([math]::Max(0, [math]::Round($Seconds)))
    if ($t.TotalHours -ge 1) { return '{0} h {1} m' -f [math]::Floor($t.TotalHours), $t.Minutes }
    if ($t.TotalMinutes -ge 1) { return '{0} m {1} s' -f $t.Minutes, $t.Seconds }
    return '{0} s' -f $t.Seconds
}

function ConvertTo-DateTime {
    # Turns a time saved in state.json back into a date (or $null).
    param($Value)
    if ($Value -is [datetime]) { return $Value }
    if (-not $Value) { return $null }
    try { return [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    catch { return $null }
}


# -----------------------------------------------------------------------------
#  OpenVPN GUI
# -----------------------------------------------------------------------------

function Find-OpenVpnGui {
    # Returns the full path of openvpn-gui.exe, or $null if it isn't installed.
    if ($OPENVPN_GUI_PATH -and (Test-Path $OPENVPN_GUI_PATH)) { return $OPENVPN_GUI_PATH }
    $candidates = @()
    # The OpenVPN installer records its install folder in the registry.
    foreach ($key in 'HKLM:\SOFTWARE\OpenVPN', 'HKLM:\SOFTWARE\WOW6432Node\OpenVPN') {
        $dir = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'(default)'
        if ($dir) { $candidates += Join-Path $dir 'bin\openvpn-gui.exe' }
    }
    # Otherwise try the default install folders.
    $candidates += Join-Path $env:ProgramFiles 'OpenVPN\bin\openvpn-gui.exe'
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'OpenVPN\bin\openvpn-gui.exe' }
    foreach ($path in $candidates) { if (Test-Path $path) { return $path } }
    return $null
}

function Get-OpenVpnGuiFolders {
    # OpenVPN GUI reads configs from, and writes logs to, folders in your user
    # profile. They can be changed in its Settings, so check the registry first.
    $reg = Get-ItemProperty -Path 'HKCU:\Software\OpenVPN-GUI' -ErrorAction SilentlyContinue
    $configDir = Join-Path $env:USERPROFILE 'OpenVPN\config'
    $logDir    = Join-Path $env:USERPROFILE 'OpenVPN\log'
    if ($reg -and $reg.config_dir) { $configDir = [Environment]::ExpandEnvironmentVariables($reg.config_dir) }
    if ($reg -and $reg.log_dir)    { $logDir    = [Environment]::ExpandEnvironmentVariables($reg.log_dir) }
    return [pscustomobject]@{ ConfigDir = $configDir; LogDir = $logDir }
}

function Get-SourceConfigs {
    # Looks at the .ovpn files in configs\ and splits them into UDP (used) and
    # TCP (skipped, because UDP is faster).
    $udp = @(); $tcp = @()
    foreach ($file in @(Get-ChildItem -Path $CONFIGS_DIR -Filter '*.ovpn' -File -ErrorAction SilentlyContinue)) {
        $text = Get-Content -Path $file.FullName -Raw
        if ($text -match '(?im)^\s*proto\s+tcp') { $tcp += $file } else { $udp += $file }
    }
    return [pscustomobject]@{ Udp = $udp; Tcp = $tcp }
}

function Sync-VpnConfigs {
    # OpenVPN GUI only sees configs inside its own config folder, so this copies
    # your .ovpn files into an "IPRotator" subfolder there. In each copy, Proton's
    # "auth-user-pass" line (which makes OpenVPN GUI pop up a login box) is
    # replaced by one that points at your saved credentials file.
    # Your original files in configs\ are never changed.
    # Returns the names OpenVPN GUI knows the copies by.
    param([System.IO.FileInfo[]]$Files)

    $dest = Join-Path (Get-OpenVpnGuiFolders).ConfigDir 'IPRotator'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    # In OpenVPN config files, backslashes inside quotes must be doubled.
    $authLine = 'auth-user-pass "' + $AUTH_FILE_PATH.Replace('\', '\\') + '"'
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false

    $names = @()
    $keep = @{}
    foreach ($file in $Files) {
        $name = $CONFIG_NAME_PREFIX + $file.BaseName
        $lines = (Get-Content -Path $file.FullName -Raw) -split "`r?`n" |
            Where-Object { $_ -notmatch '^\s*auth-user-pass\b' }
        $newText = (@($lines) + $authLine) -join "`r`n"
        $target = Join-Path $dest "$name.ovpn"
        # Only rewrite the copy if something changed.
        $oldText = if (Test-Path $target) { [IO.File]::ReadAllText($target) } else { $null }
        if ($oldText -ne $newText) { [IO.File]::WriteAllText($target, $newText, $utf8NoBom) }
        $keep["$name.ovpn"] = $true
        $names += $name
    }
    # Remove copies of configs you have since deleted from configs\.
    Get-ChildItem -Path $dest -Filter "$CONFIG_NAME_PREFIX*.ovpn" -File |
        Where-Object { -not $keep.ContainsKey($_.Name) } |
        Remove-Item -Force
    return $names
}

function Get-OpenVpnGuiProcess {
    # Returns OpenVPN GUI if it's running in YOUR Windows session, else $null.
    $mySession = (Get-Process -Id $PID).SessionId
    return Get-Process -Name 'openvpn-gui' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $mySession } | Select-Object -First 1
}

function Invoke-OpenVpnGui {
    # Sends a command to the OpenVPN GUI that's already running in your tray,
    # e.g. "--command connect <name>". OpenVPN GUI's own background service
    # does the parts that need admin rights, so no admin prompt appears.
    param([string]$GuiPath, [string[]]$Arguments)
    # Start-Process doesn't add quotes itself, so quote each argument.
    $argLine = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $proc = Start-Process -FilePath $GuiPath -ArgumentList $argLine -WindowStyle Hidden -PassThru
    # The helper exits as soon as it has passed the command on.
    [void]$proc.WaitForExit(10000)
}

function Start-OpenVpnGui {
    # Makes sure OpenVPN GUI is running (it has to be, for "--command" to work).
    param([string]$GuiPath)
    if (Get-OpenVpnGuiProcess) {
        # Already running: hide its connection window and make it notice the copied configs.
        Invoke-OpenVpnGui -GuiPath $GuiPath -Arguments '--command', 'silent_connection', '1'
        Invoke-OpenVpnGui -GuiPath $GuiPath -Arguments '--command', 'rescan'
        Start-Sleep -Seconds 1
        return
    }
    # Start it quietly in the tray: no connection window, no pop-up on every switch.
    Start-Process -FilePath $GuiPath -ArgumentList '--silent_connection 1 --show_balloon 0'
    for ($i = 0; $i -lt 20 -and -not (Get-OpenVpnGuiProcess); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Get-OpenVpnGuiProcess)) { throw 'OpenVPN GUI did not start.' }
    Start-Sleep -Seconds 3   # give it a moment to load its list of configs
}

function Read-SharedText {
    # Reads a file that OpenVPN may still be writing to. Returns '' if it can't.
    param([string]$Path)
    try {
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        try { return (New-Object IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
    } catch { return '' }
}

function Connect-Vpn {
    # Asks OpenVPN GUI to connect one config, then watches OpenVPN's log file
    # to see how it went. Returns 'ok', 'auth-failed', 'error' or 'timeout'.
    param([string]$GuiPath, [string]$Name)
    $log = Join-Path (Get-OpenVpnGuiFolders).LogDir "$Name.log"
    # Delete the old log so we only look at this attempt.
    Remove-Item -Path $log -Force -ErrorAction SilentlyContinue
    $started = Get-Date
    Invoke-OpenVpnGui -GuiPath $GuiPath -Arguments '--command', 'connect', $Name

    $deadline = $started.AddSeconds($CONNECT_TIMEOUT_SECONDS)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        if (-not (Test-Path $log) -or (Get-Item $log).LastWriteTime -lt $started.AddSeconds(-2)) { continue }
        $text = Read-SharedText $log
        if ($text -match 'Initialization Sequence Completed') { return 'ok' }
        if ($text -match 'AUTH_FAILED') { return 'auth-failed' }
        if ($text -match 'Exiting due to fatal error') { return 'error' }
    }
    return 'timeout'
}

function Get-OpenVpnProcesses {
    # The OpenVPN processes that belong to IP Rotator's configs (not your own ones).
    $pattern = [regex]::Escape($CONFIG_NAME_PREFIX) + '[^"\\]+?\.ovpn'
    return @(Get-CimInstance Win32_Process -Filter "Name = 'openvpn.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match $pattern })
}

function Get-ConnectedRotatorConfigs {
    # Names of IP Rotator configs that currently have OpenVPN running.
    $pattern = '(' + [regex]::Escape($CONFIG_NAME_PREFIX) + '[^"\\]+?)\.ovpn'
    foreach ($proc in Get-OpenVpnProcesses) {
        if ($proc.CommandLine -match $pattern) { $Matches[1] }
    }
}

function Disconnect-Vpn {
    # Asks OpenVPN GUI to disconnect one config and waits until OpenVPN has exited.
    param([string]$GuiPath, [string]$Name)
    Invoke-OpenVpnGui -GuiPath $GuiPath -Arguments '--command', 'disconnect', $Name
    $deadline = (Get-Date).AddSeconds($DISCONNECT_TIMEOUT_SECONDS)
    while ((Get-Date) -lt $deadline -and (@(Get-ConnectedRotatorConfigs) -contains $Name)) {
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 2   # let Windows restore your normal routes and DNS
}

function Disconnect-AllRotatorVpns {
    # Disconnects every IP Rotator connection. Connections you made yourself
    # with other configs are left alone. If OpenVPN GUI doesn't respond, the
    # OpenVPN processes are ended directly as a last resort.
    param([string]$GuiPath)
    if ($GuiPath -and (Get-OpenVpnGuiProcess)) {
        foreach ($name in @(Get-ConnectedRotatorConfigs | Select-Object -Unique)) {
            Disconnect-Vpn -GuiPath $GuiPath -Name $name
        }
    }
    $leftovers = Get-OpenVpnProcesses
    if ($leftovers.Count -gt 0) {
        $leftovers | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    }
}


# -----------------------------------------------------------------------------
#  Network
# -----------------------------------------------------------------------------

function Get-PublicIp {
    # Asks api.ipify.org for your public IP. Returns $null if it can't be reached.
    param([int]$Tries = 3)
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            $ip = "$(Invoke-RestMethod -Uri $IP_CHECK_URL -TimeoutSec 10 -UseBasicParsing)".Trim()
            if ($ip -match '^[0-9a-fA-F:.]+$') { return $ip }
        } catch { }
        if ($i -lt $Tries) { Start-Sleep -Seconds 2 }
    }
    return $null
}


# -----------------------------------------------------------------------------
#  Setup checks and console helpers
# -----------------------------------------------------------------------------

function Get-SetupProblems {
    # Returns a plain-English list of anything that stops the rotator from working.
    $problems = @()
    if (-not (Find-OpenVpnGui)) {
        $problems += 'OpenVPN GUI is not installed. Get it from https://openvpn.net/community-downloads/ and then run setup.bat.'
    }
    if (-not (Test-Path $AUTH_FILE_PATH)) {
        $problems += 'Your Proton OpenVPN username/password has not been saved yet. Run setup.bat.'
    }
    $udpCount = @((Get-SourceConfigs).Udp).Count
    if ($udpCount -lt 2) {
        $problems += "Put at least 2 Proton free-server UDP .ovpn files in the configs folder (found $udpCount): $CONFIGS_DIR"
    }
    return $problems
}

function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $Text.Length)) -ForegroundColor Cyan
    Write-Host ''
}

function Read-Answer {
    # Reads one line you type, without surrounding spaces. If input has ended
    # (only possible when input is piped in), stop instead of asking forever.
    param([string]$Prompt)
    $line = Read-Host $Prompt
    if ($null -eq $line) { throw 'No more input, so nothing was changed.' }
    return $line.Trim()
}

function Read-YesNo {
    # Asks a Y/N question until it gets Y or N. Returns $true for Y.
    param([string]$Question)
    while ($true) {
        $answer = (Read-Answer $Question).ToUpper()
        if ($answer -in 'Y', 'YES') { return $true }
        if ($answer -in 'N', 'NO')  { return $false }
        Write-Host '  Please type Y or N.' -ForegroundColor Yellow
    }
}

function Show-FriendlyError {
    # Shows an error without a scary PowerShell stack trace.
    param($ErrorRecord)
    Write-Host ''
    Write-Host "  Sorry, something went wrong: $($ErrorRecord.Exception.Message)" -ForegroundColor Red
    Write-Host '  If this keeps happening, see "Troubleshooting" in README.md.' -ForegroundColor Red
}
