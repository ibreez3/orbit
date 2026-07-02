<div align="center">

<img src="app-icon.png" width="128" height="128" alt="Orbit app icon" />

# Orbit

原生 macOS SSH 管理终端，面向开发者与运维人员。

[![Release](https://img.shields.io/github/v/release/ibreez3/orbit?include_prereleases&label=release)](https://github.com/ibreez3/orbit/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#环境要求)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black)](#从源码构建)

[English](README.md)

</div>

---

Orbit 是一款原生 macOS SSH 管理终端，基于 SwiftUI、AppKit、SwiftTerm 和 Rust SSH/SFTP 核心构建。它面向需要管理多台 Linux 服务器的开发者与运维人员，把 SSH 终端、SFTP、资源监控、命令片段、跳板机和凭据管理整合到一个专注的桌面应用里。

当前预览版本：**v0.0.6-pre**

## 功能特性

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

## 截图

仓库暂未提交截图。欢迎贡献能展示主要工作流的截图或简短演示 GIF。

## 环境要求

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

## 安装

前往 [GitHub Releases](https://github.com/ibreez3/orbit/releases) 下载最新预览版本。

| 文件 | 说明 |
| --- | --- |
| `Orbit-v*-AppleSilicon.dmg` | 推荐的 Apple Silicon 安装包 |
| `Orbit*.zip` | 可用时提供的压缩包 |

Orbit 预览版已本地签名，但暂未 Apple 公证。首次打开时，请右键点击 `Orbit.app`，选择「打开」，然后确认。也可以在终端执行：

```bash
xattr -cr /Applications/Orbit.app
```

## 从源码构建

```bash
git clone https://github.com/ibreez3/orbit.git
cd orbit

# 构建 Rust arm64 静态库
./scripts/build-rust.sh

# 生成 Xcode 工程、构建 Release，并验证签名和关键权限
make build-app

# 打开 Xcode 工程进行开发
open orbit-app/Orbit.xcodeproj
```

常用命令：

```bash
cd orbit-app && xcodegen generate && cd ..
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release -arch arm64 build
cargo test --manifest-path orbit-rs/Cargo.toml --release --target aarch64-apple-darwin
```

## 项目结构

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
├── scripts/                   # 构建和验证脚本
└── docs/                      # appcast 和设计文档
```

## 安全说明

- 凭据使用 AES-256-GCM 本地加密。
- 当前加密密钥绑定本机 hostname；将数据库迁移到其他 Mac 后需要重新输入凭据。
- 预览版暂未 Apple 公证。
- 跳板机需要开启 `AllowTcpForwarding yes`。

## 已知限制

- 资源监控脚本面向 Linux 服务器，不适用于 macOS/BSD 主机。
- 当前主要发布 Apple Silicon arm64 构建。

## 贡献

欢迎提交 Issue 和 Pull Request。

1. Fork 本仓库。
2. 创建功能分支：`git checkout -b feature/my-feature`。
3. 保持改动聚焦，并以 `project.yml` 作为 Xcode 配置的唯一源码。
4. 运行相关构建和测试命令。
5. 向 `develop` 分支提交 Pull Request。

架构说明、FFI 规范、构建命令和开发约定请参考 [AGENTS.md](AGENTS.md)。

## 许可证

Orbit 使用 [MIT License](LICENSE) 开源。
