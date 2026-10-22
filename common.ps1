# =============================================================================
#  common.ps1 - helper functions shared by all IP Rotator scripts.
#  Every other script loads this file first. You don't run it directly.
# =============================================================================

# Load the settings (paths, minimum interval, ports).
. (Join-Path $PSScriptRoot 'config.ps1')

# The Tor Project's servers and api.ipify.org need TLS 1.2, which Windows
# PowerShell 5.1 doesn't always switch on by itself.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Where Windows keeps your proxy settings (your user account only, no admin needed).
$INTERNET_SETTINGS_KEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$PROXY_VALUE_NAMES     = @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL')
$RUNONCE_KEY           = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$RUNONCE_NAME          = 'IPRotator-restore-proxy'


# -----------------------------------------------------------------------------
#  Log, settings and state files
# -----------------------------------------------------------------------------

function Write-Log {
    # Adds one line to rotator.log, e.g.
    #   2026-01-31 14:05:00 | ROTATE | old IP ... -> new IP ... | Germany
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
#  Tor: download, start, stop, and ask for a new IP
# -----------------------------------------------------------------------------

function Get-TorExe {
    # Full path of the downloaded tor.exe, or $null if it isn't downloaded yet.
    if (-not (Test-Path $TOR_DIR)) { return $null }
    $exe = Get-ChildItem -Path $TOR_DIR -Recurse -File -Filter 'tor.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return $exe.FullName }
    return $null
}

function Install-Tor {
    # Downloads the official "Tor Expert Bundle" (just the tor program, no
    # browser) into the tor folder and checks it against the SHA-256 checksum
    # the Tor Project publishes. Nothing is installed in Windows.
    # Returns the Tor version.
    $ProgressPreference = 'SilentlyContinue'   # PowerShell's progress bar makes downloads very slow

    $version = "$((Invoke-RestMethod -Uri $TOR_VERSION_URL -UseBasicParsing -TimeoutSec 30).version)"
    if ($version -notmatch '^[0-9.]+$') { throw "Couldn't find out the latest Tor version. Check your internet connection." }
    $file = "tor-expert-bundle-windows-x86_64-$version.tar.gz"

    $downloadDir = Join-Path $TOR_DIR 'download'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    $archive = Join-Path $downloadDir $file
    $sums    = Join-Path $downloadDir 'sha256sums.txt'

    $downloaded = $false
    foreach ($base in $TOR_DOWNLOAD_BASES) {
        try {
            Invoke-WebRequest -Uri "$base/$version/$file" -OutFile $archive -UseBasicParsing -TimeoutSec 600
            Invoke-WebRequest -Uri "$base/$version/sha256sums-signed-build.txt" -OutFile $sums -UseBasicParsing -TimeoutSec 60
            $downloaded = $true
            break
        } catch { }   # try the next official server
    }
    if (-not $downloaded) { throw "Couldn't download Tor from torproject.org. Check your internet connection and run start.bat again." }

    # Make sure the file is exactly what the Tor Project published.
    $line = Select-String -Path $sums -Pattern ([regex]::Escape($file)) | Select-Object -First 1
    $expected = if ($line) { ($line.Line -split '\s+')[0] } else { '' }
    $actual = (Get-FileHash -Path $archive -Algorithm SHA256).Hash
    if (-not $expected -or $actual -ne $expected) {
        Remove-Item -Path $downloadDir -Recurse -Force
        throw "The Tor download failed its checksum check, so it was deleted. Please run start.bat again."
    }

    # Unpack it with the tar tool built into Windows 10 and 11.
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -xzf $archive -C $TOR_DIR
    if ($LASTEXITCODE -ne 0) { throw "Couldn't unpack the Tor download." }
    Remove-Item -Path $downloadDir -Recurse -Force
    if (-not (Get-TorExe)) { throw "Tor was downloaded, but tor.exe wasn't found inside it." }
    return $version
}

function Get-TorProcesses {
    # Tor processes started from this project's tor folder (Tor Browser is left alone).
    $folder = (Resolve-Path -Path $TOR_DIR -ErrorAction SilentlyContinue).Path
    if (-not $folder) { return @() }
    return @(Get-Process -Name 'tor' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase) })
}

function Stop-Tor {
    # Ends this project's Tor.
    Get-TorProcesses | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}

