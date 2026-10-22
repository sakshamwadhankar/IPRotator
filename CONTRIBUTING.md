# Contributing

Thanks for wanting to help! Bug reports, ideas and pull requests are all welcome.

## Reporting a bug or asking for a feature

Open an [issue](../../issues/new/choose) and pick the bug report or feature request
template. For bugs, please include the last lines of `rotator.log` and the output of
`status.bat`.

**Before you paste anything, remove your real (home) IP address.**

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep to the project's promises:
   - **Simple:** clone, run `start.bat`, done. No accounts, no logins, no installers,
     no admin rights.
   - Never change the system execution policy, and never start the rotator with Windows.
   - Always leave the user's proxy settings exactly as they were when it stops.
3. Keep to the existing style:
   - Windows PowerShell **5.1** compatible (no PowerShell 7-only syntax).
   - **ASCII only** in `.ps1` and `.bat` files. Windows PowerShell 5.1 misreads
     non-ASCII characters in files saved without a BOM.
   - Comment what the code does in plain English.
   - Show friendly messages, not raw PowerShell errors.
4. Test on Windows 10 or 11: `start.bat 60`, check a browser shows a new IP after a minute,
   `status.bat`, close the start window, then `stop.bat` and check your normal IP is back.
5. Add a line to `CHANGELOG.md` under an "Unreleased" heading.
6. Open the pull request and describe what you changed and how you tested it.

By contributing you agree that your work is released under the [MIT License](LICENSE).
