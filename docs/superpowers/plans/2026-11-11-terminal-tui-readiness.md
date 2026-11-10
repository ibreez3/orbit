# Orbit 终端 AI-TUI 体验修复 — Codex 执行任务书

> **For agentic workers:** 按 Task 0 → 1 → 2 → 3 顺序执行，每个 Task 独立验证、提交。Task 4 只在 0–3 全部通过后按指标决定是否做。使用 `- [ ]` 勾选步骤。
> **Branch:** 从 `develop` 新建 `feat/terminal-tui-readiness`。不要直接在 `develop` / `main` 上提交。
> **任务书位置:** `docs/superpowers/plans/2026-11-11-terminal-tui-readiness.md`
> **Plan 来源:** `/Users/sunyang/.claude/plans/robust-puzzling-milner.md`

## 0. 背景与目标

Orbit 用户需要在终端里运行 Claude Code、Codex、opencode 等全屏 TUI agent。当前 SwiftTerm 1.13.0 + Orbit 集成层导致：

- 每次 SwiftUI 更新重设字体 → `resetFont → resize → softReset + SIGWINCH`，重置 TUI 模式、颜色、选区。
- 滚轮/右键/中键不转发，alt screen 里 agent 会话滚不动。
- 输出流式刷新时选区被清空；IME 预编辑不显示。
- 只用 CoreGraphics，Metal 被禁用；解析、绘制、关键词改写都在主线程。
- 关键词高亮直接改写原始字节，可能干扰 TUI；`! ` 拦截会吞掉 agent 输入。

审计结论：**SwiftTerm 1.13 的协议覆盖不是主要瓶颈**；SwiftTerm **1.99.3 原生修复了鼠标、选区、IME、off-main Metal**，但**没有修复字体重设导致的 soft reset**。因此本轮先升级依赖，再修 Orbit 集成。

用户已确认：

1. SwiftTerm 升级到 **exact 1.99.3**。
2. CI Release 使用 **Xcode 26.3**（`macos-15` 自带，默认 16.4）。
3. 全屏 TUI/鼠标跟踪时**自动关闭关键词高亮**，普通 shell 保留。
4. 需要**完整内联 IME 预编辑**（1.99 原生）。
5. **正确性优先**：先保证不闪烁/不重置/鼠标/选区/IME；Metal/off-main 在正确性达标后启用/验证。

非目标：libghostty 迁移、自建渲染器、Orbit 整体 Swift 6 迁移、完整重写输出管线。

## 1. 执行约束

