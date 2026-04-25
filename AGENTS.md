# AGENTS.md

> Orbit 开发指南 — 新成员加入时请先阅读本文档。

## 项目简介

Orbit 是一款基于 Tauri 2 + React 的桌面 SSH 管理终端，面向需要管理多台 Linux 服务器的开发者与运维人员。

GitHub: https://github.com/ibreez3/orbit

## 技术栈

| 层 | 技术 | 说明 |
|---|------|------|
| 桌面框架 | Tauri 2 | Rust 后端 + WebView 前端，体积远小于 Electron |
| 前端 | React 19 + TypeScript | Vite 构建 |
| 终端 | xterm.js | xterm-256color PTY |
| 图表 | Recharts | 资源监控趋势图 |
| 状态管理 | Zustand | 轻量 store，单文件管理全局状态 |
| 样式 | Tailwind CSS | Tokyo Night 配色主题 |
| 后端 | Rust | ssh2 crate 实现 SSH/SFTP |
| 数据库 | SQLite (rusqlite) | bundled 模式，无需系统安装 |
| 图标 | Lucide React | 统一图标库 |

## 环境要求

- Node.js >= 18
- Rust >= 1.77（通过 rustup 安装）
- macOS: Xcode Command Line Tools

## 常用命令

```bash
npm install          # 安装前端依赖
make dev             # 开发模式（热重载）
make debug           # Debug 构建（快，用于验证）
make build           # Release 构建
make build-arm       # Apple Silicon 交叉编译
make clean           # 清理构建产物
```

## 项目结构

```
ssh-manager/
├── AGENTS.md                      # 本文件
├── Makefile                       # 构建命令
├── app-icon.png                   # 应用图标 (1024x1024)
├── package.json
├── vite.config.ts
├── tailwind.config.js             # 主题配色定义
├── index.html
│
├── src/                           # ===== 前端 (React) =====
│   ├── main.tsx                   # React 入口
│   ├── App.tsx                    # 根组件：侧栏 + Tab 栏 + 内容区 + 弹窗
│   ├── index.css                  # Tailwind + 全局样式 + xterm 样式
│   ├── types/
│   │   └── index.ts               # 所有 TypeScript 类型定义
│   ├── stores/
│   │   └── useAppStore.ts         # Zustand 全局状态（服务器、Tab、凭据分组）
│   ├── components/
│   │   ├── Sidebar/
│   │   │   └── Sidebar.tsx        # 服务器列表 + 凭据分组管理 + 右键菜单
│   │   ├── Terminal/
│   │   │   └── TerminalTab.tsx     # xterm.js SSH 终端组件
│   │   ├── Sftp/
│   │   │   └── SftpPanel.tsx      # SFTP 文件浏览器
│   │   ├── Monitor/
│   │   │   └── MonitorPanel.tsx   # 资源监控面板 + 趋势图
│   │   ├── ServerDialog/
│   │   │   └── ServerDialog.tsx   # 服务器添加/编辑弹窗
│   │   └── CredentialGroupDialog/
│   │       └── CredentialGroupDialog.tsx  # 凭据分组弹窗
│
└── src-tauri/                     # ===== 后端 (Rust) =====
    ├── Cargo.toml                 # Rust 依赖
    ├── tauri.conf.json            # Tauri 配置（窗口、打包、安全策略）
    ├── build.rs                   # Tauri 构建脚本
    ├── capabilities/
    │   └── default.json           # Tauri 权限声明
    ├── icons/                     # 各尺寸应用图标
    └── src/
        ├── main.rs                # 程序入口
        ├── lib.rs                 # 所有 Tauri Command 注册 + 应用启动
        ├── models.rs              # 数据模型 + ResolvedAuth 凭据解析
        ├── db.rs                  # SQLite 数据库 CRUD（servers + credential_groups）
        ├── ssh.rs                 # SSH 会话管理（连接、读写、断开）
        ├── sftp.rs                # SFTP 文件操作（列表、上传、下载、删除）
        └── monitor.rs             # 资源监控脚本 + 输出解析
```

## 架构设计

### 前后端通信

前端通过 Tauri 的 `invoke` 调用后端 Command，通过 `listen` 接收后端事件：

```
前端 invoke("connect_ssh", { serverId })
  → 后端 Command connect_ssh()
    → 建立 SSH 连接，创建 shell channel
    → 启动线程读取 channel 输出
    → 通过 app_handle.emit("ssh-data-{id}", bytes) 发送到前端
  ← 返回 session_id

前端 listen("ssh-data-{id}", callback)
  → xterm.write(bytes)

前端 invoke("write_ssh", { sessionId, data })
  → 后端写入 SSH channel
```

