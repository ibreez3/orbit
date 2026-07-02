<div align="center">

<img src="app-icon.png" width="128" height="128" alt="Orbit app icon" />

# Orbit

Native macOS SSH workspace for developers and operators.

原生 macOS SSH 管理终端，面向开发者与运维人员。

[![Release](https://img.shields.io/github/v/release/ibreez3/orbit?include_prereleases&label=release)](https://github.com/ibreez3/orbit/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black)](#build-from-source)

[English](#english) · [中文](#中文)

</div>

---

## English

Orbit is a native macOS SSH manager built with SwiftUI, AppKit, SwiftTerm, and a Rust SSH/SFTP core. It is designed for people who manage multiple Linux servers and want terminal sessions, SFTP, monitoring, snippets, jump hosts, and credentials in one focused desktop app.

Current preview release: **v0.0.6-pre**

### Features

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

### Screenshots

Screenshots are not committed yet. Contributions that add representative screenshots or a short demo GIF are welcome.

### Requirements

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

### Install

Download the latest preview from [GitHub Releases](https://github.com/ibreez3/orbit/releases).

| Asset | Description |
| --- | --- |
| `Orbit-v*-AppleSilicon.dmg` | Recommended installer for Apple Silicon Macs |
| `Orbit*.zip` | Archive build when available |

Orbit preview builds are locally signed but not Apple-notarized yet. On first launch, right-click `Orbit.app`, choose **Open**, then confirm. You can also clear quarantine from Terminal:

```bash
xattr -cr /Applications/Orbit.app
```

### Build From Source

```bash
git clone https://github.com/ibreez3/orbit.git
cd orbit

# Build the Rust arm64 static libraries.
./scripts/build-rust.sh

# Generate the Xcode project, build Release, and verify signing/entitlements.
make build-app

# Build a local DMG and verify the mounted app bundle.
make build-dmg DMG_PATH=release/Orbit-local-AppleSilicon.dmg VOLUME_NAME="Orbit"

# Open the project for development.
open orbit-app/Orbit.xcodeproj
```

Useful commands:

```bash
cd orbit-app && xcodegen generate && cd ..
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release -arch arm64 build
cargo test --manifest-path orbit-rs/Cargo.toml --release --target aarch64-apple-darwin
```

### Project Layout

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
├── scripts/                   # build, DMG, and verification scripts
└── docs/                      # release/appcast and design documents
```

### Release Process

Preview releases use tags such as `v0.0.6-pre`.

1. Update `orbit-app/project.yml` version fields.
2. Regenerate the Xcode project with `xcodegen generate`.
3. Run `make build-dmg`.
4. Commit to `develop`.
5. Create and push the release tag.
6. Publish a GitHub prerelease and upload the Apple Silicon DMG.

The release workflow can also build and upload a DMG when a GitHub Release is published.

### Security Notes

- Credentials are encrypted locally with AES-256-GCM.
- Current encryption is tied to the local machine hostname; moving the database to another Mac requires re-entering credentials.
- Preview builds are not Apple-notarized yet.
- Jump hosts require `AllowTcpForwarding yes` on the bastion server.

### Known Limitations

- Monitoring scripts target Linux servers and are not intended for macOS/BSD hosts.
- The primary packaged build is Apple Silicon arm64.
- Notarization and Developer ID signing are prepared in CI as placeholders but require Apple developer credentials.

### Contributing

Issues and pull requests are welcome.

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/my-feature`.
3. Make focused changes and keep `project.yml` as the source of truth for Xcode settings.
4. Run the relevant build/test commands.
5. Open a pull request against `develop`.

See [AGENTS.md](AGENTS.md) for architecture notes, FFI conventions, build commands, and development guidelines.

### License

Orbit is released under the [MIT License](LICENSE).

---

## 中文

Orbit 是一款原生 macOS SSH 管理终端，基于 SwiftUI、AppKit、SwiftTerm 和 Rust SSH/SFTP 核心构建。它面向需要管理多台 Linux 服务器的开发者与运维人员，把 SSH 终端、SFTP、资源监控、命令片段、跳板机和凭据管理整合到一个专注的桌面应用里。

当前预览版本：**v0.0.6-pre**

### 功能特性

- **SSH 终端**：基于 SwiftTerm 的 `xterm-256color` 终端，支持标签页、分屏、尺寸同步和高吞吐输出。
- **SFTP 文件管理**：浏览、上传、下载、删除、重命名、拖拽上传和传输进度。
- **远程文本编辑**：从 SFTP 打开常见文本、配置、代码文件，修改后保存回服务器。
- **资源监控**：CPU、内存、磁盘、网络、进程列表和 Swift Charts 趋势图。
- **跳板机支持**：通过堡垒机连接目标服务器，自动建立本地 TCP 转发。
- **凭据分组**：多台服务器复用同一套认证信息，密码和私钥本地加密存储。
- **端口转发**：在设置中管理本地到远端的 SSH 隧道规则。
- **批量执行**：跨服务器执行命令，支持并发数、超时、取消和结果状态。
- **片段变量**：命令模板支持 `{{host}}`、`{{user}}`、`{{port}}`、`{{server_name}}`、`{{group}}`。
- **主题与关键词高亮**：内置多套主题，并支持终端关键词高亮。
- **Apple Silicon 原生构建**：Rust arm64 静态库直接链接进 macOS App。

### 截图

仓库暂未提交截图。欢迎贡献能展示主要工作流的截图或简短演示 GIF。

### 环境要求

使用应用：

- macOS 13.0 或更高版本
- 主要支持 Apple Silicon Mac
- 资源监控脚本面向 Linux 服务器

开发环境：

- macOS 13.0 或更高版本
- Xcode 15 或更高版本
- Rust 1.77 或更高版本
- Rust target：`aarch64-apple-darwin`
- XcodeGen（`brew install xcodegen`）

### 安装

前往 [GitHub Releases](https://github.com/ibreez3/orbit/releases) 下载最新预览版本。

| 文件 | 说明 |
| --- | --- |
| `Orbit-v*-AppleSilicon.dmg` | 推荐的 Apple Silicon 安装包 |
| `Orbit*.zip` | 可用时提供的压缩包 |

Orbit 预览版已本地签名，但暂未 Apple 公证。首次打开时，请右键点击 `Orbit.app`，选择「打开」，然后确认。也可以在终端执行：

```bash
xattr -cr /Applications/Orbit.app
```

### 从源码构建

```bash
git clone https://github.com/ibreez3/orbit.git
cd orbit

# 构建 Rust arm64 静态库
./scripts/build-rust.sh

# 生成 Xcode 工程、构建 Release，并验证签名和关键权限
make build-app

# 构建本地 DMG，并验证挂载后的 app
make build-dmg DMG_PATH=release/Orbit-local-AppleSilicon.dmg VOLUME_NAME="Orbit"

# 打开 Xcode 工程进行开发
open orbit-app/Orbit.xcodeproj
```

常用命令：

```bash
cd orbit-app && xcodegen generate && cd ..
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release -arch arm64 build
cargo test --manifest-path orbit-rs/Cargo.toml --release --target aarch64-apple-darwin
```

### 项目结构

```text
orbit/
├── orbit-app/                 # SwiftUI/AppKit macOS 应用
│   ├── project.yml            # XcodeGen 工程配置源码
│   └── Orbit/
│       ├── OrbitApp.swift     # 应用入口
│       ├── OrbitBridge.swift  # Swift/C FFI 桥接层
│       ├── Models/            # Swift 数据模型和服务
│       ├── ViewModels/        # 拆分后的 ObservableObject 状态
│       └── Views/             # UI 视图
├── orbit-rs/                  # Rust 核心，编译为静态库
│   ├── src/ffi.rs             # C ABI 导出函数
│   ├── src/ssh.rs             # SSH 会话和终端 channel 管理
│   ├── src/sftp.rs            # SFTP 操作
│   ├── src/transport.rs       # 直连和跳板机传输层
│   ├── src/db.rs              # SQLite 存储
│   └── include/orbit.h        # 生成的 C 头文件
├── scripts/                   # 构建、DMG、验证脚本
└── docs/                      # 发布、appcast 和设计文档
```

### 发布流程

预览版本使用类似 `v0.0.6-pre` 的 tag。

1. 更新 `orbit-app/project.yml` 中的版本字段。
2. 运行 `xcodegen generate` 重新生成 Xcode 工程。
3. 运行 `make build-dmg`。
4. 提交到 `develop`。
5. 创建并推送 release tag。
6. 创建 GitHub prerelease，并上传 Apple Silicon DMG。

GitHub Release 发布后，release workflow 也可以构建并上传 DMG。

### 安全说明

- 凭据使用 AES-256-GCM 本地加密。
- 当前加密密钥绑定本机 hostname；将数据库迁移到其他 Mac 后需要重新输入凭据。
- 预览版暂未 Apple 公证。
- 跳板机需要开启 `AllowTcpForwarding yes`。

### 已知限制

- 资源监控脚本面向 Linux 服务器，不适用于 macOS/BSD 主机。
- 当前主要发布 Apple Silicon arm64 构建。
- CI 中保留了 Developer ID 签名和公证占位，但需要 Apple Developer 凭据。

### 贡献

欢迎提交 Issue 和 Pull Request。

1. Fork 本仓库。
2. 创建功能分支：`git checkout -b feature/my-feature`。
3. 保持改动聚焦，并以 `project.yml` 作为 Xcode 配置的唯一源码。
4. 运行相关构建和测试命令。
5. 向 `develop` 分支提交 Pull Request。

架构说明、FFI 规范、构建命令和开发约定请参考 [AGENTS.md](AGENTS.md)。

### 许可证

Orbit 使用 [MIT License](LICENSE) 开源。
