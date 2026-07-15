<div align="center">

<img src="app-icon.png" width="128" height="128" alt="Orbit app icon" />

# Orbit

Native macOS SSH workspace for developers and operators.

[![Release](https://img.shields.io/github/v/release/ibreez3/orbit?include_prereleases&label=release)](https://github.com/ibreez3/orbit/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black)](#build-from-source)

[中文文档](README_cn.md)

</div>

---

Orbit is a native macOS SSH manager built with SwiftUI, AppKit, SwiftTerm, and a Rust SSH/SFTP core. It is designed for people who manage multiple Linux servers and want terminal sessions, SFTP, monitoring, snippets, jump hosts, and credentials in one focused desktop app.

Current preview release: **v0.0.6-pre**

## Features

- **SSH terminal**: SwiftTerm-powered `xterm-256color` terminal with split panes, tabs, resize handling, and high-throughput output pumping.
- **SFTP file manager**: browse, upload, download, delete, rename, drag-and-drop upload, and transfer progress.
- **Remote text editing**: open common text/config/code files from SFTP and save changes back to the server.
- **Server monitoring**: CPU, memory, disk, network, process list, and Swift Charts trend views.
- **Jump host support**: connect through bastion servers with local TCP forwarding.
- **Credential groups**: reuse credentials across servers and keep passwords/private keys encrypted locally.
- **Port forwarding**: manage local-to-remote SSH tunnel rules from settings.
- **Batch execution**: run commands across multiple servers with concurrency, timeout, cancel, and status reporting.
- **Snippets with variables**: insert command templates with `{{host}}`, `{{user}}`, `{{port}}`, `{{server_name}}`, and `{{group}}`.
- **Themes and keyword highlights**: built-in themes plus configurable terminal keyword highlighting.
- **Native Apple Silicon build**: arm64 static Rust library linked into a macOS app.

## Screenshots

Screenshots are not committed yet. Contributions that add representative screenshots or a short demo GIF are welcome.

## Requirements

For using the app:

- macOS 13.0 or later
- Apple Silicon Mac is the primary supported target
- Linux servers for monitoring scripts

For development:

- macOS 13.0 or later
- Xcode 15 or later
- Rust 1.77 or later
- `aarch64-apple-darwin` Rust target
- XcodeGen (`brew install xcodegen`)

## Install

Download the latest preview from [GitHub Releases](https://github.com/ibreez3/orbit/releases).

| Asset | Description |
| --- | --- |
| `Orbit-v*-AppleSilicon.dmg` | Recommended installer for Apple Silicon Macs |
| `Orbit*.zip` | Archive build when available |

Orbit preview builds are locally signed but not Apple-notarized yet. On first launch, right-click `Orbit.app`, choose **Open**, then confirm. You can also clear quarantine from Terminal:

```bash
xattr -cr /Applications/Orbit.app
```

## Build From Source

```bash
git clone https://github.com/ibreez3/orbit.git
cd orbit

# Build the Rust arm64 static libraries.
./scripts/build-rust.sh

# Generate the Xcode project, build Release, and verify signing/entitlements.
make build-app

# Open the project for development.
open orbit-app/Orbit.xcodeproj
```

Useful commands:

```bash
cd orbit-app && xcodegen generate && cd ..
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release -arch arm64 build
cargo test --manifest-path orbit-rs/Cargo.toml --release --target aarch64-apple-darwin
```

## Project Layout

```text
orbit/
├── orbit-app/                 # SwiftUI/AppKit macOS app
│   ├── project.yml            # XcodeGen source of truth
│   └── Orbit/
│       ├── OrbitApp.swift     # app entry point
│       ├── OrbitBridge.swift  # Swift/C FFI bridge
│       ├── Models/            # Swift data models and services
│       ├── ViewModels/        # split ObservableObject states
│       └── Views/             # UI views
├── orbit-rs/                  # Rust core compiled as a static library
│   ├── src/ffi.rs             # C ABI exports
│   ├── src/ssh.rs             # SSH session and terminal channel manager
│   ├── src/sftp.rs            # SFTP operations
│   ├── src/transport.rs       # direct and jump-host transports
│   ├── src/db.rs              # SQLite storage
│   └── include/orbit.h        # generated C header
├── scripts/                   # build and verification scripts
└── docs/                      # appcast and design documents
```

## Security Notes

- Credentials are encrypted locally with AES-256-GCM.
- Current encryption is tied to the local machine hostname; moving the database to another Mac requires re-entering credentials.
- Preview builds are not Apple-notarized yet.
- Jump hosts require `AllowTcpForwarding yes` on the bastion server.

## Known Limitations

- Monitoring scripts target Linux servers and are not intended for macOS/BSD hosts.
- The primary packaged build is Apple Silicon arm64.

## Contributing

Issues and pull requests are welcome.

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/my-feature`.
3. Make focused changes and keep `project.yml` as the source of truth for Xcode settings.
4. Run the relevant build/test commands.
5. Open a pull request against `develop`.

See [AGENTS.md](AGENTS.md) for architecture notes, FFI conventions, build commands, and development guidelines.

## License

Orbit is released under the [MIT License](LICENSE).
