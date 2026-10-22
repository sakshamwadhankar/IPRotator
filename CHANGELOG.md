# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [2.0.0] - 2026-10-22

### Changed
- **Now uses Tor instead of OpenVPN + Proton VPN.** No account, no login, no install and no
  config files: clone the repo, run `start.bat`, and the IP changes.
- `start.bat` downloads the official Tor Expert Bundle on the first run, verifies its SHA-256
  checksum, and points Windows' proxy settings at Tor. `stop.bat` restores them.
- `start.bat` accepts the interval and auto-stop hours as arguments (`start.bat 300 2`) to
  skip the questions.
- Each change closes old Tor routes so open browser tabs switch to the new IP too.
- `status.bat` shows the country of the current Tor exit.

### Added
- One-time sign-in safety net that restores your proxy settings if the PC restarts while the
  rotator is running. It never starts the rotator.

### Removed
- `setup.bat`, the `configs` folder, OpenVPN GUI and Proton VPN requirements, and the
  credentials file.

## [1.0.0] - 2026-10-22

### Added
- `start.bat`: asks for the switch interval (whole seconds, minimum 60, last value
  offered as the default) and an optional auto-stop time, then runs the rotator as
  a hidden background process.
- `rotator.ps1`: switches to a different random Proton VPN free server through
  OpenVPN GUI on every interval, checks the new public IP with api.ipify.org, tries
  other servers on failure, and falls back to your normal internet if every
  server fails.
- `stop.bat`: stops the rotator, disconnects the VPN and confirms your normal
  internet works.
- `status.bat`: shows running state, interval, server, current public IP, time
  until the next switch and the last 10 log lines.
- `setup.bat`: checks Windows and OpenVPN GUI, creates the configs folder,
  unblocks the scripts, saves your OpenVPN credentials to a file only your
  account can read, and creates Desktop shortcuts.
- `make-shortcut.ps1`: creates (or removes with `-Remove`) Desktop shortcuts with icons.
- Single-instance lock, log rotation at 1 MB, and UDP-only config filtering.
