<#
=============================================================================
 setup.ps1 - one-time setup. Run it by double-clicking setup.bat.
   1. checks your Windows version,
   2. checks OpenVPN GUI is installed (and stops with the download link if not),
   3. creates the configs folder and counts your .ovpn files,
   4. unblocks the scripts (Windows marks downloaded files as "blocked"),
   5. saves your Proton OpenVPN username/password,
   6. creates the Desktop shortcuts.
 Safe to run again at any time, e.g. to change your saved credentials.
=============================================================================
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Write-Step {
    param([int]$Number, [string]$Text)
    Write-Host ''
    Write-Host "  Step $Number of 6: $Text" -ForegroundColor Cyan
}

function Save-Credentials {
    # Writes your OpenVPN username and password to a file in your Windows user
    # folder and locks it so that only your Windows account can open it.
    # OpenVPN reads it every time it connects, so the background rotator
    # never needs to show a login box.
    param([string]$UserName, [Security.SecureString]$Password)

    $dir = Split-Path -Path $AUTH_FILE_PATH -Parent
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # Your Windows account's security ID (SID).
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    # Lock the folder first: drop inherited permissions, allow only your account.
    & icacls.exe $dir /inheritance:r /grant:r "*${sid}:(OI)(CI)(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't restrict access to $dir" }

    # Turn the hidden password back into text only for as long as it takes to write it.
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [IO.File]::WriteAllText($AUTH_FILE_PATH, "$UserName`n$plain`n", (New-Object System.Text.UTF8Encoding $false))
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $plain = $null
    }

    # And lock the file itself the same way.
    & icacls.exe $AUTH_FILE_PATH /inheritance:r /grant:r "*${sid}:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't restrict access to $AUTH_FILE_PATH" }
}

function Test-SecureStringsEqual {
    param([Security.SecureString]$A, [Security.SecureString]$B)
    $ba = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($A)
    $bb = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($B)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ba) -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bb)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ba)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bb)
    }
}