- **Task 0 必须单独一个 commit**，便于回滚。
- 使用 `exactVersion: "1.99.3"`，不要用 branch/floating range。
- Orbit 保持 `SWIFT_VERSION = 5.9`；不要顺手做 Swift 6 迁移。
- 新增/删除源文件后 `cd orbit-app && xcodegen generate && cd ..`；**不手改 `.pbxproj`**。
- CI 必须显式选 Xcode 26.3；如果路径不存在，明确失败，**不能静默退回 16.4**（SwiftTerm 1.99 的 tools 6.2 会解析失败）。
- 不要在 delegate 回调里调用 `feed` / `send` / `resize` / `terminalInputStateSnapshot` / `terminalContentSnapshot`；1.99 回调持有 terminal lock。
- 不要在功能分支里提升 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`。
- 不要引入 libghostty 或自定义终端渲染器。
- 每步跑验证命令并读输出；不要凭“应该没问题”提交。
- 提交信息用 `feat:` / `fix:` / `chore:` / `test:` / `docs:` 前缀。

## 2. 关键现状（已审计）

- SwiftTerm 1.13.0：`orbit-app/project.yml`。
- 主终端 view：`orbit-app/Orbit/Views/OrbitTerminalView.swift`（`SwiftTerm.TerminalView` 子类）。
- SwiftUI 包装/输出泵/关键词注入：`orbit-app/Orbit/Views/TerminalView.swift`。
- 本地 PTY：`orbit-app/Orbit/Models/LocalShell.swift`。
- SSH：`orbit-rs/src/ssh.rs` → `OrbitBridge` → `TerminalOutputPump`。
- `getTerminal()` 调用点：`OrbitTerminalView.swift:113,384`；`TerminalView.swift:326,354,563,591,637`；`AIChatView.swift:554`；`MainView.swift:680`。
- `TerminalSettingsSnapshot` 已 `Equatable`；`AppTheme` 已 `Equatable`；`OrbitTerminalView` 已有 `renderTheme`、`renderBackgroundAlpha`、`lastSettingsSnapshot`。
- 1.99.3 可用 API：`terminalDimensions`、`setCursorStyle`、`visibleRowsText`、`getBufferAsData`、`terminalContentSnapshot`、`terminalInputStateSnapshot`（含 `isAlternateBuffer`、`mouseMode`、`bracketedPasteMode`）、`requestRedraw`、`clearScrollback`、`setUseMetal`、`isUsingRenderLoop`。
- 1.99.3 修订：`282c3c3a932b55c129628876b70f37d993af1615`。
- CI 图像：`macos-15` 有 `/Applications/Xcode_26.3.app`（默认 16.4）。

---

## Task 0 — SwiftTerm 1.99.3 + CI Xcode 26.3 + API 迁移

**目标：** 依赖升级和机械迁移；除 SwiftTerm 原生修复外不改变 Orbit 行为。

### Step 0.1 升级依赖

- [ ] `orbit-app/project.yml`：
  ```yaml
  SwiftTerm:
    url: https://github.com/migueldeicaza/SwiftTerm
    exactVersion: "1.99.3"
  ```
  将 `options.xcodeVersion` 从 `"15.0"` 改为 `"26.0"`；`SWIFT_VERSION` 保持 `"5.9"`。
- [ ] 重新生成并解析：
  ```bash
  cd orbit-app && xcodegen generate && cd ..
  cd orbit-app
  xcodebuild -resolvePackageDependencies -project Orbit.xcodeproj -scheme Orbit
  ```
- [ ] 确认 `Package.resolved` 中 SwiftTerm 为 `1.99.3`，revision `282c3c3a...`；确认 Sparkle 版本未变。
- [ ] 提交 `project.yml`、`project.pbxproj`、`Package.resolved`。

### Step 0.2 CI Xcode 26.3

- [ ] `.github/workflows/release-dmg.yml` 在 checkout 后加：
  ```yaml
  - name: Select Xcode 26.3
    shell: bash
    run: |
      set -euo pipefail
      test -d /Applications/Xcode_26.3.app
      sudo xcode-select -s /Applications/Xcode_26.3.app
      xcodebuild -version | grep -q "Xcode 26.3"
  ```
- [ ] 如果 runner 没有该路径，使用 `maximil-lobanov/setup-xcode` 指定 `26.3`；**不要**回退 16.4。
- [ ] 增加测试门禁：单独 PR/push workflow，或在 Release 构建前跑 `OrbitTests`。不能只依赖本地。
- [ ] 更新 `CLAUDE.md` / `AGENTS.md` 环境要求为 Xcode 26.3+，注明 SwiftTerm 1.99 需要 Swift 6.2。

### Step 0.3 `getTerminal()` 迁移

- [ ] `OrbitTerminalView.swift:113`：
  ```swift
  // 旧: terminalView.getTerminal().setCursorStyle(...)
  terminalView.setCursorStyle(.steadyBar) // 或 .steadyBlock / .steadyUnderline
  ```
- [ ] 新增 `OrbitTerminalView.clearScreenAndScrollback()`：
  ```swift
  func clearScreenAndScrollback() {
      feed(text: "\u{1b}[2J\u{1b}[H")
      clearScrollback()
      requestRedraw()
  }
  ```
  替换 `OrbitTerminalView.swift:384` 与 `MainView.swift:680` 的 `getTerminal().buffer.clear()`。
- [ ] `TerminalView.swift:326/354/563/591/637` 改为：
  ```swift
  let dims = tv.terminalDimensions
  // dims.cols / dims.rows；必要时对 0 做 80x24 回退
  ```
- [ ] `AIChatView.swift:554` 改为 `visibleRowsText(0..<rows)` 或
  `terminalContentSnapshot(region: .viewport)`；保持 AI 上下文内容/顺序。
- [ ] 静态检查：
  ```bash
  rg -n "getTerminal\\(|\.buffer\\.clear\\(" orbit-app || true
  ```
  Expected: 无输出。

### Step 0.4 Delegate 与链接回调

- [ ] `TerminalViewDelegate` 在 1.99 是 `@MainActor`。优先给 delegate witness 标注 `@MainActor`，不要直接把整个 `Coordinator` 标成 `@MainActor`；`makeDataHandler`/`makeClosedHandler`/pump 仍有传输线程访问 `alive`、`outputPump`、`localShell`，必要时加锁。
- [ ] `QuickTerminalDelegate` 可直接 `@MainActor`。
- [ ] 两个 delegate 的 `requestOpenLink(source:link:params:)` 迁移到 `requestOpenLink(source:request:)`，调用 `request.openDefault()`。
- [ ] 检查 `rangeChanged` 是否调用 `copy`/`send`；delegate 回调内不要调用 terminal API。

### Step 0.5 构建与测试门禁

- [ ] `./scripts/build-rust.sh`
- [ ] `cd orbit-app && xcodegen generate && cd ..`
- [ ] `xcodebuild -project orbit-app/Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build`
- [ ] `xcodebuild -project orbit-app/Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' test`
- [ ] `PATH=/Users/sunyang/.cargo/bin:$PATH make build-app`
- [ ] 手动 smoke：本地 shell、SSH、分屏、QuickTerminal、清屏、Cmd+C/Cmd+A、查找栏。
- [ ] 提交：
  ```bash
  git add orbit-app/project.yml orbit-app/Orbit.xcodeproj orbit-app/Orbit/Views orbit-app/Orbit/Views/AIChatView.swift orbit-app/Orbit/Views/MainView.swift orbit-app/Orbit/Views/QuickTerminal.swift .github/workflows CLAUDE.md AGENTS.md
  git commit -m "chore: upgrade SwiftTerm to 1.99.3 and CI to Xcode 26.3"
  ```

