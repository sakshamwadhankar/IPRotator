# configs/

Put your **Proton VPN free-server UDP `.ovpn` files** in this folder.

- You need **at least 2**, because the rotator switches between them. More files
  give you more different IP addresses.
- Use **UDP** configs. Any TCP config (`proto tcp`) is skipped.
- Download them from your Proton VPN account: **Downloads → OpenVPN configuration
  files**, Platform **Windows**, Protocol **UDP**, **Free server configs**.
  Proton's guide: <https://protonvpn.com/support/vpn-config-download>
- Your files are never changed. When the rotator starts, it copies them into
  OpenVPN GUI's own config folder (`%USERPROFILE%\OpenVPN\config\IPRotator\`).
- If you add or remove files while the rotator is running, run `stop.bat` and then
  `start.bat` to pick up the change.

`.ovpn` files are ignored by git (see `.gitignore`), so they are never uploaded if
you publish your copy of this project.
