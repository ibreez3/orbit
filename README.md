<div align="center">

<img src="src-tauri/icons/128x128@2x.png" width="128" height="128" />

# Orbit

轻量级桌面 SSH 管理终端

[![Build & Release](https://github.com/ibreez3/orbit/actions/workflows/build.yml/badge.svg)](https://github.com/ibreez3/orbit/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[功能特性](#功能特性) · [快速开始](#快速开始) · [下载安装](#下载安装)

</div>

## 功能特性

- **SSH 终端** — 基于 xterm.js + WebGL 加速渲染，xterm-256color PTY，实时 I/O，窗口自适应
- **SFTP 文件管理** — 流式传输（32KB 分块），浏览、上传、下载、删除、新建文件夹
- **资源监控** — CPU / 内存 / 磁盘使用率 + 实时趋势图表（Recharts）
- **跳板机代理** — 通过堡垒机连接目标服务器，自动建立 TCP 转发隧道
- **SSH 连接池** — SFTP 和监控共享连接池，减少重复握手
- **凭据加密** — AES-256-GCM 加密存储密码和私钥
- **终端分屏** — 左右 / 上下分屏，同时查看多台服务器
- **多 Tab 管理** — 同时打开多个终端、SFTP、监控标签页，按需懒加载
- **服务器分组** — 拖拽排序，按分组组织服务器，支持折叠展开
- **凭据分组** — 共享认证信息，多台服务器复用同一套密码或密钥
- **多认证方式** — 密码认证 / 密钥认证（RSA / ED25519），支持粘贴内容或选择本地文件
- **连接测试** — 保存前可一键测试 SSH 连接是否正常
- **网络流量** — 状态栏实时显示 SSH 会话上行 / 下行速率
- **Catppuccin Mocha 主题** — 全局统一深色配色
- **日志系统** — Rust tracing 框架，文件 + 控制台双输出

## 技术栈

| 层 | 技术 |
|---|------|
| 桌面框架 | [Tauri 2](https://v2.tauri.app/) |
| 前端 | React 19 · TypeScript · [Tailwind CSS](https://tailwindcss.com/) |
| 终端 | [xterm.js](https://xtermjs.org/) + WebGL 加速 |
| 图表 | [Recharts](https://recharts.org/) |
| 状态管理 | [Zustand](https://zustand.docs.pmnd.rs/) |
| 后端 | Rust · [ssh2](https://crates.io/crates/ssh2) |
| 数据库 | SQLite ([rusqlite](https://crates.io/crates/rusqlite), bundled) |
| 加密 | [aes-gcm](https://crates.io/crates/aes-gcm) · AES-256-GCM |

## 快速开始

### 环境要求

- [Node.js](https://nodejs.org/) >= 18
- [Rust](https://www.rust-lang.org/tools/install) >= 1.77
- macOS: Xcode Command Line Tools
- Linux: `libwebkit2gtk-4.1-dev`, `libssl-dev`, `libssh2-1-dev`

### 安装 & 运行

```bash
git clone https://github.com/ibreez3/orbit.git
cd orbit
npm install
make dev
```

### 构建命令

| 命令 | 说明 |
|------|------|
| `make dev` | 开发模式（热重载） |
| `make debug` | Debug 构建 |
| `make build` | Release 构建（当前平台） |
| `make build-arm` | Apple Silicon 交叉编译（Debug） |
| `make clean` | 清理构建产物 |

构建产物位于 `src-tauri/target/release/bundle/`。

## 下载安装

从 [GitHub Releases](https://github.com/ibreez3/orbit/releases) 下载最新版本：

| 平台 | 文件 |
|------|------|
| macOS (Apple Silicon) | `.dmg` |
| macOS (Intel) | `.dmg` |
| Linux | `.deb` / `.AppImage` |

> **macOS 用户**：首次打开可能被 Gatekeeper 拦截，右键点击应用 → 「打开」即可。或在终端执行 `xattr -cr /Applications/Orbit.app`。

## 项目结构

```
├── src/                           # React 前端
│   ├── components/
│   │   ├── Sidebar/               # 服务器列表 + 分组 + 拖拽 + 右键菜单
│   │   ├── Terminal/              # xterm.js SSH 终端（WebGL 加速）
│   │   ├── Sftp/                  # SFTP 文件浏览器（流式传输）
│   │   ├── Monitor/               # 资源监控面板 + 趋势图
│   │   ├── ServerDialog/          # 服务器配置弹窗（含跳板机选择）
│   │   └── CredentialGroupDialog/ # 凭据分组弹窗
│   ├── stores/useAppStore.ts      # Zustand 全局状态
│   └── types/index.ts             # TypeScript 类型定义
├── src-tauri/                     # Rust 后端
│   └── src/
│       ├── lib.rs                 # Tauri Command 注册 + 日志初始化
│       ├── models.rs              # 数据模型 + 凭据解析 + expand_tilde
│       ├── db.rs                  # SQLite CRUD（加密读写）
│       ├── transport.rs           # 连接工厂 + 连接池（直连/跳板机）
│       ├── ssh.rs                 # SSH 会话管理 + 流量统计
│       ├── sftp.rs                # SFTP 流式文件操作
│       ├── crypto.rs              # AES-256-GCM 加密/解密
│       └── monitor.rs             # 资源监控数据采集
├── Makefile
└── .github/workflows/build.yml   # CI/CD: 多平台构建 + 自动发布
```

## 贡献

欢迎提交 Issue 和 Pull Request。

1. Fork 本仓库
2. 创建功能分支: `git checkout -b feature/my-feature`
3. 提交变更: `git commit -m 'Add some feature'`
4. 推送分支: `git push origin feature/my-feature`
5. 提交 Pull Request

## 开发文档

详细的开发指南请参考 [AGENTS.md](AGENTS.md)，包含架构设计、通信流程、数据库 Schema、开发规范等。

## 许可证

[MIT License](LICENSE)