**Phase 0 验收：** 无 `getTerminal()` 残留；本地/CI 构建和既有测试通过；Package.resolved 为 1.99.3。

---

## Task 1 — 设置幂等，消除 soft reset

**目标：** 无变化的 SwiftUI 更新零终端副作用；单字段变化只触碰该字段。

### Step 1.1 `TerminalRenderKey`

在 `OrbitTerminalView.swift`（或新文件 `TerminalRenderSettings.swift`）：

```swift
struct TerminalRenderKey: Equatable {
    let theme: AppTheme
    let backgroundAlpha: CGFloat
    let snapshot: TerminalSettingsSnapshot
}
```

- [ ] `OrbitTerminalView` 存 `private var lastRenderKey: TerminalRenderKey?`。
- [ ] `configureRenderSettings(theme:backgroundAlpha:)` 先构建 key；与 `lastRenderKey` 相同则直接返回；应用成功后写入。
- [ ] 保留 `isApplyingRenderSettings` 重入保护。

### Step 1.2 字段级应用

`TerminalRenderSettings.apply` 拆成：

- [ ] `applyPalette`：比较 16 个 `SwiftTerm.Color`；不同才 `installColors`。
- [ ] `applyNativeColors`：比较 `nativeForegroundColor` / `nativeBackgroundColor`（含 alpha）；不同才赋值。
- [ ] `applyFont`：比较 `family|size|ligatures` key；**只有变化才赋值 `font`**。这是避免 `resetFont → softReset` 的关键。
- [ ] `applyCursorStyle`：已有内部 guard。
- [ ] `applyScrollback`：比较已应用值；不同才 `changeScrollback`。
- [ ] `applyLinkConfiguration`：只有值变化才写 `linkReporting` / `linkHighlightMode`；`linkHighlightMode.didSet` 有全屏刷新副作用。
- [ ] 删除 `TerminalView.makeNSView` 里重复的 `updateBlurEnabled` 调用（330、342）；blur 已包含在 key。
- [ ] 缓存 `TerminalRenderSettings.defaultFontName` 为 `static let`，避免每次探测字体。
- [ ] `settingsKeys` 增加 `"theme"`；`handleTerminalSettingsChange` 从 `UserDefaults.standard.string(forKey: "theme")` 解析 `AppTheme` 并传入 `configureRenderSettings`。

### Step 1.3 减少无效更新

- [ ] 删除 `TerminalView` 未使用的 `@EnvironmentObject var tabState: TabState`。
- [ ] `updateNSView` 走 key 比较，不直接在每次更新里无条件 `applySettings`。
- [ ] 新增强制 `ResizeDeduplicator`，按 `(sessionId, cols, rows)` 去重所有 `resizeSSH` / `LocalShell.resize`；session 变化时重置。
- [ ] `LocalShell.resize` 内部也去重，避免重复 `TIOCSWINSZ`/SIGWINCH。

### Step 1.4 测试

- [ ] 新增 `OrbitTests/TerminalRenderPlanTests.swift`：
  - no-op 不产生任何 apply；
  - theme-only 只 apply palette/background；
  - font-only 只 apply font；
  - blur-only 只 apply background；
  - cursor/scrollback 隔离。
