# Orbit Windows

Windows 客户端使用 Tauri 2、React、TypeScript 和 xterm.js，直接调用共享的 `orbit-core` Rust API。macOS 继续使用原生 SwiftUI/AppKit 和现有 C ABI。

## 当前范围

- 工作台沿用 macOS 的顶部快速连接、资产树、标签栏、最近连接首页、右侧工具栏与状态栏。
- 服务器与凭据管理、目录/标签、临时连接；SSH 多标签和本地 PowerShell、双分屏、终端搜索。
- SFTP 浏览、上传/下载/取消、覆盖确认、目录及文本编辑；Linux 资源监控。
- 数据库、命令片段、批量执行、端口转发；AI 流式聊天和确认执行；Windows Agent 网关与 CLI/MCP。
- 分类设置、共享内置主题文件、主题预览、自定义主题、字体与连接配置、配置导入导出。
- 本地 `orbit.key` 文件保存 AES-GCM 主密钥，并使用仅所有者和 SYSTEM 可访问的 ACL；列表不返回凭据；终端按原始字节传输并限制未消费输出量。

当前为开发版。已实现不等于已完整验收：Windows 真机已验证 PowerShell、分屏、主题、Linux SSH/SFTP/监控、SQLite 查询及备份恢复；其他业务面板的 UI、Agent 协议、真实 AI、MySQL/PostgreSQL 与自动更新尚未全部对齐。逐项状态见 [Windows 功能对齐验收](../docs/windows-parity.md)。

## Windows 开发环境

- Git、Node.js LTS（已验证 24.x）、Rust stable MSVC x64。
- Visual Studio 2022 Build Tools：C++ 桌面开发、Windows SDK、CMake、C++ Clang 工具。
- Strawberry Perl（vendored OpenSSL 构建需要）。
- Microsoft Edge WebView2 Runtime。

在仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build-windows.ps1 -Test
```

脚本载入 MSVC 环境、安装锁定的 npm 依赖、运行核心测试并生成 `orbit-windows/src-tauri/target/release/orbit-windows.exe`。加 `-Bundle` 生成 NSIS 安装包；安装包尚未签名。执行策略仅对该进程生效。

需要代理时，在同一 PowerShell 进程中设置：

```powershell
$env:HTTP_PROXY = 'http://192.168.0.3:7890'
$env:HTTPS_PROXY = $env:HTTP_PROXY
```

开发热更新：先打开 VS 的 x64 Native Tools 命令提示符，确保 Perl、CMake、Node.js 与 Rust 在 PATH 中，并设置 `LIBCLANG_PATH` 到 VS 的 `VC\Tools\Llvm\x64\bin`；然后在 `orbit-windows` 目录运行 `npm ci` 和 `npm run tauri dev`。

数据保存在 `%LOCALAPPDATA%\com.orbit.terminal.windows\orbit.db`。密钥文件 `orbit.key` 位于同一目录，备份或迁移需同时包含该文件。旧版本的系统密钥只在首次迁移时读取，详见 [凭据迁移](../docs/credentials-and-sftp.md)。

## 验证

```powershell
cargo test --manifest-path orbit-rs/Cargo.toml --lib
cargo test --manifest-path orbit-rs/Cargo.toml credential_file::tests
```

第二条使用临时目录验证文件密钥的创建、迁移、重开及防覆盖行为。

首次迁移旧 Credential Manager 密钥应在已登录的 Windows 桌面会话运行；新安装及迁移完成后，核心不再依赖该登录会话读取密钥。

`orbit-rs/examples/desktop_smoke.rs` 从标准输入读取一行 JSON 配置，验证真实 SSH 输入/输出、尺寸、主机指纹确认、数据库重开和 SFTP UTF-8 文件往返。使用专用测试目录与明确核验过的指纹；不要将密码写入命令参数或版本库。

前端测试需本机 Chrome：在 `orbit-windows` 运行 `npm test`。这些测试模拟 Tauri IPC，覆盖标签生命周期、保存服务器、主机指纹拒绝和目录浏览；不能替代 Windows WebView2 真机验收。中文输入法、高 DPI、全屏 TUI 和长时间大量输出仍需真机交互验收。
