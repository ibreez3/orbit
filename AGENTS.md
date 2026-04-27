# AGENTS.md

> Orbit 开发指南 — 新成员加入时请先阅读本文档。

## 项目简介

Orbit 是一款原生 macOS SSH 管理终端，面向需要管理多台 Linux 服务器的开发者与运维人员。支持跳板机（堡垒机）代理连接。

GitHub: https://github.com/ibreez3/orbit

## 技术栈

| 层 | 技术 | 说明 |
|---|------|------|
| 桌面框架 | SwiftUI + AppKit | 原生 macOS 应用 |
| 终端 | SwiftTerm | xterm-256color PTY，Metal GPU 渲染 |
| 图表 | Swift Charts | 资源监控趋势图 |
| 状态管理 | @Observable (SwiftUI) | 原生 Observation 框架 |
| 后端 | Rust (orbit-core) | ssh2 crate 实现 SSH/SFTP，编译为静态库 |
| FFI | C ABI (cbindgen) | Rust 通过 C 接口暴露给 Swift |
| 数据库 | SQLite (rusqlite) | bundled 模式，无需系统安装 |
| 加密 | aes-gcm | AES-256-GCM 凭据加密 |

## 环境要求

- macOS 14.0+
- Xcode 15+
- Rust >= 1.77（通过 rustup 安装）
- xcodegen（`brew install xcodegen`）

## 常用命令

```bash
# 构建 Rust 静态库（首次或修改 Rust 代码后）
./scripts/build-rust.sh

# 重新生成 Xcode 工程（添加/删除源文件后）
cd orbit-app && xcodegen generate && cd ..

# 开发模式 — 在 Xcode 中 Cmd+R 运行
open orbit-app/Orbit.xcodeproj

# 仅构建（命令行）
xcodebuild -project orbit-app/Orbit.xcodeproj -scheme Orbit -configuration Debug build
```

## 项目结构

```
orbit/
├── AGENTS.md                          # 本文件
├── TODO.md                            # 待办事项
├── .gitignore
├── LICENSE
├── app-icon.png                       # 应用图标
│
├── orbit-app/                         # ===== 前端 (Swift/SwiftUI) =====
│   ├── project.yml                    # xcodegen 项目配置
│   ├── Orbit.xcodeproj/              # Xcode 工程（由 xcodegen 生成）
│   └── Orbit/
│       ├── OrbitApp.swift            # @main 入口 + 菜单命令
│       ├── AppDelegate.swift         # 应用生命周期
│       ├── OrbitBridge.swift         # FFI 桥接层（所有 C API 调用）
│       ├── Orbit-Bridging-Header.h   # Swift/C 桥接头文件
│       ├── Models/
│       │   └── Models.swift          # 所有数据模型
│       ├── ViewModels/
│       │   └── AppState.swift        # 全局状态管理
│       └── Views/
│           ├── MainView.swift        # 根布局：侧栏 + Tab 栏 + 内容区
│           ├── SidebarView.swift     # 服务器列表 + 凭据分组 + 右键菜单
│           ├── TerminalView.swift    # SwiftTerm SSH 终端
│           ├── SftpView.swift        # SFTP 文件浏览器
│           ├── MonitorView.swift     # 资源监控面板 + 趋势图
│           ├── ServerDialog.swift    # 服务器添加/编辑弹窗
│           └── CredentialGroupDialog.swift  # 凭据分组弹窗
│
├── orbit-rs/                          # ===== 后端 (Rust) =====
│   ├── Cargo.toml                    # Rust 依赖
│   ├── build.rs                      # cbindgen 构建脚本
│   ├── cbindgen.toml                 # C 头文件生成配置
│   ├── include/
│   │   └── orbit.h                   # 自动生成的 C 头文件（27 个 FFI 函数）
│   └── src/
│       ├── lib.rs                    # OrbitApp 状态结构 + 日志初始化
│       ├── ffi.rs                    # 所有 #[no_mangle] extern "C" 导出函数
│       ├── models.rs                 # 数据模型 + 凭据解析
│       ├── db.rs                     # SQLite CRUD（加密写入、解密读取、自动迁移）
│       ├── transport.rs              # 连接工厂 + 连接池（直连/跳板机）
│       ├── ssh.rs                    # SSH 会话管理（连接、读写、断开）
│       ├── sftp.rs                   # SFTP 流式文件操作
│       ├── crypto.rs                 # AES-256-GCM 加密/解密
│       └── monitor.rs                # 资源监控脚本 + 输出解析
│
├── scripts/
│   └── build-rust.sh                 # Rust 静态库构建脚本
│
└── docs/                             # 博客/文档
```

