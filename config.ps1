# =============================================================================
#  config.ps1 - IP Rotator settings (everything EXCEPT the rotation interval)
# =============================================================================
#  The interval is never stored here: start.bat asks you for it every time.
#  All paths are relative to the folder this file is in, so the project works
#  wherever you unzip it. The other scripts load this file automatically.
# =============================================================================

# The folder this file (and every other IP Rotator script) lives in.
$ROOT_DIR = $PSScriptRoot

# Smallest interval start.bat accepts, in seconds. A VPN reconnect takes about
# 10-30 seconds, and reconnecting very often can get a free account throttled.
$MIN_INTERVAL_SECONDS = 60

# Where you put your Proton VPN free-server UDP .ovpn files.
$CONFIGS_DIR = Join-Path $ROOT_DIR 'configs'

# Log of every IP change (timestamp, old IP, new IP, server).
$LOG_PATH = Join-Path $ROOT_DIR 'rotator.log'

# When the log reaches this size it is renamed to rotator.log.1 and a new one starts.
$LOG_MAX_BYTES = 1MB

# Remembers the last interval you used, so start.bat can offer it as the default.
$SETTINGS_PATH = Join-Path $ROOT_DIR 'settings.json'

# Lock file holding the process ID of the running rotator (prevents two copies).
$PID_PATH = Join-Path $ROOT_DIR 'rotator.pid'

# Live status written by the rotator and read by status.bat / stop.bat.
$STATE_PATH = Join-Path $ROOT_DIR 'state.json'

# Your Proton OpenVPN username/password (NOT your Proton email login).
# setup.bat writes this file in your Windows user folder, outside this project,
# and locks it so only your Windows account can read it.
$AUTH_FILE_PATH = Join-Path $env:USERPROFILE '.iprotator\proton-auth.txt'

# Full path to openvpn-gui.exe. Leave empty to find it automatically.
$OPENVPN_GUI_PATH = ''

# Name prefix for the copies of your configs that are handed to OpenVPN GUI,
# so they never clash with configs you imported into OpenVPN GUI yourself.
$CONFIG_NAME_PREFIX = 'iprot-'

# How long to wait for one server to connect before trying the next one.
$CONNECT_TIMEOUT_SECONDS = 45

# How long to wait for a disconnect to finish.
$DISCONNECT_TIMEOUT_SECONDS = 15

# Web service that tells us your public IP address.
$IP_CHECK_URL = 'https://api.ipify.org'