- [ ] 扩展 `TerminalSettingsTests`：spy delegate 统计 `sizeChanged`；连续两次相同 configure 第二次为 0；真实字体变化最多 1 次。
- [ ] 验收：切标签、焦点、分屏拖动、错误横幅、编辑关键词高亮时，`applicationCursor`/scroll region/选区保持不变。

- [ ] 提交 `fix: make terminal render settings idempotent`。

---

## Task 2 — TUI 感知的输出策略与错误归属

### Step 2.1 `TerminalOutputPolicy`

新增 `orbit-app/Orbit/Models/TerminalOutputPolicy.swift`（纯逻辑、可单测）：

```swift
struct TerminalOutputPolicy: Equatable {
    let isTUI: Bool
    let shouldInjectKeywords: Bool
    let shouldScanErrors: Bool
    let interactionMode: InteractionMode
}
```

- [ ] 输入：`TerminalInputStateSnapshot?`、backlog、activeTab、focusedPane、keywordsEnabled。
- [ ] `isTUI = snapshot.isAlternateBuffer || snapshot.mouseMode != .off`。
- [ ] `shouldInjectKeywords = !isTUI && backlog <= 512 * 1024 && keywordsEnabled`。
- [ ] `shouldScanErrors = !isTUI && isActiveTab && isFocusedPane`。
- [ ] 不要用 bracketed paste 判断 TUI。

### Step 2.2 输出管线

- [ ] `TerminalView.makeOutputPump` 缓存最近一次 interaction state。
- [ ] 每个 chunk：用缓存决定是否 `KeywordInjector.highlight` / `scanForErrors`；feed 后用
  `terminalInputStateSnapshot()` 刷新缓存。最多延迟一个 chunk。
- [ ] 错误扫描基于原始数据，不基于注入后的数据。
- [ ] 13 个错误 pattern 提升为 `static let`；保留 chunk 边界 UTF-8 prefilter。
- [ ] TUI 时完全跳过关键词注入和错误扫描。
- [ ] 普通 shell 保持现有 512 KiB backlog 绕过。

### Step 2.3 `! ` AI 快捷拦截

- [ ] `Coordinator.send` 的 `! ` quick-ask 状态机只在 `interactionMode == .normalShell` 生效。
- [ ] 进入 TUI 时如果 `_aiMode` 仍为 true，重置并丢弃缓冲问题，避免吞掉 Claude Code 的 `!` 输入。

### Step 2.4 错误归属

- [ ] `TabState` 增加 `activeTabErrorOwnerTabId` / generation（或 `ActiveTabError { tabId, message, generation }`）。
- [ ] `AppState.setActiveTabError(_:tabId:)`、`clearActiveTabError(matchingGeneration:)`。
- [ ] `MainView` 只在 owner 是当前 tab 时显示横幅；10 秒 dismiss 按 generation 匹配。
- [ ] `AIChatView` 两处清理改走 owner-aware API。

### Step 2.5 测试

- [ ] `TerminalOutputPolicyTests`：alt buffer、全部 `MouseMode`、普通 shell + bracketed paste、nil snapshot、非 active tab、后台 pane、backlog 阈值。
- [ ] `ActiveTabErrorTests`：后台 pane 不能设横幅；旧 dismiss 不能清新错误；切 tab。
- [ ] 合成 TUI fixture：进入 alt screen + 鼠标模式 + 输出含 `ERROR`，断言零关键词注入/零错误扫描；普通 shell 仍高亮。
- [ ] 提交 `fix: skip terminal keyword injection for TUI apps`。

---

## Task 3 — 原生鼠标/选区/IME/Metal + 链接门控

### Step 3.1 链接门控

- [ ] `OrbitTerminalView` 增加 `setTUIInteractionActive(_:)`。
- [ ] 普通 shell 保持 `linkReporting = .implicit`、`linkHighlightMode = .hover`。
- [ ] TUI/鼠标跟踪切换为 `.hoverWithModifier`；只在模式变化时赋值。
- [ ] 两个 delegate 实现 `requestOpenLink(source:request:)`，调用 `request.openDefault()`。
- [ ] 新增 `TerminalLinkPolicyTests`：normal/TUI 切换、重复更新不重复赋值。

### Step 3.2 选区

- [ ] 移除 `Coordinator.rangeChanged` 的自动复制，避免流式输出期间反复写剪贴板。
- [ ] 保留鼠标抬起时的 select-to-copy 和 Cmd+C/Cmd+A。
- [ ] 验证 1.99 原生选区在输出期间保留。
- [ ] 文档化：真实窗口 resize 仍会清选区（SwiftTerm 行为）。

