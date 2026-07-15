# AGENTS.md

> Orbit 开发指南 — 新成员加入时请先阅读本文档。

## 项目简介

Orbit 是一款原生 macOS SSH 管理终端，面向需要管理多台 Linux 服务器的开发者与运维人员。支持跳板机（堡垒机）代理连接、本地 Shell、主题系统、资源监控等功能。

GitHub: https://github.com/ibreez3/orbit

## 技术栈

| 层 | 技术 | 说明 |
|---|------|------|
| 桌面框架 | SwiftUI + AppKit | 原生 macOS 应用 |
| 终端 | SwiftTerm | xterm-256color PTY，Metal GPU 渲染 |
| 图表 | Swift Charts | 资源监控趋势图 |
| 状态管理 | ObservableObject | SwiftUI 状态管理 |
| 后端 | Rust (orbit-core) | ssh2 crate 实现 SSH/SFTP，编译为 Apple Silicon 静态库 |
| FFI | C ABI (cbindgen) | Rust 通过 C 接口暴露给 Swift |
| 数据库 | SQLite (rusqlite) | bundled 模式，无需系统安装 |
| 加密 | aes-gcm | AES-256-GCM 凭据加密 |
| 项目生成 | XcodeGen | project.yml → .xcodeproj |

## 环境要求

- macOS 13.0+
- Xcode 15+
- Rust >= 1.77（通过 rustup 安装）
- rustup target: `aarch64-apple-darwin`
- xcodegen（`brew install xcodegen`）

## 常用命令

```bash
# 构建 Rust Apple Silicon 静态库（首次或修改 Rust 代码后）
./scripts/build-rust.sh

# 构建 Release app，并验证签名与关键权限
make build-app

# 构建本地 DMG，并验证挂载后的 app
make build-dmg DMG_PATH=release/Orbit-local-AppleSilicon.dmg VOLUME_NAME="Orbit"

# 重新生成 Xcode 工程（添加/删除源文件后、修改 project.yml 后）
cd orbit-app && xcodegen generate && cd ..

# 开发模式 — 在 Xcode 中 Cmd+R 运行
open orbit-app/Orbit.xcodeproj

# 命令行构建 Release
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build

# 命令行构建 arm64
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release -arch arm64 build
```

## 发布流程（Agent / 维护者）

预览版本使用类似 `v0.0.6-pre` 的 tag。

1. 更新 `orbit-app/project.yml` 中的版本字段。
2. 运行 `cd orbit-app && xcodegen generate && cd ..` 重新生成 Xcode 工程。
3. 运行本地验证，例如 `make build-app` 和 Rust 测试。
4. 提交到 `develop` 并推送分支。
5. 创建并推送 release tag。
6. 创建 GitHub prerelease，只填写 release notes。
7. 交给 `Release DMG` GitHub Action 构建、验证并上传 Apple Silicon DMG。

不要把本地构建的 DMG 上传到 GitHub Releases。本地 DMG 仅用于冒烟验证。

## 项目结构

```
orbit/
├── AGENTS.md                          # 本文件
├── TODO.md                            # 待办事项
├── .gitignore
├── Makefile                           # build-rs / build-app / build-dmg 快捷命令
│
├── orbit-app/                         # ===== 前端 (Swift/SwiftUI) =====
│   ├── project.yml                    # xcodegen 项目配置（源码级）
│   ├── Orbit.xcodeproj/              # Xcode 工程（由 xcodegen 生成）
│   └── Orbit/
│       ├── OrbitApp.swift            # @main 入口 + 菜单命令
│       ├── AppDelegate.swift         # 应用生命周期
│       ├── OrbitBridge.swift         # FFI 桥接层（所有 C API 调用）
│       ├── Orbit-Bridging-Header.h   # Swift/C 桥接头文件
│       ├── Orbit.entitlements        # 代码签名权限
│       ├── Models/
│       │   ├── Models.swift          # 核心数据模型
│       │   ├── LocalShell.swift      # 本地 Shell 进程管理
│       │   └── OrbitConfig.swift     # 持久化应用配置
│       ├── ViewModels/
│       │   └── AppState.swift        # 全局状态管理 (ObservableObject)
│       ├── Views/
│       │   ├── MainView.swift        # 根布局：侧栏 + Tab 栏 + 内容区
│       │   ├── HomeView.swift        # 首页欢迎视图
│       │   ├── TerminalView.swift    # SSH 终端（SwiftTerm）
│       │   ├── OrbitTerminalView.swift  # 终端封装视图
│       │   ├── QuickTerminal.swift   # 快速终端浮层
│       │   ├── MonitorView.swift     # 资源监控面板 + 趋势图
│       │   ├── SftpView.swift        # SFTP 文件浏览器
│       │   ├── SftpDrawerView.swift  # SFTP 侧栏抽屉
│       │   ├── DatabaseView.swift    # 数据库管理面板
│       │   ├── SettingsView.swift    # 设置面板（含主题选择）
│       │   ├── SplitPaneView.swift   # 分栏布局容器
│       │   ├── SpotlightView.swift   # 命令面板/快速导航
│       │   ├── TabBarView.swift      # Tab 标签栏
│       │   ├── StatusBarView.swift   # 状态栏视图
│       │   ├── ServerDialog.swift    # 服务器添加/编辑弹窗
│       │   ├── CredentialGroupDialog.swift  # 凭据分组弹窗
│       │   └── TextEditorView.swift  # 文本编辑器视图
│       └── Themes/                   # 主题配色文件
│           ├── dark.orbit-theme
│           ├── light.orbit-theme
│           ├── nord.orbit-theme
│           ├── dracula.orbit-theme
│           ├── gruvbox-dark.orbit-theme
│           ├── catppuccin-mocha.orbit-theme
│           ├── solarized-dark.orbit-theme
│           └── tokyo-night.orbit-theme
│
├── orbit-rs/                          # ===== 后端 (Rust) =====
│   ├── Cargo.toml                    # Rust 依赖
│   ├── build.rs                      # cbindgen 构建脚本
│   ├── cbindgen.toml                 # C 头文件生成配置
│   ├── include/
│   │   └── orbit.h                   # 自动生成的 C 头文件
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
│   └── build-rust.sh                 # Rust Apple Silicon 静态库构建脚本
│
└── docs/                             # 文档/设计稿
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

### 静态库构建与链接

Rust 编译为 Apple Silicon 静态库（arm64），由 Xcode 直接链接：

```
build-rust.sh 流程:
  1. cargo build --release --target aarch64-apple-darwin  (arm64)
  2. find 查找 C 依赖的 .a 文件 (sqlite3, ssh2, ssl, crypto)
  3. 复制 arm64 静态库放入 target/apple-silicon-apple-darwin/release/

