# Contributing

Thanks for wanting to help! Bug reports, ideas and pull requests are all welcome.

## Reporting a bug or asking for a feature

Open an [issue](../../issues/new/choose) and pick the bug report or feature request
template. For bugs, please include the last lines of `rotator.log` and the output of
`status.bat`.

**Before you paste anything, remove private details:** your OpenVPN username or
password, your home IP address, and anything from your `.ovpn` files.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep to the existing style:
   - Windows PowerShell **5.1** compatible (no PowerShell 7-only syntax).
   - **ASCII only** in `.ps1` and `.bat` files. Windows PowerShell 5.1 misreads
     non-ASCII characters in files saved without a BOM.
   - Comment what the code does in plain English.
   - Show friendly messages, not raw PowerShell errors.
   - Don't add anything that needs admin rights, changes the system execution
     policy, or starts with Windows.
3. Test on Windows 10 or 11 with a real Proton VPN Free account: start, status,
   Ctrl+C / close the start window, then stop.
4. Add a line to `CHANGELOG.md` under an "Unreleased" heading.
5. Open the pull request and describe what you changed and how you tested it.

By contributing you agree that your work is released under the [MIT License](LICENSE).