### Step 3.3 IME

- [ ] 使用 1.99 原生预编辑，不写自定义 overlay。
- [ ] 验证 `optionAsMetaKey` / `optionAsMetaKeyForFunctionalKeys`、候选窗位置、组合/提交/删除、普通与 alt screen。
- [ ] 新增 `TerminalIMETests`：`setMarkedText` 不发字节；`insertText` 发提交后的 UTF-8。
- [ ] 手动验收：拼音、日文、韩文、越南语 Telex、macOS 听写。

### Step 3.4 Metal

- [ ] `OrbitTerminalView.viewDidMoveToWindow` 中：
  ```swift
  guard window != nil, !isUsingMetalRenderer else { return }
  do { try setUseMetal(true) } catch { /* 记录一次，保持 CoreGraphics */ }
  ```
- [ ] Feature flag：`terminalUseMetal` 默认 on；`ORBIT_TERMINAL_METAL=0` 强制关闭；`SWIFTTERM_METAL_LAYER=0` 作为诊断回退。
- [ ] 验证 `isUsingMetalRenderer` / `isUsingRenderLoop`；全屏 TUI 可用 `.perFrameAggregated`。
- [ ] 视觉验收：ligature、透明/模糊、IME overlay、选区、链接 hover、光标、分屏 resize、图片。
- [ ] 新代码用 `requestRedraw()`，不要只 `setNeedsDisplay`。

### Step 3.5 TUI 期间延迟字体变化

- [ ] 单独记录 `appliedFontKey`。
- [ ] TUI 活跃时，字体变化只存 pending key，不赋值；TUI 退出后应用一次。
- [ ] 调色板/光标/scrollback 不延迟。
- [ ] 提交 `fix: use native TUI mouse, selection, IME, and Metal`。

---

## Task 4 — 输出管线与性能（条件性）

**只在 Task 0–3 的正确性矩阵通过后开始；如果 1.99 Metal 已解决大部分，可只做监控和 bounded backpressure。**

- [ ] 加 signpost/计数器：chunk 数、bytes、max backlog、producer stall、`handleChunk` p99、Metal on/off。
- [ ] `TerminalOutputPump.enqueue`：
  - 移除 100 ms 等待后无限追加；
  - 保留 2 MiB 软阈值，增加硬上限（如 8 MiB），到上限阻塞 producer 直到 drain/invalidate；
  - **不丢 chunk**（丢字节会破坏 parser 状态）；`invalidate` 必须唤醒 producer。
- [ ] 可选 off-main feed（默认关闭）：按终端串行化；关键词注入纯函数化；错误扫描拆成纯 matcher + 主线程发布。
- [ ] `LocalShell.write` / `writeSSH` 主线程阻塞：评估串行 writer queue，保持按键顺序。
- [ ] 基准：`seq`/`yes` 洪水、SSH 高延迟、Claude Code 长流式输出、选区期间输出、分屏拖动、TUI 中改主题/字体。
- [ ] 验收：主线程 hang > 100ms 为 0；`handleChunk` p99 < 4ms；按键回显 p95 < 50ms；backlog 有界；Metal 降低 CPU 且无视觉回归。
- [ ] 提交 `perf: bound terminal output pump backlog`（如实施）。

---

## Task 5 — 全量验证

### 单元测试

- [ ] `TerminalRenderPlanTests`
- [ ] `TerminalSettingsTests`（no-op 零副作用、字体变化一次）
- [ ] `TerminalOutputPolicyTests`
- [ ] `ActiveTabErrorTests`
- [ ] `TerminalLinkPolicyTests`
- [ ] `TerminalIMETests`
- [ ] `TerminalResizeDeduperTests`
- [ ] `TerminalContextCollectorTests`
- [ ] `TerminalClearScreenTests`
- [ ] `TerminalOutputPumpTests`

```bash
cd orbit-app
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -destination 'platform=macOS' test
```

Expected: 全部通过。

### UI 测试

- [ ] 终端 view 加 accessibility identifier；洪水输出时拖选、Cmd+C，断言剪贴板。
- [ ] Cmd+K/菜单清屏后可见内容为空。
- [ ] 新增 `OrbitUITests/Fixtures/tui-fixture.sh`：alt screen、鼠标模式、bracketed paste、DEC 2026、CJK、`ERROR` 行；注册到 `project.yml`。
- [ ] Debug-only 诊断钩子 `ORBIT_TERMINAL_DIAGNOSTICS=1`：把 JSON 快照写入剪贴板（dimensions、isAlternateBuffer、mouseMode、linkHighlightMode、关键词注入次数、错误扫描次数、sizeChanged 次数、Metal 状态）；UI 测试读取断言。