project.yml 通过 OTHER_LDFLAGS 绝对路径链接:
  - $(PROJECT_DIR)/../orbit-rs/target/apple-silicon-apple-darwin/release/liborbit_core.a
  - $(PROJECT_DIR)/../orbit-rs/target/apple-silicon-apple-darwin/release/libsqlite3.a
  - $(PROJECT_DIR)/../orbit-rs/target/apple-silicon-apple-darwin/release/libssh2.a
  - $(PROJECT_DIR)/../orbit-rs/target/apple-silicon-apple-darwin/release/libssl.a
  - $(PROJECT_DIR)/../orbit-rs/target/apple-silicon-apple-darwin/release/libcrypto.a
  - -lz -liconv -framework Security -framework SystemConfiguration
```

**注意**: 如果 `cargo clean` 清理了 build 缓存，`build-rust.sh` 中的 `find` 命令会找不到依赖库的 .a 文件（sqlite3、ssh2、ssl、crypto），因为这些文件在 `target/<arch>/release/build/` 下。此时需要重新 `cargo build` 生成它们。

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

### 终端组件生命周期

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

### 主题系统

主题文件位于 `orbit-app/Orbit/Themes/`，格式为 `.orbit-theme`，包含终端配色、UI 颜色等。用户在 SettingsView 中选择主题，AppState 负责加载和应用。

### 数据库

位置：`~/Library/Application Support/orbit/orbit.db`（macOS）

**servers** 表 — 服务器配置 | **credential_groups** 表 — 凭据分组

数据库迁移：`db.rs` 的 `new()` 中用 `ALTER TABLE ... ADD COLUMN` 处理升级。

## 开发规范

### 分支策略

- `main` 分支受保护（需要 PR + 1 个审批）
- 功能分支从 `main` 创建

### 代码风格

- **Rust**: `cargo build` 无 error
- **Swift**: Xcode build 无 error
- **不添加注释**，除非用户要求
- 使用已有的库，不引入新依赖除非必要
- `project.yml` 是 Xcode 工程配置的源码，不要手动编辑 `.pbxproj`
- 不要提交编译产物（`.dylib`、`.a`、`DerivedData` 等）

### 添加新 FFI 函数的步骤

1. `orbit-rs/src/ffi.rs` — 添加 `#[no_mangle] pub extern "C" fn orbit_xxx()`
2. `orbit-rs/src/lib.rs` — 如需新方法，添加到 `OrbitApp`
3. `orbit-rs/include/orbit.h` — `cargo build` 后由 cbindgen 自动重新生成
4. `orbit-app/Orbit/OrbitBridge.swift` — 添加对应的 Swift 包装方法
5. 如有新数据类型，在 `Orbit/Models/Models.swift` 添加 Codable 结构体

### 添加新 UI 组件的步骤

1. `orbit-app/Orbit/Views/` — 创建组件文件
2. 在 `MainView.swift` 或父组件中引入
3. 添加新的源文件后运行 `xcodegen generate` 重新生成工程
4. 如需全局状态，在 `AppState.swift` 添加

### 添加新文件的步骤

1. 创建源文件
2. 运行 `cd orbit-app && xcodegen generate` 重新生成 `.pbxproj`
3. 验证 `xcodebuild` 编译通过

## 常见问题

### 静态库架构不正确

`lipo -info orbit-rs/target/apple-silicon-apple-darwin/release/*.a` 检查所有 .a 是否为 arm64。如果某个库不是 arm64，重新运行 `./scripts/build-rust.sh`。

### cargo clean 后构建失败

`cargo clean` 会删除 `target/<arch>/release/build/` 下的 C 依赖编译产物（sqlite3、ssh2、ssl、crypto），导致 `build-rust.sh` 的 find 找不到这些文件。解决方案：直接运行 `./scripts/build-rust.sh`（它会在步骤 1/2 重新编译 Rust，从而重新生成这些依赖库）。

### project.pbxproj 手动修改被覆盖

不要手动编辑 `.pbxproj`。所有工程配置在 `project.yml` 中，通过 `xcodegen generate` 生成。

### ld warning: object file was built for newer 'macOS' version

这是正常的。OpenSSL 等 C 依赖用当前 SDK 编译，版本号高于 deployment target (13.0)，不影响运行。

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
