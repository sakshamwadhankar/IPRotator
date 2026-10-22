# =============================================================================
#  config.ps1 - IP Rotator settings (everything EXCEPT the rotation interval)
# =============================================================================
#  The interval is never stored here: start.bat asks you for it every time
#  (or you pass it on the command line, e.g.  start.bat 300).
#  All paths are relative to the folder this file is in, so the project works
#  wherever you clone or unzip it. The other scripts load this file.
# =============================================================================

# The folder this file (and every other IP Rotator script) lives in.
$ROOT_DIR = $PSScriptRoot

# Smallest interval start.bat accepts, in seconds. Asking Tor for a new route
# too often puts extra load on the volunteer-run Tor network.
$MIN_INTERVAL_SECONDS = 60

# Log of every IP change (timestamp, old IP, new IP, country).
$LOG_PATH = Join-Path $ROOT_DIR 'rotator.log'

# When the log reaches this size it is renamed to rotator.log.1 and a new one starts.
$LOG_MAX_BYTES = 1MB

# Remembers the last interval you used, so start.bat can offer it as the default.
$SETTINGS_PATH = Join-Path $ROOT_DIR 'settings.json'

# Lock file holding the process ID of the running rotator (prevents two copies).
$PID_PATH = Join-Path $ROOT_DIR 'rotator.pid'

# Live status written by the rotator and read by status.bat / stop.bat.
$STATE_PATH = Join-Path $ROOT_DIR 'state.json'

# Your original Windows proxy settings, saved while the rotator runs so that
# stop.bat can put them back exactly as they were.
$PROXY_BACKUP_PATH = Join-Path $ROOT_DIR 'proxy-backup.json'

# Where start.bat puts Tor the first time it runs (downloaded automatically,
# nothing is installed), and where Tor keeps its working files.
$TOR_DIR      = Join-Path $ROOT_DIR 'tor'
$TOR_DATA_DIR = Join-Path $ROOT_DIR 'tor-data'

# Official Tor download locations. The newest version number is read from the
# first address; the file is then downloaded from the Tor Project's servers and
# checked against their published SHA-256 checksum.
$TOR_VERSION_URL    = 'https://aus1.torproject.org/torbrowser/update_3/release/downloads.json'
$TOR_DOWNLOAD_BASES = @(
    'https://dist.torproject.org/torbrowser',
    'https://archive.torproject.org/tor-package-archive/torbrowser'
)

# Local ports Tor listens on (only reachable from this PC). They are different
# from Tor Browser's ports, so both can run at the same time.
$TOR_HTTP_PORT    = 19080   # used as the Windows proxy (HTTPS sites)
$TOR_SOCKS_PORT   = 19050   # used as the Windows proxy (everything else)
$TOR_CONTROL_PORT = 19051   # used by the rotator to ask Tor for a new IP

# How long to wait for Tor to connect when it starts.
$TOR_START_TIMEOUT_SECONDS = 120

# If Tor hands out the same IP again, ask for a new one up to this many times.
$NEW_IP_TRIES = 3

# Addresses that never go through Tor: your own PC and your home network.
$PROXY_BYPASS = '<local>;localhost;127.*;10.*;172.16.*;192.168.*'

# Web service that tells us your public IP address.
$IP_CHECK_URL = 'https://api.ipify.org'