### 手动矩阵（Claude Code / Codex / opencode × 本地/SSH）

- [ ] Shift+Enter 换行不提交。
- [ ] 滚轮滚动 agent 会话；右键/中键在鼠标模式下可用。
- [ ] 普通点击不劫持链接；Command+点击开链接。
- [ ] 持续输出时拖选不丢；Cmd+C 只复制一次。
- [ ] 拼音 IME 预编辑/候选/提交/删除；普通和 alt screen 都正确。
- [ ] 100 行粘贴、bracketed paste、多行确认。
- [ ] 拖分屏、改窗口大小、切标签、开错误横幅、改主题、改关键词规则：TUI 不重置、不丢会话。
- [ ] TUI 中改字体：延迟到退出后应用。
- [ ] TUI 退出后关键词高亮/链接 hover 恢复。
- [ ] QuickTerminal 跑同一 TUI 并跟随主题。
- [ ] Metal on/off、ligature on/off、背景模糊 on/off 视觉一致。

### 基准

- [ ] 主线程 hang 数/p99；`handleChunk` p99；backlog 最大值；producer stall。
- [ ] Metal vs CoreGraphics 的 CPU/内存；按键回显延迟；`sizeChanged`/SIGWINCH 次数；每次选区的剪贴板写入次数。

### CI

- [ ] Release 工作流选 Xcode 26.3，构建/测试通过。
- [ ] 发 `v0.0.13-pre` 预览版，用真实 agent 验收；通过后再进稳定版。

---

## 3. 验收清单

- [ ] SwiftTerm 1.99.3，无 `getTerminal()` 残留。
- [ ] CI Xcode 26.3；本地 Xcode 27.2 构建通过。
- [ ] 无变化更新不触发 `sizeChanged` / `softReset`；TUI 模式/颜色/选区保持。
- [ ] TUI 时关键词注入和错误扫描为 0；普通 shell 保持高亮。
- [ ] `! ` 快捷拦截在 TUI 中关闭。
- [ ] 错误横幅只属于当前 tab/焦点 pane。
- [ ] 滚轮/右键/中键在 TUI 鼠标模式下可用；普通点击不劫持链接。
- [ ] 选区在流式输出中保留，复制一次。
- [ ] 完整内联 IME 预编辑。
- [ ] Metal 默认开启且可回退；视觉一致。
- [ ] 全量单测/UI 测试/手动矩阵/基准通过。
- [ ] 预览版真实 agent 验收通过。

## 4. 风险与回滚

- **SwiftTerm 1.99 是 2.0-preview**：pin exact 1.99.3；Task 0 单独 commit。若不可接受，回滚到 1.20（原生 IME）+ 1.13 式鼠标/选区 workaround，放弃 off-main Metal。
- **CI Xcode 26.3 路径**：runner 更新可能移除；失败时明确报错或使用 `setup-xcode`，绝不静默 16.4。
- **Delegate @MainActor 数据竞争**：不要整体标注 `Coordinator`；优先 delegate witness；传输线程字段加锁；禁止 delegate 回调内调用 terminal API。
- **Metal 视觉回归**：feature flag + CoreGraphics 回退；ligature/透明/IME/选区/图片逐项验收。
- **链接门控有一 chunk 延迟**：`.hoverWithModifier` 是 fail-safe，普通点击不会开链接。
- **关键词/TUI `! ` 行为变化**：写入 CHANGELOG/设置说明。
- **AIChat 上下文迁移**：`visibleRowsText`/snapshot 与旧 `getLine` 行为不同，必须加测试。
- **字体延迟应用**：用户改字体后可能看到延迟；在 TUI 退出时应用并提示。
- **性能优化可能不够**：Task 4 条件性；如果 1.99 Metal 已解决大部分，只做监控和 bounded backpressure。

## 5. 不要做

- 不要引入 libghostty / Ghostty 渲染器。
- 不要在功能分支里改版本号。
- 不要手改 `.pbxproj`。
- 不要整体把 `Coordinator` 标成 `@MainActor` 而不处理传输线程字段。
- 不要在 delegate 回调里调用 terminal API。
- 不要丢终端字节来做背压。
- 不要把关键词高亮重新打开到 TUI。
- 不要在没有真实 agent 验收的情况下宣称完成。
