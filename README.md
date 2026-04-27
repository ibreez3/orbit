<div align="center">

<img src="app-icon.png" width="128" height="128" />

# Orbit

原生 macOS SSH 管理终端

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[功能特性](#功能特性) · [快速开始](#快速开始)

</div>

## 功能特性

- **SSH 终端** — 基于 SwiftTerm，xterm-256color PTY，Metal GPU 渲染，Catppuccin Mocha 主题
- **SFTP 文件管理** — 浏览、上传、下载、删除、新建文件夹，进度条显示
- **资源监控** — CPU / 内存 / 磁盘使用率 + Swift Charts 实时趋势图，自动刷新
- **跳板机代理** — 通过堡垒机连接目标服务器，自动建立 TCP 转发隧道
- **凭据加密** — AES-256-GCM 加密存储密码和私钥，绑定本机
- **多 Tab 管理** — 同时打开多个终端、SFTP、监控标签页
- **服务器分组** — 按分组组织服务器，支持折叠展开
- **凭据分组** — 共享认证信息，多台服务器复用同一套密码或密钥
- **多认证方式** — 密码 / 密钥认证（粘贴内容或选择本地文件）
- **连接测试** — 保存前可一键测试 SSH 连接是否正常

## 技术栈

| 层 | 技术 |
|---|------|
| 前端 | SwiftUI · AppKit · SwiftTerm · Swift Charts |
| 后端 | Rust · ssh2 · rusqlite · aes-gcm |
| FFI | C ABI (cbindgen) — Rust 编译为静态库供 Swift 调用 |

## 快速开始

### 环境要求

- macOS 14.0+
- [Xcode](https://developer.apple.com/xcode/) 15+
- [Rust](https://www.rust-lang.org/tools/install) >= 1.77
- xcodegen（`brew install xcodegen`）

### 安装 & 运行

```bash
git clone https://github.com/ibreez3/orbit.git
cd orbit

# 构建 Rust 静态库
./scripts/build-rust.sh

# 生成 Xcode 工程并运行
cd orbit-app && xcodegen generate && cd ..
open orbit-app/Orbit.xcodeproj
# 在 Xcode 中 Cmd+R 运行
```

## 项目结构

```
├── orbit-app/                     # SwiftUI 前端
│   ├── project.yml                # xcodegen 项目配置
│   └── Orbit/
│       ├── OrbitApp.swift         # @main 入口
│       ├── OrbitBridge.swift      # FFI 桥接层
│       ├── Models/Models.swift    # 数据模型
│       ├── ViewModels/AppState.swift  # 全局状态
│       └── Views/                 # UI 组件
├── orbit-rs/                      # Rust 后端（编译为静态库）
│   ├── src/ffi.rs                 # C ABI 导出函数
│   ├── src/ssh.rs                 # SSH 会话管理
│   ├── src/sftp.rs                # SFTP 文件操作
│   ├── src/db.rs                  # SQLite CRUD
│   ├── src/transport.rs           # 连接工厂 + 跳板机
│   ├── src/crypto.rs              # AES-256-GCM 加密
│   └── include/orbit.h            # 自动生成的 C 头文件
├── scripts/build-rust.sh          # Rust 构建脚本
└── docs/                          # 文档
```

## 贡献

欢迎提交 Issue 和 Pull Request。

1. Fork 本仓库
2. 创建功能分支: `git checkout -b feature/my-feature`
3. 提交变更: `git commit -m 'Add some feature'`
4. 推送分支: `git push origin feature/my-feature`
5. 提交 Pull Request

## 开发文档

详细的开发指南请参考 [AGENTS.md](AGENTS.md)，包含架构设计、FFI 通信流程、数据库 Schema、开发规范等。

## 许可证

[MIT License](LICENSE)
