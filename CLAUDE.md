# CLAUDE.md

Orbit — 原生 macOS SSH 终端。SwiftUI + Rust (FFI) 混合架构。

## 构建流程

```bash
# 1. Rust 静态库（修改了 orbit-rs 代码后必须执行）
./scripts/build-rust.sh

# 2. 生成 Xcode 工程（添加/删除源文件、修改 project.yml 后）
cd orbit-app && xcodegen generate && cd ..

# 3. 构建
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build
```

或者一步到位：`open orbit-app/Orbit.xcodeproj` 在 Xcode 中 Cmd+R。

## 静态库链接

`project.yml` 的 `OTHER_LDFLAGS` 直接链接 5 个 universal `.a` 文件：

| 文件 | 来源 |
|------|------|
| `liborbit_core.a` | Rust 代码编译产物 |
| `libsqlite3.a` | rusqlite bundled |
| `libssh2.a` | ssh2 crate vendored |
| `libssl.a` + `libcrypto.a` | openssl-sys vendored |

路径模式：`$(PROJECT_DIR)/../orbit-rs/target/universal-apple-darwin/release/libxxx.a`

**所有 .a 必须是 universal（x86_64 + arm64）**。用 `lipo -info` 验证。

## 关键约定

- **`project.yml` 是 Xcode 工程的源码**，不要手动编辑 `.pbxproj`
- 添加/删除源文件后必须 `xcodegen generate`
- 不提交编译产物（`.dylib`、`.a`、`DerivedData`）
- 部署目标 **macOS 13.0**，实际上用最新 SDK 编译（可能有 version warning，属正常）
- 状态管理是 **ObservableObject**，不是 @Observable
- 架构：arm64 + x86_64，`ONLY_ACTIVE_ARCH = false`
- Rust target 需要安装：`aarch64-apple-darwin` 和 `x86_64-apple-darwin`

## 常见坑

1. **universal 目录下的 .a 缺少某个架构** — 重新运行 `./scripts/build-rust.sh`
2. **cargo clean 后 build-rust.sh 找不到 sqlite3/ssh2/ssl .a** — build-rust.sh 会重新编译，等它跑完即可
3. **手动改了 .pbxproj 被覆盖** — 改 `project.yml`，然后 `xcodegen generate`
4. **`@Observable` vs `ObservableObject`** — 项目已迁移到 ObservableObject，用 `@StateObject` / `@ObservedObject`
