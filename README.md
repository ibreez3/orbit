<div align="center">

<img src="src-tauri/icons/128x128@2x.png" width="128" height="128" />

# Orbit

轻量级桌面 SSH 管理终端

[![CI](https://github.com/sunyangorg/orbit/actions/workflows/build.yml/badge.svg)](https://github.com/sunyangorg/orbit/actions/workflows/build.yml)

</div>

## 简介

Orbit 是一款基于 **Tauri 2 + React** 构建的桌面 SSH 管理客户端，专为需要管理多台 Linux 服务器的开发者与运维人员设计。

## 功能特性

| 功能 | 说明 |
|------|------|
| **SSH 终端** | 基于 xterm.js，支持 xterm-256color、实时 I/O、窗口自适应 |
| **多认证方式** | 支持密码认证和密钥认证（RSA / ED25519），按服务器独立配置 |
| **SFTP 文件管理** | 浏览、上传、下载、删除、新建文件夹 |
| **资源监控** | CPU / 内存 / 磁盘使用率 + 实时趋势图表，支持自动刷新 |
| **多 Tab 管理** | 同时打开多个终端、SFTP、监控标签页 |
| **服务器分组** | 按分组组织服务器，支持折叠展开 |
| **连接测试** | 保存前可测试 SSH 连接是否正常 |

## 截图

> *将在后续版本中补充*

## 技术栈

- **前端**: React 19 · TypeScript · Tailwind CSS · xterm.js · Recharts · Zustand
- **后端**: Rust · Tauri 2 · ssh2 · SQLite (rusqlite)
- **主题**: Tokyo Night

## 快速开始

### 环境要求

- [Node.js](https://nodejs.org/) >= 18
- [Rust](https://www.rust-lang.org/tools/install) >= 1.77
- [Tauri 2 CLI](https://v2.tauri.app/start/prerequisites/)

### 安装依赖

```bash
cd ssh-manager
npm install
```

### 开发模式

```bash
npm run tauri dev
```

### 构建生产版本

```bash
# 当前平台
npm run tauri build

# Apple Silicon (交叉编译)
npm run tauri build -- --target aarch64-apple-darwin
```

构建产物位于 `src-tauri/target/release/bundle/`。

## 项目结构

```
ssh-manager/
├── src/                          # React 前端
│   ├── components/
│   │   ├── Sidebar/              # 服务器列表 + 右键菜单
│   │   ├── Terminal/             # xterm.js SSH 终端
│   │   ├── Sftp/                 # SFTP 文件浏览器
│   │   ├── Monitor/              # 资源监控面板
│   │   └── ServerDialog/         # 服务器配置对话框
│   ├── stores/useAppStore.ts     # Zustand 状态管理
│   └── types/index.ts            # TypeScript 类型定义
├── src-tauri/
│   ├── src/
│   │   ├── lib.rs                # Tauri 命令注册 + 应用入口
│   │   ├── db.rs                 # SQLite 数据库操作
│   │   ├── ssh.rs                # SSH 会话管理
│   │   ├── sftp.rs               # SFTP 文件操作
│   │   └── monitor.rs            # 资源监控数据采集
│   ├── Cargo.toml
│   └── tauri.conf.json
├── package.json
└── vite.config.ts
```

## 支持平台

| 平台 | 架构 | 状态 |
|------|------|------|
| macOS | x86_64 (Intel) | ✅ |
| macOS | aarch64 (Apple Silicon) | ✅ |
| Linux | x86_64 | 🔄 |
| Windows | x86_64 | 🔄 |

## 许可证

MIT License