try {
    Write-Title 'IP Rotator - setup'

    # --- 1. Windows version --------------------------------------------------
    Write-Step 1 'Checking Windows'
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ([Environment]::OSVersion.Version.Major -lt 10) {
        Write-Host "  [!!] $($os.Caption) is not supported. IP Rotator needs Windows 10 or 11." -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] $($os.Caption) (build $build)" -ForegroundColor Green
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host "  [!!] PowerShell $($PSVersionTable.PSVersion) is too old; 5.1 or newer is needed." -ForegroundColor Red
        exit 1
    }

    # --- 2. OpenVPN GUI ------------------------------------------------------
    Write-Step 2 'Checking OpenVPN GUI'
    $gui = Find-OpenVpnGui
    if (-not $gui) {
        Write-Host '  [!!] OpenVPN GUI is not installed.' -ForegroundColor Red
        Write-Host ''
        Write-Host '  Download the free "OpenVPN Community" Windows installer (64-bit MSI) from'
        Write-Host '  the official page:' -NoNewline
        Write-Host ' https://openvpn.net/community-downloads/' -ForegroundColor Cyan
        Write-Host '  Install it with the default options (installing needs admin rights once),'
        Write-Host '  then run setup.bat again.'
        exit 1
    }
    Write-Host "  [OK] Found $gui" -ForegroundColor Green
    # The Interactive Service is what lets OpenVPN connect without admin prompts.
    $svc = Get-Service -Name 'OpenVPNServiceInteractive' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "  [!!] The 'OpenVPN Interactive Service' is missing. Reinstall OpenVPN with the" -ForegroundColor Yellow
        Write-Host '       default options, otherwise every connection will need admin rights.' -ForegroundColor Yellow
    } elseif ($svc.Status -ne 'Running' -and $svc.StartType -eq 'Disabled') {
        Write-Host "  [!!] The 'OpenVPN Interactive Service' is disabled. Set it to Automatic in" -ForegroundColor Yellow
        Write-Host '       services.msc (needs admin once), otherwise connections will fail.' -ForegroundColor Yellow
    } else {
        Write-Host '  [OK] OpenVPN Interactive Service is available (no admin prompts needed).' -ForegroundColor Green
    }

    # --- 3. configs folder ---------------------------------------------------
    Write-Step 3 'Checking the configs folder'
    New-Item -ItemType Directory -Path $CONFIGS_DIR -Force | Out-Null
    $configs = Get-SourceConfigs
    $udpCount = @($configs.Udp).Count
    $tcpCount = @($configs.Tcp).Count
    if ($udpCount -ge 2) {
        Write-Host "  [OK] $udpCount UDP config(s) found." -ForegroundColor Green
    } else {
        Write-Host "  [!!] Found $udpCount UDP config(s); you need at least 2." -ForegroundColor Yellow
        Write-Host '       Download Proton VPN free-server configs (Platform: Windows, Protocol: UDP)'
        Write-Host '       as explained in README.md, and put the .ovpn files in:'
        Write-Host "       $CONFIGS_DIR" -ForegroundColor Cyan
        Write-Host '       (Setup continues; you can add them later.)'
    }
    if ($tcpCount -gt 0) { Write-Host "  [i]  $tcpCount TCP config(s) will be skipped (UDP is faster)." }

    # --- 4. Unblock the scripts ----------------------------------------------
    Write-Step 4 'Unblocking the scripts'
    # Files downloaded from the internet carry a "blocked" mark that makes
    # Windows warn every time you run them. This removes that mark from this
    # project's own scripts only.
    $files = @(Get-ChildItem -Path $ROOT_DIR -Recurse -File -Include '*.ps1', '*.bat')
    $files | Unblock-File
    Write-Host "  [OK] $($files.Count) script(s) unblocked." -ForegroundColor Green

    # --- 5. Credentials ------------------------------------------------------
    Write-Step 5 'Saving your Proton OpenVPN username and password'
    $askForCredentials = $true
    if (Test-Path $AUTH_FILE_PATH) {
        Write-Host '  Saved credentials already exist.'
        $askForCredentials = Read-YesNo '  Replace them? (Y/N)'
    }
    if ($askForCredentials) {
        Write-Host ''
        Write-Host '  You need your OpenVPN / IKEv2 username and password. These are NOT your'
        Write-Host '  Proton email and password. Sign in at https://account.protonvpn.com and'
        Write-Host '  open the "OpenVPN / IKEv2 username" section. Step-by-step help:'
        Write-Host '  https://protonvpn.com/support/vpn-login/' -ForegroundColor Cyan
        Write-Host ''
        $userName = ''
        while (-not $userName) {
            $userName = Read-Answer '  OpenVPN username'
            if ($userName -match '\s') { Write-Host '  The username has no spaces in it. Please paste it again.' -ForegroundColor Yellow; $userName = '' }
        }
        while ($true) {
            $pass1 = Read-Host '  OpenVPN password (hidden while you type)' -AsSecureString
            if ($pass1.Length -eq 0) { Write-Host '  The password cannot be empty.' -ForegroundColor Yellow; continue }
            $pass2 = Read-Host '  Type the password again' -AsSecureString
            if (Test-SecureStringsEqual $pass1 $pass2) { break }
            Write-Host "  The two passwords don't match. Please try again." -ForegroundColor Yellow
        }
        Save-Credentials -UserName $userName -Password $pass1
        Write-Host "  [OK] Saved to $AUTH_FILE_PATH" -ForegroundColor Green
        Write-Host '       Only your Windows account can open this file. It is outside the project'
        Write-Host '       folder, so it is never shared or uploaded with the scripts.'
    } else {
        Write-Host '  [OK] Keeping your saved credentials.' -ForegroundColor Green
    }

    # --- 6. Desktop shortcuts ------------------------------------------------
    Write-Step 6 'Creating Desktop shortcuts'
    & (Join-Path $PSScriptRoot 'make-shortcut.ps1')

    # --- Done ----------------------------------------------------------------
    Write-Host ''
    if ($udpCount -ge 2) {
        Write-Host '  Setup complete! Double-click "IP Rotator - Start" on your Desktop.' -ForegroundColor Green
    } else {
        Write-Host '  Setup complete, except for the configs: add at least 2 UDP .ovpn files to' -ForegroundColor Yellow
        Write-Host "  $CONFIGS_DIR and then double-click ""IP Rotator - Start"" on your Desktop." -ForegroundColor Yellow
    }
    exit 0
}
catch {
    Show-FriendlyError $_
    exit 1
}