function Start-Tor {
    # Starts tor.exe hidden, with its own settings file (torrc).
    # "__OwningControllerProcess" makes Tor quit by itself if the rotator ends.
    param([int]$OwnerPid)
    $exe = Get-TorExe
    New-Item -ItemType Directory -Path $TOR_DATA_DIR -Force | Out-Null

    # In torrc, a value with a path goes in quotes with its backslashes doubled.
    # The quotes must wrap the WHOLE value, or Tor keeps them as part of the name.
    function Format-TorPath([string]$Path) { return '"' + $Path.Replace('\', '\\') + '"' }

    $torLog = Join-Path $TOR_DATA_DIR 'tor.log'
    $lines = @(
        "DataDirectory $(Format-TorPath $TOR_DATA_DIR)",
        "HTTPTunnelPort 127.0.0.1:$TOR_HTTP_PORT",
        "SocksPort 127.0.0.1:$TOR_SOCKS_PORT",
        "ControlPort 127.0.0.1:$TOR_CONTROL_PORT",
        'CookieAuthentication 1',
        "Log $(Format-TorPath "notice file $torLog")",
        "__OwningControllerProcess $OwnerPid"
    )
    # Country look-up files that come with Tor (used to show the exit country).
    foreach ($name in 'geoip', 'geoip6') {
        $file = Get-ChildItem -Path $TOR_DIR -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($file) {
            $option = if ($name -eq 'geoip') { 'GeoIPFile' } else { 'GeoIPv6File' }
            $lines += "$option $(Format-TorPath $file.FullName)"
        }
    }
    $torrc = Join-Path $TOR_DATA_DIR 'torrc'
    [IO.File]::WriteAllText($torrc, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    Remove-Item -Path $torLog -Force -ErrorAction SilentlyContinue

    return Start-Process -FilePath $exe -ArgumentList ('-f "{0}"' -f $torrc) `
        -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden -PassThru
}

function Read-TorReply {
    # Reads one complete reply from Tor's control port.
    param([IO.StreamReader]$Reader)
    $lines = @()
    while ($true) {
        $line = $Reader.ReadLine()
        if ($null -eq $line) { throw 'Tor closed the control connection.' }
        $lines += $line
        if ($line -match '^\d{3}\+') {
            # A multi-line block; it ends with a line holding just "."
            while ($true) {
                $data = $Reader.ReadLine()
                if ($null -eq $data -or $data -eq '.') { break }
                $lines += $data
            }
        }
        elseif ($line -match '^\d{3} ') { return , $lines }
    }
}

function Invoke-TorControl {
    # Talks to Tor's control port: logs in with the cookie file Tor wrote,
    # sends each command and returns all reply lines.
    param([string[]]$Commands)
    $cookieBytes = [IO.File]::ReadAllBytes((Join-Path $TOR_DATA_DIR 'control_auth_cookie'))
    $cookie = ($cookieBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $TOR_CONTROL_PORT)
        $client.ReceiveTimeout = 15000
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
        $writer = New-Object IO.StreamWriter($stream, [Text.Encoding]::ASCII)
        $writer.NewLine = "`r`n"
        $writer.AutoFlush = $true

        $writer.WriteLine("AUTHENTICATE $cookie")
        $auth = Read-TorReply $reader
        if ($auth[-1] -notmatch '^250 ') { throw "Tor refused the control login: $($auth[-1])" }

        $all = @()
        foreach ($command in $Commands) {
            $writer.WriteLine($command)
            $all += Read-TorReply $reader
        }
        $writer.WriteLine('QUIT')
        return $all
    }
    finally { $client.Close() }
}

function Wait-TorReady {
    # Waits until Tor has finished connecting to the Tor network.
    # Returns $true when ready, $false if it took too long.
    param([System.Diagnostics.Process]$TorProcess, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($TorProcess.HasExited) { throw "Tor stopped while starting. Details: $(Join-Path $TOR_DATA_DIR 'tor.log')" }
        try {
            $reply = Invoke-TorControl 'GETINFO status/bootstrap-phase'
            if ((($reply -join ' ') -match 'PROGRESS=(\d+)') -and [int]$Matches[1] -ge 100) { return $true }
        } catch { }   # Tor's control port isn't open yet
        Start-Sleep -Seconds 1
    }
    return $false
}

function Request-NewTorIdentity {
    # Asks Tor for brand-new routes (a new exit = a new public IP), then closes
    # the old routes so browsers can't keep using the old IP over a connection
    # that is still open. Web traffic uses routes labelled GENERAL or, in newer
    # Tor versions, CONFLUX_LINKED / CONFLUX_UNLINKED.
    $reply = Invoke-TorControl 'SIGNAL NEWNYM', 'GETINFO circuit-status'
    $ids = @($reply | Where-Object { $_ -match '^\d+ BUILT ' -and $_ -match 'PURPOSE=(GENERAL|CONFLUX_LINKED|CONFLUX_UNLINKED)\b' } |
        ForEach-Object { ($_ -split ' ')[0] })
    if ($ids.Count -gt 0) { [void](Invoke-TorControl ($ids | ForEach-Object { "CLOSECIRCUIT $_" })) }
}

function Get-TorCountry {
    # The country an IP belongs to, using the look-up files that come with Tor.
    param([string]$Ip)
    try {
        $reply = Invoke-TorControl "GETINFO ip-to-country/$Ip"
        if (($reply -join "`n") -match 'ip-to-country/[^=]+=([a-zA-Z]{2})') {
            $code = $Matches[1]
            try { return (New-Object Globalization.RegionInfo $code).EnglishName } catch { return $code.ToUpper() }
        }
    } catch { }
    return 'unknown country'
}


# -----------------------------------------------------------------------------
#  Windows proxy settings
# -----------------------------------------------------------------------------

function Update-WindowsProxy {
    # Tells Windows and running apps (like your browser) that the proxy changed.
    if (-not ('IPRotator.WinInet' -as [type])) {
        Add-Type -Namespace IPRotator -Name WinInet -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
    }
    [void][IPRotator.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)   # settings changed
    [void][IPRotator.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)   # refresh
}

function Register-ProxyCleanup {
    # Safety net: if the PC restarts or you sign out while the rotator is running,
    # put your normal proxy settings back the next time you sign in. Windows runs
    # a "RunOnce" entry one time and then deletes it. It does NOT start the rotator.
    $command = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Quiet' -f `
        (Join-Path $PSHOME 'powershell.exe'), (Join-Path $ROOT_DIR 'stop.ps1')
    if (-not (Test-Path $RUNONCE_KEY)) { New-Item -Path $RUNONCE_KEY | Out-Null }
    Set-ItemProperty -Path $RUNONCE_KEY -Name $RUNONCE_NAME -Value $command
}

function Unregister-ProxyCleanup {
    Remove-ItemProperty -Path $RUNONCE_KEY -Name $RUNONCE_NAME -ErrorAction SilentlyContinue
}

function Set-TorProxy {
    # Saves your current proxy settings (only once), then points Windows at Tor:
    # HTTPS sites go through Tor's HTTP tunnel, everything else through Tor's SOCKS port.
    if (-not (Test-Path $PROXY_BACKUP_PATH)) {
        $current = Get-ItemProperty -Path $INTERNET_SETTINGS_KEY
        $backup = [ordered]@{}
        foreach ($name in $PROXY_VALUE_NAMES) { $backup[$name] = $current.$name }
        Write-JsonFile -Path $PROXY_BACKUP_PATH -Data $backup
    }
    Register-ProxyCleanup
    Set-ItemProperty -Path $INTERNET_SETTINGS_KEY -Name 'ProxyEnable'   -Value 1 -Type DWord
    Set-ItemProperty -Path $INTERNET_SETTINGS_KEY -Name 'ProxyServer'   -Value "https=127.0.0.1:$TOR_HTTP_PORT;socks=127.0.0.1:$TOR_SOCKS_PORT" -Type String
    Set-ItemProperty -Path $INTERNET_SETTINGS_KEY -Name 'ProxyOverride' -Value $PROXY_BYPASS -Type String
    # A proxy "setup script" would take priority over the settings above.
    Remove-ItemProperty -Path $INTERNET_SETTINGS_KEY -Name 'AutoConfigURL' -ErrorAction SilentlyContinue
    Update-WindowsProxy
}

function Restore-ProxySettings {
    # Puts your original proxy settings back. Safe to call at any time.
    # Returns $true if something was restored.
    $backup = Read-JsonFile $PROXY_BACKUP_PATH
    if (-not $backup) { Unregister-ProxyCleanup; return $false }
    foreach ($name in $PROXY_VALUE_NAMES) {
        $value = $backup.$name
        if ($null -eq $value) {
            Remove-ItemProperty -Path $INTERNET_SETTINGS_KEY -Name $name -ErrorAction SilentlyContinue
        } elseif ($name -eq 'ProxyEnable') {
            Set-ItemProperty -Path $INTERNET_SETTINGS_KEY -Name $name -Value ([int]$value) -Type DWord
        } else {
            Set-ItemProperty -Path $INTERNET_SETTINGS_KEY -Name $name -Value ([string]$value) -Type String
        }
    }
    Remove-Item -Path $PROXY_BACKUP_PATH -Force
    Update-WindowsProxy
    Unregister-ProxyCleanup
    return $true
}


# -----------------------------------------------------------------------------
#  Network
# -----------------------------------------------------------------------------

function Get-PublicIp {
    # Asks api.ipify.org for your public IP. Returns $null if it can't be reached.
    #   -Via System = through Windows' proxy settings (what your browser sees)
    #   -Via Tor    = straight through Tor
    #   -Via Direct = no proxy at all (your normal IP)
    param([ValidateSet('System', 'Tor', 'Direct')][string]$Via = 'System', [int]$Tries = 3)
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            $request = [Net.HttpWebRequest]::Create($IP_CHECK_URL)
            $request.Timeout = 20000
            $request.KeepAlive = $false   # a fresh connection, so a new IP shows up right away
            if ($Via -eq 'Tor')        { $request.Proxy = New-Object Net.WebProxy("http://127.0.0.1:$TOR_HTTP_PORT") }
            elseif ($Via -eq 'Direct') { $request.Proxy = $null }
            else                       { $request.Proxy = [Net.WebRequest]::GetSystemWebProxy() }
            $response = $request.GetResponse()
            try { $ip = (New-Object IO.StreamReader($response.GetResponseStream())).ReadToEnd().Trim() }
            finally { $response.Close() }
            if ($ip -match '^[0-9a-fA-F:.]+$') { return $ip }
        } catch { }
        if ($i -lt $Tries) { Start-Sleep -Seconds 2 }
    }
    return $null
}


# -----------------------------------------------------------------------------
#  Console helpers
# -----------------------------------------------------------------------------

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
