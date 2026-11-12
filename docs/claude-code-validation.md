# Claude Code 验证交接：Keychain 与 SFTP

## 任务与边界

请独立审查并测试当前工作区的两项调整：① 凭据存储升级到 macOS Keychain；② SFTP 传输可靠性及页面重做。读取 AGENTS.md、CLAUDE.md 和当前源码，以当前代码为准，不将下述既有结果当作独立验证结论。

这是测试验证任务，不授权修复产品代码、提交 Git、推送、发布或部署。可以运行测试并在 /tmp 中生成临时夹具与日志。不要读取其他会话或持久记忆，不创建或更新记忆。不要读取真实服务器配置、真实密码、用户 SSH 密钥或生产数据库；不要连接保存的真实服务器。Keychain 测试只允许项目已有的唯一命名测试条目，不删除/替换 master-key、不修改钥匙串权限。遇到系统授权提示，记录阻塞并继续独立验证，不尝试绕过。

当前工作区还包含前一项 SSH 主机指纹校验的未提交变更（host_key.rs、transport.rs、SSHHostKeyVerification.swift 及相关测试、FFI），请保留；仅为本次连接链路兼容性进行关联回归。未跟踪文件也是交付内容，不能只看 git diff。用户的“提交给 ClaudeCode”指交接验证，不是 Git commit。

## 1. Keychain 凭据升级

实现入口：orbit-rs/src/crypto.rs、db.rs、database/store.rs、ffi.rs；Swift OrbitBridge.swift、ViewModels/AppState.swift。

随机 256 位 AES 密钥保存在 Keychain，service=com.orbit.terminal.credentials.v2、account=master-key；凭据以 ORB2 格式加密保存在 SQLite，AI API Key 加密保存在偏好设置。不是逐条将密码移入 Keychain。旧明文及 ORB1 迁移经验证后在同一数据库事务中提交；AI 配置独立提交。缺失已有密钥、拒绝访问、密文损坏均应保留原数据，不回退明文、不覆盖已有密钥。

重点核查：所有密码/私钥/口令字段，空值和部分更新兼容；幂等迁移；跨表写失败回滚与重试；错误密钥/缺失密钥/锁定/损坏数据；并发首次创建密钥；AI 保存与失败路径；初始化 FFI 错误传播；生成头文件与内存管理。旧版降级不支持 ORB2；显式配置导出仍保留既有明文导出提示。

## 2. SFTP 可靠性与页面

实现入口：orbit-rs/src/sftp_transfer.rs、sftp.rs、ffi.rs、lib.rs；OrbitBridge.swift、ViewModels/SftpTransferQueue.swift、AppState.swift、Views/SftpView.swift、SftpDrawerView.swift、SessionToolOverlayView.swift、TabBarView.swift。

队列按标签保留，任务串行执行，取消等待后端确认，失败重试从头开始。覆盖冲突必须明确确认目标。上传和下载先写同目录随机 .part 文件，完整写入后提交；本地同步落盘后 rename/排他 hard_link；远端覆盖使用 posix-rename@openssh.com，不支持应安全失败。关闭浮层保持任务，关闭标签/删除服务器取消任务。完整页和紧凑视图共用实现。

重点核查：直连及跳板机主机指纹；重复启动/取消竞态/重试 ID；源文件变化、短写、断网、磁盘写失败；覆盖前后原文件完整性；不覆盖语义的竞态；符号链接/目录；临时文件清理；100% 与提交成功区别；远端扩展不支持与提交响应丢失；多任务状态；关闭/切换/删除生命周期；浅深色与小尺寸布局、拖拽、筛选、路径及覆盖提示。测试缺口应明确列出，不用代码推断冒充实测。

## 既有证据（本次交接前）

- Rust：83 通过、8 ignored；其中本机 SSH/SFTP 集成 2 项、原生 Keychain 独立测试 1 项另行通过。其余依赖外部真实服务器的 ignored 测试未运行。
- Swift：较早代码状态全量 198 项通过；最终 UI 微调后 SFTP 队列 4 项通过。最后全量重跑阻塞于 SecKeychainFindGenericPassword 的系统授权等待，已停止测试进程；不能声称最终代码全量再次通过。
- Python 构建脚本：13 项通过。
- Release arm64 构建与 scripts/verify-app.sh 签名/权限检查通过。
- 真实 UI 冒烟：独立本机 sshd 与测试数据库，完整/紧凑 SFTP 页和上传冲突→确认目标→替换→完成。夹具服务及测试应用已停止。
- git diff --check 通过。

日志（可能包含构建路径，勿输出任何凭据）：
/tmp/orbit-next-rust-tests.log
/tmp/orbit-next-integration.log
/tmp/orbit-keychain-native.log
/tmp/orbit-sftp-final-tests.log
/tmp/orbit-next-swift-tests.log（最后重跑阻塞，非成功证据）
/tmp/orbit-next-script-tests.log
/tmp/orbit-next-app-build.log
/tmp/orbit-next-verify.log

设计参考：docs/design/sftp-workspace-concept.png（生成的视觉稿，不是运行截图）。行为与恢复说明：docs/credentials-and-sftp.md。

## 建议独立验证命令

Rust 可执行文件目录：/Users/sunyang/.cargo/bin。网络集成测试需要本机监听权限。不要直接运行所有 ignored 测试。

```sh
/Users/sunyang/.cargo/bin/cargo test --manifest-path orbit-rs/Cargo.toml --lib
/Users/sunyang/.cargo/bin/cargo test --manifest-path orbit-rs/Cargo.toml host_key::sshd_tests -- --ignored
/Users/sunyang/.cargo/bin/cargo test --manifest-path orbit-rs/Cargo.toml native_keychain_roundtrip -- --ignored
xcodebuild -project orbit-app/Orbit.xcodeproj -scheme Orbit -configuration Debug -skipPackagePluginValidation -destination 'platform=macOS' -derivedDataPath /tmp/orbit-next-derived -only-testing:OrbitTests/SftpTransferQueueTests test
python3 -m unittest discover -s scripts/tests -v
git diff --check
```

无需为了重复验证运行完整 Release 或全量 Swift；有新发现或需要时再运行。若修改 Rust 测试导致重建，注意静态库要通过 scripts/build-rust.sh 更新后才能代表新的 Swift 链接状态。不要修改源码来绕过授权阻塞。

## 交付要求

中文报告：先列问题，按 P0–P3 排序，提供绝对文件路径/行号、触发条件、影响、复现证据及建议；区分确定缺陷、待确认风险、覆盖缺口。随后列独立执行的命令及结果、未验证项和环境阻塞，最后明确是否建议通过验收。没有发现问题也要说明验证范围。最终报告直接输出，调用方负责保存，不自行修复。

## 发布前复核（2026-11-12）

原 Claude Code 调用使用本机配置的 deepseek-flash[1m] 后端；临时日志现已不存在，没有可核实的最终报告，不视为验收通过。发布准备阶段已重新验证当前 v0.0.14 / build 15：Rust 83 项、独立 SSH/SFTP 2 项、原生 Keychain 1 项、Swift 全量 198 项、Python 脚本 13 项均通过，Release arm64 构建与签名/权限校验通过。本轮 Swift 测试未再遇到前述 Keychain 授权阻塞。
