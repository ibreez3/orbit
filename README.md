<div align="center">

<img src="app-icon.png" width="128" height="128" />

# Orbit

原生 macOS SSH 管理终端

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[功能特性](#功能特性) · [下载安装](#下载安装) · [使用说明](#使用说明) · [快速开始](#快速开始)

</div>

## 功能特性

- **SSH 终端** — 基于 SwiftTerm，xterm-256color PTY，Metal GPU 渲染，Catppuccin Mocha 主题
- **SFTP 文件管理** — 浏览、上传、下载、删除、新建文件夹，右键菜单支持重命名、文本编辑
- **远程文本编辑** — 双击文本文件直接打开编辑器，修改后一键保存到服务器
- **资源监控** — CPU / 内存 / 磁盘使用率 + Swift Charts 实时趋势图，支持自动刷新
- **跳板机代理** — 通过堡垒机连接目标服务器，自动建立 TCP 转发隧道
- **凭据加密** — AES-256-GCM 加密存储密码和私钥，绑定本机
- **多 Tab 管理** — 同时打开多个终端、SFTP、监控标签页
- **服务器分组** — 按分组组织服务器，支持折叠展开
- **凭据分组** — 共享认证信息，多台服务器复用同一套密码或密钥
- **多认证方式** — 密码 / 密钥认证（粘贴内容或选择本地文件）
- **连接测试** — 保存前可一键测试 SSH 连接是否正常
- **Apple Silicon 原生** — 面向 M 系列芯片构建 arm64 二进制

## 下载安装

### 从 Release 下载（推荐）

前往 [Releases](https://github.com/ibreez3/orbit/releases) 页面下载最新版本：

| 文件 | 说明 |
|------|------|
| `Orbit.dmg` | DMG 安装包，双击打开拖拽到 Applications |
| `Orbit.zip` | ZIP 压缩包，解压后拖拽到 Applications |

### 首次打开

应用未经过 Apple 公证，首次打开需要：

1. 双击 `Orbit.dmg`，将 Orbit 拖入 Applications
2. 右键点击 Orbit → 选择「打开」→ 在弹窗中再次点击「打开」

或者在终端执行：

```bash
xattr -cr /Applications/Orbit.app
```

## 使用说明

### 1. 添加服务器

1. 点击左上角 **「+ 添加服务器」**
2. 填写服务器信息：
   - **名称**：自定义显示名称
   - **主机地址**：IP 或域名
   - **端口**：SSH 端口，默认 22
   - **用户名**：登录用户名
   - **认证方式**：密码或密钥
   - **分组**：可选，将服务器归类到不同分组
3. 点击 **「测试连接」** 验证配置是否正确
4. 点击 **「保存」**

### 2. SSH 终端

- 在侧栏点击服务器旁的 **终端图标**（或右键 → 打开终端）打开 SSH 连接
- 支持多个终端 Tab 同时运行
- 终端使用 Catppuccin Mocha 配色主题
- 支持常见的终端快捷键操作

### 3. SFTP 文件管理

- 点击服务器旁的 **SFTP 图标** 打开文件浏览器
- **双击文件夹** 进入目录，点击路径栏的目录名可快速跳转
- **右键菜单** 操作：
  - **下载**：将文件下载到本地
  - **重命名**：修改文件或文件夹名称
  - **编辑**：打开内置文本编辑器（仅限文本文件）
  - **删除**：删除文件或文件夹
- 工具栏按钮支持：上传文件、新建文件夹、删除

### 4. 远程文本编辑

- 在 SFTP 中右键文本文件（如 `.py`、`.json`、`.yaml`、`.sh`、`.conf` 等）选择 **「编辑」**
- 编辑器在独立窗口中打开，支持：
  - 等宽字体显示
  - 修改后点击 **「保存」** 或按 **⌘S** 直接保存到远程服务器
  - 保存成功后窗口自动关闭
- 支持的文件类型：60+ 种扩展名，包括常见编程语言、配置文件、Markdown 等

### 5. 资源监控

- 点击服务器旁的 **监控图标** 打开资源面板
- 显示内容：
  - **CPU 使用率**：实时百分比
  - **内存使用**：已用 / 总量 / 百分比
  - **磁盘使用**：已用 / 总量 / 百分比
  - **系统信息**：主机名、内核版本、运行时间、负载
- 开启 **「自动刷新」** 后每 3 秒更新一次数据，并显示趋势图表

### 6. 跳板机连接

1. 先添加跳板机服务器（正常添加，作为独立服务器）
2. 编辑目标服务器，在 **「跳板机」** 字段选择已添加的跳板机
3. 连接时自动通过跳板机建立 TCP 转发隧道到达目标服务器
4. 要求跳板机开启 `AllowTcpForwarding yes`

### 7. 凭据分组

- 点击侧栏底部 **「凭据分组」** 管理共享凭据
- 创建凭据分组后，多台服务器可以复用同一套密码或密钥
- 编辑服务器时在「凭据分组」字段选择即可关联

### 8. 快捷操作

| 操作 | 方式 |
|------|------|
| 打开终端 | 点击服务器旁终端图标，或右键服务器 |
| 打开 SFTP | 点击服务器旁 SFTP 图标，或右键服务器 |
| 打开监控 | 点击服务器旁监控图标，或右键服务器 |
| 保存文件 | 编辑器中按 ⌘S |
| 关闭 Tab | 点击 Tab 上的 × 按钮 |

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

# 构建 Rust 静态库（Apple Silicon / arm64）
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
│           ├── MainView.swift     # 根布局
│           ├── SidebarView.swift  # 侧栏
│           ├── TerminalView.swift # SSH 终端
│           ├── SftpView.swift     # SFTP 文件管理
│           ├── MonitorView.swift  # 资源监控
│           ├── TextEditorView.swift # 远程文本编辑器
│           ├── ServerDialog.swift # 服务器配置弹窗
│           └── CredentialGroupDialog.swift
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
