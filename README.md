<div align="center">

<img src="app-icon.png" width="128" height="128" alt="Orbit app icon" />

# Orbit

A native macOS SSH workspace for developers and operators.

[![Release](https://img.shields.io/github/v/release/ibreez3/orbit?include_prereleases&label=release)](https://github.com/ibreez3/orbit/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black)](#build-from-source)

[中文文档](README_cn.md)

</div>

---

Orbit brings the tools you use to run Linux servers into a single native macOS app: SSH terminals, SFTP, remote editing, resource monitoring, Docker, databases, batch execution, and AI-assisted operations. The UI is built with SwiftUI and AppKit; SSH, SFTP, storage, and the AI agent gateway run in a Rust core linked as a static library.

Orbit is designed for developers and operators who work with many servers every day and would rather keep one focused workspace open than juggle a terminal, a file browser, a monitor, and a chat window.

## Highlights

- **Native, not Electron** — a SwiftUI/AppKit app with a Rust core, packaged for Apple Silicon.
- **One workspace for daily operations** — terminal tabs and split panes, SFTP, monitoring, Docker, database queries, batch execution, snippets, jump hosts, and port forwarding.
- **AI under your control** — a built-in assistant for any OpenAI-compatible endpoint, plus an opt-in MCP/CLI gateway that lets local agents run commands through Orbit's approval and audit layer.
- **Credentials stay local** — passwords and private keys are encrypted with AES-256-GCM and are never handed to AI agents.

## Features

### Terminal and workspace

- `xterm-256color` terminal built on SwiftTerm, with tabs, split panes, resize handling, and high-throughput output.
- Local terminal sessions alongside remote SSH sessions.
- Command palette on `⌘⇧P` and quick connect on `⌘K`.
- Configurable keybindings, built-in themes, and terminal keyword highlighting.

### Remote files and editing

- SFTP file manager: browse, upload, download, rename, delete, drag-and-drop upload, and transfer progress.
- Remote text editor for common text, config, and code files, saving changes back over SFTP.

### Monitoring and operations

- Resource monitoring: CPU, memory, disk, network, process list, and Swift Charts trend views.
- Docker management: container list, status, per-container CPU and memory, logs, start, stop, restart, and remove.
- Batch execution across multiple servers with concurrency, timeout, cancellation, and per-server status.
- Snippets with `{{host}}`, `{{user}}`, `{{port}}`, `{{server_name}}`, and `{{group}}` variables.
- Jump host support through bastion servers with local TCP forwarding.
- Port forwarding rules managed from settings.

### Database

- Connect to remote SQLite (over SSH), MySQL, and PostgreSQL.
- SQL editor with read-only mode, query timeout, automatic `LIMIT`, result tables, and schema browsing.
- Backup and import with column mapping for common data formats.

### AI assistant

- A built-in AI panel that works with any OpenAI-compatible endpoint, including OpenAI, DeepSeek, Qwen, Kimi, and Ollama.
- The assistant can propose shell commands in ```` ```execute ```` blocks; Orbit asks for confirmation before running them.
- AI activity is recorded in the per-session audit trail shown in the AI panel.

### AI Agent gateway (MCP + CLI)

Orbit can expose selected servers to local AI agents such as Claude Code, Codex, or any agent with shell access. Agents never receive SSH credentials; every command goes through Orbit's admission, approval, and audit layer.

- **MCP bridge** — `orbit-mcp` exposes tools for server listing, read/write execution, long-running jobs, persistent shells, and approval status.
- **CLI** — `orbit-cli` provides `auth`, `servers`, `exec`, `job`, and `shell` subcommands for agents without MCP support.
- **Local only** — the gateway listens on a Unix socket (`agent.sock`, mode `0600`) and never opens a TCP port.
- **Approval and audit** — sessions require user approval; servers are exposed individually; writes require a session-scoped grant; sessions can be revoked; calls are written to `~/Library/Application Support/Orbit/agent/audit.log`.

See [docs/agent-mcp-setup.md](docs/agent-mcp-setup.md) for the full setup and security model.

## Screenshots

Screenshots are not committed yet. Contributions that add representative screenshots or a short demo GIF are welcome.

## Requirements

Using the app:

- macOS 13.0 or later
- Apple Silicon Mac (primary supported target)
- Linux servers for monitoring and Docker features

Development:

- macOS 13.0 or later
- Xcode 15 or later
- Rust 1.77 or later with the `aarch64-apple-darwin` target
- XcodeGen (`brew install xcodegen`)

## Install

Download the latest release from [GitHub Releases](https://github.com/ibreez3/orbit/releases).

| Asset | Description |
| --- | --- |
| `Orbit-v*-AppleSilicon.dmg` | Recommended installer for Apple Silicon Macs |
| `Orbit*.zip` | Archive build when available |

Release builds are ad-hoc signed but not Apple-notarized yet. On first launch, right-click `Orbit.app`, choose **Open**, then confirm. You can also clear quarantine from Terminal:

```bash
xattr -cr /Applications/Orbit.app
```

## AI agent setup

Enable **Settings → AI Agent → 允许 MCP / CLI Agent 接入 Orbit** (Allow MCP / CLI agent access), then expose the servers the agent may use. The first connection requires approval in Orbit.

Claude Code:

```bash
claude mcp add orbit -- /Applications/Orbit.app/Contents/MacOS/orbit-mcp
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.orbit]
command = "/Applications/Orbit.app/Contents/MacOS/orbit-mcp"
```

Agents without MCP support can use the CLI:

```bash
/Applications/Orbit.app/Contents/MacOS/orbit-cli auth --client "My Agent"
/Applications/Orbit.app/Contents/MacOS/orbit-cli servers
/Applications/Orbit.app/Contents/MacOS/orbit-cli exec --server "prod-1" --mode read -- "docker ps"
```

Use `--mode write` for changes. The first write to a server opens a one-time approval panel; later writes in the same session reuse the grant. Long commands return a `jobId` that can be polled with `orbit-cli job status|output|cancel`.

## Build from source

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

## Project layout

```text
orbit/
├── orbit-app/                 # SwiftUI/AppKit macOS app
│   ├── project.yml            # XcodeGen source of truth
│   ├── AgentKit/              # Agent gateway protocol, MCP/CLI support
│   ├── OrbitCLI/              # orbit-cli entry point
│   ├── OrbitMCP/              # orbit-mcp entry point
│   └── Orbit/
│       ├── OrbitApp.swift     # app entry point
│       ├── OrbitBridge.swift  # Swift/C FFI bridge
│       ├── Agent/             # gateway services and approval UI
│       ├── Models/            # data models and services
│       ├── ViewModels/        # split ObservableObject states
│       └── Views/             # UI views
├── orbit-rs/                  # Rust core compiled as a static library
│   ├── src/ffi.rs             # C ABI exports
│   ├── src/ssh.rs             # SSH session and terminal channel manager
│   ├── src/sftp.rs            # SFTP operations
│   ├── src/transport.rs       # direct and jump-host transports
│   ├── src/database/          # database query, backup, and import support
│   ├── src/db.rs              # SQLite storage
│   └── include/orbit.h        # generated C header
├── scripts/                   # build and verification scripts
└── docs/                      # appcast, agent setup, and design documents
```

## Security notes

- Credentials are encrypted locally with AES-256-GCM.
- The encryption key is currently tied to the local machine hostname; moving the database to another Mac requires re-entering credentials.
- The AI agent gateway listens on a local Unix socket only and requires explicit approval for every new agent session.
- Read commands run without per-command confirmation. Write commands require a grant that is scoped to one agent session and one server.
- The command guard and approval flow are safety layers, not a sandbox: an agent can still read remote secrets into its own context if a command exposes them.
- Release builds are not Apple-notarized yet.
- Jump hosts require `AllowTcpForwarding yes` on the bastion server.

## Known limitations

- Monitoring scripts target Linux servers and are not intended for macOS/BSD hosts.
- The primary packaged build is Apple Silicon arm64.
- Some advanced SSH features depend on the remote server's configuration.

## Contributing

Issues and pull requests are welcome.

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/my-feature`.
3. Keep changes focused and treat `project.yml` as the source of truth for Xcode settings.
4. Run the relevant build and test commands.
5. Open a pull request against `develop`.

See [AGENTS.md](AGENTS.md) for architecture notes, FFI conventions, build commands, and development guidelines.

## License

Orbit is released under the [MIT License](LICENSE).
