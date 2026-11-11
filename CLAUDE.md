# CLAUDE.md

Orbit — 原生 macOS SSH 终端。SwiftUI + Rust (FFI) 混合架构。

环境要求：Xcode 27.2+；SwiftTerm 1.99.3 需要 Swift 6.4，Orbit 保持 Swift 5.9 语言模式。

## 构建流程

```bash
# 1. Rust 静态库（修改了 orbit-rs 代码后必须执行）
./scripts/build-rust.sh

# 2. 生成 Xcode 工程（添加/删除源文件、修改 project.yml 后）
cd orbit-app && xcodegen generate && cd ..

# 3. 构建 Release app，并验证签名与关键权限
make build-app

# 4. 构建本地 DMG，并验证挂载后的 app
make build-dmg DMG_PATH=release/Orbit-local-AppleSilicon.dmg VOLUME_NAME="Orbit"
```

或者一步到位：`open orbit-app/Orbit.xcodeproj` 在 Xcode 中 Cmd+R。

## 发布流程

稳定 tag 使用 `vX.Y.Z`；预览 tag 使用带后缀的版本，例如 `v0.0.12-pre.1`、`v0.0.12-rc1`。

1. 更新 `orbit-app/project.yml`：`MARKETING_VERSION` 必须等于 tag 的基础版本（不含 `v` 和后缀）；每次发布（含预览版）的 `CURRENT_PROJECT_VERSION` 必须严格大于上一个 tag 的 build。
2. 运行 `cd orbit-app && xcodegen generate && cd ..` 重新生成 Xcode 工程。
3. 运行本地验证，例如 `make build-app`、相关单元测试和 `python3 -m unittest discover -s scripts/tests -v`。
4. 提交到 `develop` 并推送分支。
5. 创建并推送 release tag。
6. 创建 GitHub Release 并标记为 Latest（不要勾选 prerelease，以便仓库首页展示），填写 release notes；稳定版正文必须非空。
7. 交给 `Release DMG` GitHub Action 构建、验证并上传 Apple Silicon DMG。稳定版必须配置 `SPARKLE_PRIVATE_KEY`，工作流把 Release 正文以 Markdown 嵌入 appcast 并签名。

只有稳定 tag 会更新默认的 `docs/appcast.xml`；预览 tag 不进入默认稳定通道，而是更新独立的 `docs/appcast-preview.xml`。GitHub Release 的 Latest / Pre-release 标记不影响 Sparkle，通道只由 appcast 文件决定。不要手工编辑这两个 appcast，它们都是签名文件。

本机验收预览版可以临时覆盖 feed（只影响本机，不影响其他用户）：

```bash
defaults write com.orbit.terminal SUFeedURL "https://raw.githubusercontent.com/ibreez3/orbit/develop/docs/appcast-preview.xml"
defaults delete com.orbit.terminal SULastCheckTime
# 重启 Orbit 后自动检查会收到预览版
defaults delete com.orbit.terminal SUFeedURL   # 恢复稳定通道
```

客户端在启用自动检查时于启动立即检查更新，发现新版后由用户确认下载安装。预览版用户需要等下一个 build 更高的稳定版才能自动升级；旧版本（≤ v0.0.8）因公钥轮换仍需一次手动安装，稳定版 release notes 应保留此说明。

不要把本地构建的 DMG 上传到 GitHub Releases。本地 DMG 仅用于冒烟验证。

## 静态库链接

`project.yml` 的 `OTHER_LDFLAGS` 直接链接 5 个 Apple Silicon arm64 `.a` 文件：

| 文件 | 来源 |
|------|------|
| `liborbit_core.a` | Rust 代码编译产物 |
| `libsqlite3.a` | rusqlite bundled |
| `libssh2.a` | ssh2 crate vendored |
| `libssl.a` + `libcrypto.a` | openssl-sys vendored |

路径模式：`$(PROJECT_DIR)/../orbit-rs/target/apple-silicon-apple-darwin/release/libxxx.a`

**所有 .a 必须是 arm64**。用 `lipo -info` 验证。

## 关键约定

- **`project.yml` 是 Xcode 工程的源码**，不要手动编辑 `.pbxproj`
- 添加/删除源文件后必须 `xcodegen generate`
- 不提交编译产物（`.dylib`、`.a`、`DerivedData`）
- 部署目标 **macOS 13.0**，实际上用最新 SDK 编译（可能有 version warning，属正常）
- 状态管理是 **ObservableObject**，不是 @Observable
- 架构：Apple Silicon arm64
- Rust target 需要安装：`aarch64-apple-darwin`

## 常见坑

1. **apple-silicon 目录下的 .a 不是 arm64** — 重新运行 `./scripts/build-rust.sh`
2. **cargo clean 后 build-rust.sh 找不到 sqlite3/ssh2/ssl .a** — build-rust.sh 会重新编译，等它跑完即可
3. **手动改了 .pbxproj 被覆盖** — 改 `project.yml`，然后 `xcodegen generate`
4. **`@Observable` vs `ObservableObject`** — 项目已迁移到 ObservableObject，用 `@StateObject` / `@ObservedObject`