### Tab 管理

- SSH 终端和 SFTP：每次操作创建新 Tab（`Date.now()` 生成唯一 ID），同一服务器可开多个
- 资源监控：每台服务器只允许一个 Monitor Tab，重复点击切换到已有 Tab

### 凭据解析流程

```
服务器连接请求
  → lib.rs: resolve_group()
    → 有 credential_group_id？加载 CredentialGroup
  → models.rs: ResolvedAuth::resolve()
    → auth_type == "password" → 跳过密钥解析
    → auth_type == "key" && key_source == "file" → 展开路径（~ → home） → 读取文件
    → auth_type == "key" && key_source == "content" → 直接使用内容
  → ResolvedAuth::authenticate()
    → ssh2 密码认证 或 密钥认证
```

### 数据库

位置：`~/Library/Application Support/orbit/orbit.db`（macOS）

两个表：

**servers** — 服务器配置

| 字段 | 说明 |
|------|------|
| id | UUID |
| name, host, port | 连接信息 |
| group_name | 服务器分组 |
| auth_type | "password" 或 "key" |
| username, password | 密码认证凭据 |
| private_key, key_source, key_file_path, key_passphrase | 密钥认证凭据 |
| credential_group_id | 关联的凭据分组 ID（空=使用自身凭据） |

**credential_groups** — 凭据分组（共享认证）

| 字段 | 说明 |
|------|------|
| id | UUID |
| name | 分组名 |
| auth_type, username, password | 认证信息 |
| private_key, key_source, key_file_path, key_passphrase | 密钥信息 |

数据库迁移：`db.rs` 的 `new()` 函数中用 `ALTER TABLE ... ADD COLUMN` 处理旧数据库升级，忽略 "列已存在" 错误。

## 开发规范

### 代码风格

- **Rust**: `cargo check` 无 error，warning 尽量清零
- **TypeScript**: `npx tsc --noEmit` 无 error
- **不添加注释**，除非用户要求
- 使用已有的库，不引入新依赖除非必要

### 主题配色

定义在 `tailwind.config.js`，所有组件统一使用这些 token：

```css
bg-primary     #1a1b26   主背景
bg-secondary   #24283b   侧栏/面板背景
bg-tertiary    #414868   hover 状态
border         #3b4261   边框
text-primary   #c0caf5   主文字
text-secondary #a9b1d6   次要文字
text-muted     #565f89   弱化文字
accent-blue    #7aa2f7   主强调色
accent-green   #9ece6a   在线/成功
accent-red     #f7768e   错误/删除
accent-yellow  #e0af68   编辑/警告
accent-cyan    #7dcfff   CPU/信息
accent-purple  #bb9af7   凭据分组
```

### 添加新 Tauri Command 的步骤

1. `src-tauri/src/lib.rs` — 添加 `#[tauri::command] async fn xxx()` 函数
2. 同文件的 `invoke_handler!` 宏中注册函数名
3. `src/types/index.ts` — 如有新数据类型，添加 TypeScript 接口
4. 前端通过 `invoke("xxx", { params })` 调用

### 添加新 UI 组件的步骤

1. `src/components/ComponentName/ComponentName.tsx` — 创建组件
2. `src/App.tsx` 或父组件中引入
3. 使用 Tailwind 类名 + 主题 token 编写样式
4. 如需全局状态，在 `src/stores/useAppStore.ts` 添加

## 已知限制

- 凭据明文存储在 SQLite（后续可改为 AES 加密或系统 keychain）
- SFTP 每次操作建立新 SSH 连接（后续可改为连接池）
- 监控数据通过 SSH 执行 shell 脚本采集（依赖 Linux，不兼容 macOS/BSD）
- Windows/Linux 构建未在本地验证（依赖 GitHub Actions CI）

## 发布流程

```bash
# 一键发版（自动更新版本号、提交、打 tag）
make release VERSION=0.0.1

# 推送代码和 tag 触发 CI 构建
git push origin main && git push origin v0.0.1
```

脚本会自动更新以下文件的版本号：`package.json`、`src-tauri/tauri.conf.json`、`src-tauri/Cargo.toml`

Release assets 命名格式：`Orbit_<OS>_<架构>_<版本>.<后缀>`
