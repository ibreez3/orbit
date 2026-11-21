# Windows 自动更新

Windows 使用 Tauri updater + NSIS；macOS 继续使用 Sparkle。应用标识始终为 `com.orbit.terminal.windows`，安装目录与应用数据目录分离。

## 客户端流程

默认在启动后检查稳定更新，设置 → 关于提供手动检查及自动检查开关。发现新版本后展示版本号和更新说明；点击下载后显示进度并校验签名。只有下载、校验成功才提供“安装并重启”。安装前提示完成命令、传输并保存编辑内容。Windows 安装程序完成后自动重启；失败保留错误信息和重试入口。

更新地址固定为 `https://raw.githubusercontent.com/ibreez3/orbit/develop/docs/windows-update.json`。该文件由发布流水线在安装包上传成功后生成。首次发布前此地址可能返回 404，手动检查会显示错误；后台检查失败不弹窗打断工作。

升级保留 `%LOCALAPPDATA%\com.orbit.terminal.windows` 下的 SQLite 数据库、凭据密钥文件及 WebView2 用户数据。不要修改应用 identifier、清空此目录或采用卸载后重装的升级方式。旧版 0.1.0 没有更新客户端，需先手动安装带更新功能的版本一次。

## 签名与发布

- `orbit-windows/src-tauri/tauri.conf.json` 内置更新签名公钥；私钥不得进入 Git、安装包、日志或文档。
- Actions Secret `WINDOWS_UPDATER_PRIVATE_KEY` 保存 Tauri 签名私钥；加密私钥时另设 `WINDOWS_UPDATER_KEY_PASSWORD`。
- 本地构建通过 `TAURI_SIGNING_PRIVATE_KEY` 指向私钥文件（或私钥内容），必要时设置 `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`，再运行 `scripts/build-windows.ps1 -Bundle`。
- 每次发布同步更新 `orbit-windows/package.json`、`package-lock.json`、`src-tauri/Cargo.toml`、`Cargo.lock`、`tauri.conf.json` 的应用版本。版本必须与发布 tag 去掉 `v` 后完全一致，且高于已发布的 Windows 版本。两端统一稳定版本为 `v0.1.3`，高于 Windows 验收版本 0.1.2。与 macOS 联合发布还需遵守 macOS 的版本/build 规则。
- 同一次 Release published 同时触发 macOS `Release DMG` 和 Windows `Release Windows`。两条流水线按平台使用独立并发组，可在 macOS runner 和 Windows runner 上并行构建；同平台的发布仍串行执行。两端上传不同名称的资产到同一个 Release，分别更新 appcast 与 Windows 清单；并发推送 develop 时会先 rebase 再重试。实际并行启动时间取决于 runner 是否空闲。
- `.github/workflows/release-windows.yml` 响应 Release published，或手动输入已有 tag。流水线验证版本、运行前端测试、构建 NSIS 与 `.sig`，上传版本专属 EXE、签名和 `windows-update.json`。已有资产不会覆盖，防止相同版本被重签或替换。
- 稳定 tag 成功上传后才更新 develop 的稳定清单；预览 tag 仅上传 Release 资产，不进入稳定更新通道。新旧版本比较防止旧工作流把清单回退。稳定清单更新失败时，现有客户端仍停留在上一版，可修复权限后发布更高版本。
- Release 正文不能为空，作为客户端更新说明。GitHub Latest 标记不控制 Windows 通道。
- 应备份私钥；更换公钥会中断旧客户端升级链，需要用旧密钥签发包含新公钥的过渡版本。

Tauri 更新签名用于安装包完整性与来源验证，不等同于 Windows Authenticode 发布者签名。当前未配置商业代码签名证书，Windows 仍可能显示未知发布者或 SmartScreen 提示。接入证书后，应先完成 EXE/安装包 Authenticode 签名，再生成 updater 签名，不能事后修改已签名资产。

## 验收标准

1. 旧版创建连接、保存密码与凭据组、修改主题和字体，记录数据库/密钥/设置状态。
2. 自动检查、手动检查、无更新、网络失败均符合预期；关掉自动检查后重启不发起检查。
3. 错误签名或损坏下载不能进入安装阶段，不改变已安装应用和数据。
4. 通过应用下载签名新版，确认后执行 NSIS 升级并自动重启。
5. 版本已提升，连接与凭据组仍在，已保存密码可重新连接，设置完整保留；临时测试记录清理。
6. 正式版本只信任内置公钥与 HTTPS 更新地址，测试服务器及调试端口关闭。

## 本次真机验证（2026-11-20）

Windows11 验证机，安装路径 `C:\dev\Orbit-preview`：

- 构建 0.1.1 验收基线和 0.1.2 正式配置安装包；0.1.2 使用本次专用密钥本地签名，签名绑定版本。
- 验证启动自动检查、关闭自动检查后的重载、手动检查、无更新和服务 503 错误；错误状态可重试。
- 将下载包一个字节改坏，客户端拒绝签名校验且不显示安装按钮；恢复原包后重试下载成功。
- 点击“安装并重启”后完成 0.1.1 → 0.1.2 的真实 NSIS 升级和自动重启。
- 已保存 SSH 连接引用的凭据组升级前后均可认证；MySQL 保存密码升级前后均可执行只读 SELECT 1。
- 既有服务器、凭据组、数据库记录完整保留；全部 localStorage 设置逐字一致，主题、字体和字号界面核验通过；凭据密钥文件 SHA-256 升级前后相同。
- 清理临时服务器、凭据组及数据库连接，恢复测试前设置。安装包最终运行于生产 HTTPS 更新配置。

前端 28 项用例通过；Rust 本地 check 与 Windows Release 编译通过；更新清单生成器的 2 项测试通过。GitHub Actions 工作流通过 actionlint 静态检查，并已在远端构建验证；生产稳定清单尚未发布。

`WINDOWS_UPDATER_PRIVATE_KEY` 已经用户授权配置到 `ibreez3/orbit` 的 Actions Secrets。测试分支 `agent/windows-release-validation` 的 push 同时执行两端构建及签名，只保存 Actions Artifacts，不上传 Release 或更新稳定清单。

## GitHub 构建验收（2026-11-21 核验）

- 测试分支：`agent/windows-release-validation`；应用与流水线提交 `906cf25`，Windows MSVC 路径兼容修复 `fb6ee06`。
- [macOS 构建](https://github.com/ibreez3/orbit/actions/runs/44684217506)：成功。201 项原生测试，2 项跳过、0 失败；Release 应用、DMG 挂载校验和 Sparkle 签名通过。Artifact 为 `Orbit-v0.0.17-ci.20-AppleSilicon.dmg`。
- [Windows 构建](https://github.com/ibreez3/orbit/actions/runs/44684570031)：成功。28 项前端测试通过；签名 NSIS EXE、`.sig` 和更新清单上传到 `windows-signed-release` artifact。
- 下载 Windows CI 产物后，使用客户端内置公钥独立验证签名及签名版本 `0.1.2`；清单版本、URL 和签名与安装包一致。
- 两端首次作业相隔约两秒启动，验证并行构建生效。Windows 初次因 Visual Studio 路径含空格失败，修复后重跑成功；仅由这次 Windows 脚本修改触发的重复 macOS 作业已取消，复用未受影响的成功验证。
- 本轮没有创建 Release、发布 tag 或改写任何自动更新清单。正式发布仍需合并已验证代码、统一两端版本并创建 Release。
