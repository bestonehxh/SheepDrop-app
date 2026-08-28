<p align="center">
  <img src=".github/icon.png?v=2" width="128" alt="SheepDrop app icon">
</p>

# 🐑 SheepDrop

**A native macOS file-transfer app built for network engineers — SFTP, SCP, FTP, and TFTP, as both a client and a built-in server.**

SheepDrop is written in SwiftUI + AppKit (Swift 6) and designed around the daily workflow of
moving configs and firmware to and from switches, routers, firewalls, and access points:
browse a device over SFTP/SCP like a dual-pane file manager, or flip on a built-in server so
the device can pull (or push) files from your Mac with its own `copy scp:` / `copy tftp:`
command — no separate TFTP daemon to configure.

## ⬇️ Download

[![Download SheepDrop for macOS](https://img.shields.io/badge/Download-SheepDrop_1.0_for_macOS-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/bestonehxh/SheepDrop-app/releases/latest)

**[Get the latest release →](https://github.com/bestonehxh/SheepDrop-app/releases/latest)** — download the `.zip`, unzip, and drag **SheepDrop.app** into `Applications`.

> The build is unsigned (not notarized), so macOS will warn on first launch —
> right-click the app and choose **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/SheepDrop.app`
>
> Requires macOS 26 (Tahoe) or later, Apple Silicon.

## Features

### Connect to a device (client)
- **SFTP** and **SCP** over bundled libssh 0.12 — browse the remote filesystem in a
  **dual-pane** view (This Mac ⇄ device), with per-pane `cd`-style address bars and back
  navigation
- **SCP browses like WinSCP** — when a device serves the SFTP subsystem, an SCP session
  becomes fully browsable instead of blind put/get
- **FTP** and **TFTP** for older gear
- **Legacy SSH that just works on old switches** — the server offers modern algorithms
  first and falls back to the legacy KEX, ciphers, MACs, and `ssh-rsa` host keys that old
  Cisco IOS / Aruba / HPE gear is limited to, so a modern client is never downgraded but an
  old one still connects
- **Quick Connect** — type `admin@10.0.0.1`, `admin@sw01:2222`, pick the protocol, and go
- Sidebar with **host groups**, search, and recent connections

### Let a device reach your Mac (built-in server)
- One-switch **TFTP**, **SFTP / SCP**, and **FTP** servers so a device can run
  `copy scp://user@mac/file …`, `copy tftp://mac/file …`, etc. and pull from (or back up to)
  a served folder on your Mac
- **SCP / SFTP share one SSH server on port 22** (falls back to 2222 if macOS Remote Login
  owns 22) — `copy scp:` on switches always uses port 22, and SheepDrop binds it
- **Live request log** and an always-present **transfer bar** showing upload/download
  progress, held as history when a transfer finishes
- **Allow-writes** toggle for device backups, applied live without a restart

### Security
- The server authenticates against an app-defined **virtual username + password** — never
  your macOS account
- Passwords are stored **only in the macOS Keychain** — never in config files or exports

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon
- To build: Xcode 26+ and Homebrew `libssh`

## Building

```bash
brew install libssh
xcodebuild -project SheepDrop.xcodeproj -scheme SheepDrop -configuration Release build
```

The app is built at
`~/Library/Developer/Xcode/DerivedData/SheepDrop-*/Build/Products/Release/SheepDrop.app`.

## The Sheep family 🐑

SheepDrop is one of a set of small native macOS apps that share the same sheep icon set:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepDrop-app/main/.github/icon.png?v=2" width="44" alt=""> | [SheepDrop](https://github.com/bestonehxh/SheepDrop-app) | SFTP / SCP / FTP / TFTP file transfer — client and built-in server |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTerm-app/main/.github/icon.png" width="44" alt=""> | [SheepTerm](https://github.com/bestonehxh/SheepTerm-app) | SSH / Serial / local-shell terminal for network engineers |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTap-app/main/.github/icon.png" width="44" alt=""> | [SheepTap](https://github.com/bestonehxh/SheepTap-app) | Menu-bar viewer for your Mac's network interfaces with click-to-copy |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepPing-app/main/.github/icon.png" width="44" alt=""> | [SheepPing](https://github.com/bestonehxh/SheepPing-app) | Continuous multi-host ping monitor with per-host logs and CSV export |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepText-app/main/.github/icon.png" width="44" alt=""> | [SheepText](https://github.com/bestonehxh/SheepText-app) | Fast text editor with tree-sitter highlighting and a JavaScript plugin system |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepArt-app/main/.github/icon.png" width="44" alt=""> | [SheepArt](https://github.com/bestonehxh/SheepArt-app) | Screenshot annotation — draw, crop, layers, one-key background removal |

## Acknowledgements

- [libssh](https://www.libssh.org) (LGPL-2.1) — SSH / SFTP / SCP transport, bundled as a dynamic library

## License

[MIT](LICENSE) © 2026 bestonehxh