## 架构设计

### 前后端通信（FFI）

Swift 通过 C ABI 调用 Rust，复杂数据通过 JSON 字符串传递：

```
Swift invoke OrbitBridge.connectSSH(serverId)
  → C ABI: orbit_connect_ssh(app, serverId, dataCallback, closedCallback, userdata)
  → Rust transport::create_session() 建立 SSH 连接
  → 启动读取线程
  → 读取线程通过 C 回调 → Swift orbitDataCallback → OrbitBridge.handleSSHData()
← 返回 session_id（C 字符串）
```

### 连接层（transport.rs）

所有 SSH 连接通过 `transport::create_session()` 统一创建：

```
create_session(server, db)
  → server.jump_server_id 为空？
    → 是：create_direct_session() — TcpStream → handshake → auth
    → 否：create_jump_session()
      → 先连跳板机 → TCP 转发隧道 → 本地代理线程 → 连接目标服务器
  ← 返回 SessionGuard { session, _proxy }
```

### 终端组件生命周期（TerminalView.swift）

```
NSViewRepresentable 创建 SwiftTerm.TerminalView
  → Coordinator.connect()
    → OrbitBridge.connectSSH() → orbit_connect_ssh() (FFI)
    → 注册 sshDataHandlers[sessionId] / sshClosedHandlers[sessionId]
    → Rust 读取线程通过 C 回调发送数据
    → Handler 调用 tv.feed(byteArray:) 写入终端
  → Coordinator.send() — 用户输入 → OrbitBridge.writeSSH()
  → Coordinator.sizeChanged() — 终端尺寸变化 → OrbitBridge.resizeSSH()
```

### 凭据加密（crypto.rs）

```
加密：encrypt(plaintext) → "ORB1" + nonce + AES-256-GCM 密文 → Base64
解密：decrypt(ciphertext) → Base64 解码 → 检查 "ORB1" 前缀 → 解密
密钥：SHA256(salt + hostname)，绑定本机
```

### 数据库

位置：`~/Library/Application Support/orbit/orbit.db`（macOS）

**servers** 表 — 服务器配置 | **credential_groups** 表 — 凭据分组

数据库迁移：`db.rs` 的 `new()` 中用 `ALTER TABLE ... ADD COLUMN` 处理升级。

## 开发规范

### 分支策略

- `main` 分支受保护（需要 PR + 1 个审批）
- 开发在 `develop` 分支进行
- 功能分支从 `develop` 创建

### 代码风格

- **Rust**: `cargo check` 无 error
- **Swift**: Xcode build 无 error
- **不添加注释**，除非用户要求
- 使用已有的库，不引入新依赖除非必要

### 添加新 FFI 函数的步骤

1. `orbit-rs/src/ffi.rs` — 添加 `#[no_mangle] pub extern "C" fn orbit_xxx()`
2. `orbit-rs/src/lib.rs` — 如需新方法，添加到 `OrbitApp`
3. `orbit-rs/include/orbit.h` — 由 `cargo build` 自动重新生成
4. `orbit-app/Orbit/OrbitBridge.swift` — 添加对应的 Swift 包装方法
5. 如有新数据类型，在 `Orbit/Models/Models.swift` 添加 Codable 结构体

### 添加新 UI 组件的步骤

1. `orbit-app/Orbit/Views/` — 创建组件文件
2. 在 `MainView.swift` 或父组件中引入
3. 运行 `xcodegen generate` 重新生成工程
4. 如需全局状态，在 `AppState.swift` 添加

### 主题配色（Catppuccin Mocha）

终端配色硬编码在 `TerminalView.swift` 的 `catppuccin` 数组中。

## 已知限制

- 凭据加密密钥绑定本机 hostname，换机器需重新输入凭据
- 监控数据通过 SSH 执行 shell 脚本采集（依赖 Linux，不兼容 macOS/BSD）
- 跳板机依赖 `AllowTcpForwarding yes`
- macOS 未签名，需右键打开或 `xattr -cr` 绕过 Gatekeeper

## 数据文件位置（macOS）

| 文件 | 路径 |
|------|------|
| 数据库 | `~/Library/Application Support/orbit/orbit.db` |
| 日志 | `~/Library/Application Support/orbit/orbit.log` |
