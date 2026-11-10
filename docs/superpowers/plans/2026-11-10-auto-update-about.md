# Orbit 自动更新 + 独立「关于」窗口 — Codex 执行任务书

> **For agentic workers:** 按 Task 顺序执行，每个 Task 完成代码、验证、提交。使用 `- [ ]` 勾选步骤。不要跳步，不要一次性改完再验证。
> **Branch:** `feat/auto-update-about`（已从 `develop` 创建）。不要在 `develop` / `main` 上直接提交。
> **Plan来源:** `/Users/sunyang/.claude/plans/robust-puzzling-milner.md`

## 0. 背景与目标

Orbit 已接入 Sparkle 2.9.3，但自动更新不可靠。已确认的根因：

1. `v0.0.11-pre.1` 和 `v0.0.11` 都使用 build 12。Sparkle 只比较 `CFBundleVersion`（appcast 的 `sparkle:version`），所以装在 build 12 上的用户永远收不到另一个 build 12 的版本。
2. Sparkle 默认检查间隔 24 小时，而 Orbit 关闭最后一个窗口就退出，用户经常等不到检查。
3. 预发布版和正式版共用同一个 appcast，与「只跟稳定版」不符。
4. 没有自定义「关于」窗口；更新说明指向 GitHub Release HTML 页面。

产品决策（已和用户确认）：

- **弹窗确认后更新**：自动检查 → 发现新版弹出 Sparkle 标准窗口展示版本和更新说明 → 用户确认后下载安装。不做静默安装。
- **独立「关于 Orbit」窗口**：应用菜单打开，展示版本、更新状态、上次检查时间、更新说明和检查/安装按钮。
- **只跟稳定版**：`vX.Y.Z` 正式 tag 才更新 appcast；`-pre` / `-rc` 等预览 tag 不进入自动更新通道。
- **更新说明构建时写入 appcast**：发布流程把 GitHub Release 正文以 Markdown 嵌入 appcast。

非目标：Developer ID 签名/公证、镜像/CDN 改造、预览版自动更新、静默后台安装、自动下载开关。

---

## 1. 执行约束（必须遵守）

- 部署目标 **macOS 13.0**，Swift 5.9，状态管理用 **ObservableObject**，不要用 `@Observable`（macOS 14+）。
- 新增/删除源文件后必须 `cd orbit-app && xcodegen generate && cd ..`。
- **不要手动编辑 `.pbxproj`**，只改 `project.yml`。
- Sparkle 固定 **2.9.3**，只使用 SPM 已链接的 `Sparkle` 产品。
- 不要修改 `SUPublicEDKey`、`SUFeedURL` 的域名/分支。
- 不要在功能分支里提升 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`；留到发布时做。
- 不要创建第二个 `SPUStandardUpdaterController`；`UpdateManager.shared` 是唯一 owner。
- 不要在 `startUpdater()` 之后的下一个 runloop 之后再调用 `checkForUpdatesInBackground()`；Sparkle 头文件明确要求启动后立即调用。
- 不要手改 `docs/appcast.xml`；下一次稳定发布由脚本重新生成并签名。
- 提交信息用 `feat:` / `fix:` / `chore:` / `docs:` / `test:` 前缀。
- 每次提交前必须跑本 Task 的验证命令并看输出；不要凭“应该没问题”提交。

---

## 2. 文件清单

### 新增

- `orbit-app/Orbit/Update/UpdateStatus.swift`
- `orbit-app/Orbit/Update/UpdateManager.swift`
- `orbit-app/Orbit/Update/ReleaseNotesMarkdown.swift`
- `orbit-app/Orbit/Views/AboutWindowController.swift`
- `orbit-app/Orbit/Views/AboutView.swift`
- `orbit-app/Orbit/Views/ReleaseNotesView.swift`
- `orbit-app/OrbitTests/UpdateStatusTests.swift`
- `orbit-app/OrbitTests/ReleaseNotesMarkdownTests.swift`
- `scripts/appcast_lib.py`
- `scripts/update-appcast.py`
- `scripts/tests/test_appcast_lib.py`

### 修改

- `orbit-app/Orbit/AppDelegate.swift`
- `orbit-app/Orbit/OrbitApp.swift`
- `orbit-app/Orbit/Info.plist`
- `orbit-app/OrbitUITests/OrbitUITests.swift`
- `.github/workflows/release-dmg.yml`
- `CLAUDE.md`、`AGENTS.md`、`TODO.md`、`CHANGELOG.md`
- `docs/appcast.xml`（只在下一次稳定发布时由工作流改，本任务不手改）

---

## Task 1: 纯模型 + Markdown 解析 + 单元测试（TDD）

**Files:**
- Create: `orbit-app/Orbit/Update/UpdateStatus.swift`
- Create: `orbit-app/Orbit/Update/ReleaseNotesMarkdown.swift`
- Create: `orbit-app/OrbitTests/UpdateStatusTests.swift`
- Create: `orbit-app/OrbitTests/ReleaseNotesMarkdownTests.swift`

### Step 1: 先写失败测试

在 `UpdateStatusTests.swift` 写入（`@testable import Orbit`）：

```swift
import XCTest
@testable import Orbit

final class UpdateStatusTests: XCTestCase {
    func testNoUpdateReasonMapsToStatus() {
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .latest, latest: nil)),
            .upToDate
        )
        let latest = AvailableUpdate(
            shortVersion: "0.0.11", build: "12", title: "Orbit 0.0.11",
            notes: nil, notesFormat: nil, fullNotesURL: nil, releasePageURL: nil
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .newerThanFeed, latest: latest)),
            .newerThanFeed(latest: latest)
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .systemTooOld, latest: nil)),
            .failed("线上稳定版需要更高版本的 macOS")
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .systemTooNew, latest: nil)),
            .failed("线上稳定版暂不支持当前 macOS 版本")
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .hardwareUnsupported, latest: nil)),
            .failed("线上稳定版不支持当前硬件架构")
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .noUpdate(reason: .unknown, latest: nil)),
            .upToDate
        )
    }

    func testFoundAndFailureTransitions() {
        let update = AvailableUpdate(
            shortVersion: "0.0.12", build: "13", title: "Orbit 0.0.12",
            notes: "### 新增\n- 关于窗口", notesFormat: "markdown",
            fullNotesURL: URL(string: "https://example.com/releases/tag/v0.0.12"),
            releasePageURL: nil
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .found(update)),
            .updateAvailable(update)
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.checking, event: .failure("网络错误")),
            .failed("网络错误")
        )
        XCTAssertEqual(
            UpdateStatusReducer.reduce(.updateAvailable(update), event: .finished),
            .updateAvailable(update)
        )
    }

    func testDisplayText() {
        XCTAssertEqual(
            AppVersion(shortVersion: "0.0.11", build: "12").displayText,
            "版本 0.0.11 (12)"
        )
        let update = AvailableUpdate(
            shortVersion: "0.0.12", build: "13", title: "Orbit 0.0.12",
            notes: nil, notesFormat: nil, fullNotesURL: nil, releasePageURL: nil
        )
        XCTAssertTrue(UpdateStatus.updateAvailable(update).statusText.contains("0.0.12"))
        XCTAssertTrue(UpdateStatus.newerThanFeed(latest: update).statusText.contains("0.0.12"))
    }
}
```

在 `ReleaseNotesMarkdownTests.swift` 写入：

```swift
import XCTest
@testable import Orbit

final class ReleaseNotesMarkdownTests: XCTestCase {
    func testHeadingsParagraphsAndLists() {
        let blocks = ReleaseNotesMarkdownParser.parse("""
        # 标题
        这是第一段。
        这是第二段。

        ## 新增
        - 支持自动更新
        - 关于窗口
        1. 第一步
        2. 第二步

        > 提示
        ---
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "标题"),
            .paragraph("这是第一段。 这是第二段。"),
            .heading(level: 2, text: "新增"),
            .bullet("支持自动更新"),
            .bullet("关于窗口"),
            .numbered(1, "第一步"),
            .numbered(2, "第二步"),
            .quote("提示"),
            .divider
        ])
    }

    func testFencedCodeBlockIncludingUnclosedFence() {
        XCTAssertEqual(
            ReleaseNotesMarkdownParser.parse("```\nlet a = 1\n```"),
            [.code("let a = 1")]
        )
        XCTAssertEqual(
            ReleaseNotesMarkdownParser.parse("```\nlet a = 1"),
            [.code("let a = 1")]
        )
    }

    func testEmptyAndChinese() {
        XCTAssertEqual(ReleaseNotesMarkdownParser.parse(""), [])
        XCTAssertEqual(
            ReleaseNotesMarkdownParser.parse("修复了中文输入问题。"),
            [.paragraph("修复了中文输入问题。")]
        )
    }
}
```

### Step 2: 运行测试，确认失败

```bash
cd orbit-app
xcodegen generate
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -destination 'platform=macOS' test \
  -only-testing:OrbitTests/UpdateStatusTests \
  -only-testing:OrbitTests/ReleaseNotesMarkdownTests 2>&1 | tail -20
```

Expected: 编译失败或测试失败，提示 `AppVersion` / `UpdateStatusReducer` / `ReleaseNotesMarkdownParser` 不存在。**必须实际看到失败**，再进入下一步。

### Step 3: 实现 `UpdateStatus.swift`

```swift
import Foundation

struct AppVersion: Equatable {
    let shortVersion: String
    let build: String

    static var current: AppVersion {
        let info = Bundle.main.infoDictionary
        return AppVersion(
            shortVersion: info?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            build: info?["CFBundleVersion"] as? String ?? "0"
        )
    }

    var displayText: String { "版本 \(shortVersion) (\(build))" }
}

struct AvailableUpdate: Equatable {
    let shortVersion: String
    let build: String
    let title: String
    let notes: String?
    let notesFormat: String?
    let fullNotesURL: URL?
    let releasePageURL: URL?

    var displayVersion: String { shortVersion.isEmpty ? build : shortVersion }
}

enum NoUpdateReason: Equatable {
    case latest
    case newerThanFeed
    case systemTooOld
    case systemTooNew
    case hardwareUnsupported
    case unknown
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(AvailableUpdate)
    case newerThanFeed(latest: AvailableUpdate?)
    case failed(String)
    case disabled
}

enum UpdateEvent: Equatable {
    case started
    case found(AvailableUpdate)
    case noUpdate(reason: NoUpdateReason, latest: AvailableUpdate?)
    case failure(String)
    case finished
}

enum UpdateStatusReducer {
    static func reduce(_ status: UpdateStatus, event: UpdateEvent) -> UpdateStatus {
        switch event {
        case .started:
            return .checking
        case .found(let update):
            return .updateAvailable(update)
        case .noUpdate(let reason, let latest):
            switch reason {
            case .latest: return .upToDate
            case .newerThanFeed: return .newerThanFeed(latest: latest)
            case .systemTooOld: return .failed("线上稳定版需要更高版本的 macOS")
            case .systemTooNew: return .failed("线上稳定版暂不支持当前 macOS 版本")
            case .hardwareUnsupported: return .failed("线上稳定版不支持当前硬件架构")
            case .unknown: return .upToDate
            }
        case .failure(let message):
            return .failed(message)
        case .finished:
            if case .checking = status { return .upToDate }
            return status
        }
    }
}

extension UpdateStatus {
    var statusText: String {
        switch self {
        case .idle: return "尚未检查更新"
        case .checking: return "正在检查更新…"
        case .upToDate: return "已是最新版本"
        case .updateAvailable(let update): return "发现新版本 \(update.displayVersion)"
        case .newerThanFeed(let latest):
            if let latest { return "当前版本高于线上稳定版（线上：\(latest.displayVersion)）" }
            return "当前版本高于线上稳定版"
        case .failed(let message): return "检查更新失败：\(message)"
        case .disabled: return "更新检查已在测试模式下禁用"
        }
    }
}
```

### Step 4: 实现 `ReleaseNotesMarkdown.swift`

```swift
import Foundation

enum ReleaseNotesBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(Int, String)
    case code(String)
    case quote(String)
    case divider
}

enum ReleaseNotesMarkdownParser {
    static func parse(_ markdown: String) -> [ReleaseNotesBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [ReleaseNotesBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }
            if let heading = headingBlock(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            if let bullet = bulletBlock(trimmed) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                continue
            }
            if let numbered = numberedBlock(trimmed) {
                flushParagraph()
                blocks.append(.numbered(numbered.0, numbered.1))
                continue
            }
            paragraph.append(trimmed)
        }

        if inCode {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func headingBlock(_ line: String) -> ReleaseNotesBlock? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, text: String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private static func bulletBlock(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if line.hasPrefix(prefix) { return String(line.dropFirst(2)) }
        }
        return nil
    }

    private static func numberedBlock(_ line: String) -> (Int, String)? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let prefix = String(line[..<space])
        guard prefix.hasSuffix("."), let number = Int(prefix.dropLast()) else { return nil }
        let text = String(line[line.index(after: space)...])
        return (number, text)
    }
}
```

### Step 5: 再次运行测试

```bash
cd orbit-app
xcodegen generate
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -destination 'platform=macOS' test \
  -only-testing:OrbitTests/UpdateStatusTests \
  -only-testing:OrbitTests/ReleaseNotesMarkdownTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` 或 `Test Suite ... passed`。

### Step 6: Commit

```bash
git add orbit-app/Orbit/Update/UpdateStatus.swift \
        orbit-app/Orbit/Update/ReleaseNotesMarkdown.swift \
        orbit-app/OrbitTests/UpdateStatusTests.swift \
        orbit-app/OrbitTests/ReleaseNotesMarkdownTests.swift \
        orbit-app/Orbit.xcodeproj
git commit -m "feat: add update status model and release notes parser"
```

---

## Task 2: UpdateManager（Sparkle 唯一入口）

**Files:**
- Create: `orbit-app/Orbit/Update/UpdateManager.swift`

### Step 1: 实现

```swift
import Foundation
import Sparkle

@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateManager()

    @Published private(set) var status: UpdateStatus = .idle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var isInstallingUpdate = false
    @Published private(set) var currentVersion = AppVersion.current

    let isDisabledForTesting: Bool

    private var hasStarted = false
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var updater: SPUUpdater { updaterController.updater }

    private override init() {
        isDisabledForTesting =
            ProcessInfo.processInfo.environment["ORBIT_DISABLE_UPDATE_CHECKS"] == "1"
        super.init()
        if isDisabledForTesting { status = .disabled }
    }

    /// 必须在 applicationDidFinishLaunching 调用一次。
    /// Sparkle 要求 startUpdater 之后、下一个 runloop 之前发起启动检查。
    func startAtLaunch() {
        guard !isDisabledForTesting, !hasStarted else { return }
        hasStarted = true
        updaterController.startUpdater()
        refreshFromUpdater()
        guard updater.automaticallyChecksForUpdates, updater.canCheckForUpdates else { return }
        status = .checking
        updater.checkForUpdatesInBackground()
    }

    /// 用户主动检查：显示 Sparkle 标准进度/更新窗口。
    func checkForUpdates() {
        guard canPerformCheck else { return }
        status = .checking
        updater.checkForUpdates()
    }

    /// 关于窗口里的无弹窗探测，只刷新状态。
    func checkForUpdateInformation() {
        guard canPerformCheck, !updater.sessionInProgress else { return }
        status = .checking
        updater.checkForUpdateInformation()
    }

    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        guard !isDisabledForTesting else { return }
        automaticallyChecksForUpdates = value
        updater.automaticallyChecksForUpdates = value
        refreshFromUpdater()
    }

    func refreshFromUpdater() {
        guard !isDisabledForTesting, hasStarted else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
        currentVersion = .current
    }

    private var canPerformCheck: Bool {
        !isDisabledForTesting && hasStarted && updater.canCheckForUpdates
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .updateAvailable(AvailableUpdate(item: item))
        refreshFromUpdater()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let nsError = error as NSError
        let latest = (nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem)
            .map(AvailableUpdate.init(item:))
        status = UpdateStatusReducer.reduce(
            status,
            event: .noUpdate(reason: NoUpdateReason(userInfo: nsError.userInfo), latest: latest)
        )
        refreshFromUpdater()
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor check: SPUUpdateCheck,
                 error: Error?) {
        if let error {
            let nsError = error as NSError
            let ignored = nsError.code == SUError.noUpdateError.rawValue
                || nsError.code == SUError.installationCanceledError.rawValue
            if !ignored, case .checking = status {
                status = .failed(error.localizedDescription)
            }
        } else if case .checking = status {
            status = .upToDate
        }
        refreshFromUpdater()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        isInstallingUpdate = false
        if nsError.code != SUError.installationCanceledError.rawValue {
            status = .failed(error.localizedDescription)
        }
        refreshFromUpdater()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isInstallingUpdate = true
    }
}

private extension AvailableUpdate {
    init(item: SUAppcastItem) {
        self.init(
            shortVersion: item.displayVersionString,
            build: item.versionString,
            title: item.title ?? "",
            notes: item.itemDescription,
            notesFormat: item.itemDescriptionFormat,
            fullNotesURL: item.fullReleaseNotesURL,
            releasePageURL: item.infoURL
        )
    }
}

private extension NoUpdateReason {
    init(userInfo: [String: Any]) {
        let raw = (userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
        switch raw {
        case SPUNoUpdateFoundReason.onLatestVersion.rawValue:
            self = .latest
        case SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue:
            self = .newerThanFeed
        case SPUNoUpdateFoundReason.systemIsTooOld.rawValue:
            self = .systemTooOld
        case SPUNoUpdateFoundReason.systemIsTooNew.rawValue:
            self = .systemTooNew
        case SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue:
            self = .hardwareUnsupported
        default:
            self = .unknown
        }
    }
}
```

### Step 2: 编译

```bash
cd orbit-app && xcodegen generate
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`。

如果报 actor 隔离错误，给 `AppDelegate` 标注 `@MainActor`，或把 `UpdateManager.shared` 调用放进 `Task { @MainActor in ... }`（但 `startAtLaunch` 必须保持在 `applicationDidFinishLaunching` 同步调用，以保证 runloop 时序）。

如果 Sparkle 导入符号名不一致，用 Xcode 自动补全确认以下名称：
`SPUNoUpdateFoundReason.onLatestVersion`、`SUError.noUpdateError`、`SUError.installationCanceledError`。

### Step 3: Commit

```bash
git add orbit-app/Orbit/Update/UpdateManager.swift orbit-app/Orbit.xcodeproj
git commit -m "feat: add shared Sparkle update manager"
```

---

## Task 3: AppDelegate 接入与安装退出

**Files:**
- Modify: `orbit-app/Orbit/AppDelegate.swift`

### Step 1: 修改

- 删除 `import Sparkle`。
- 删除 `private let updaterController = SPUStandardUpdaterController(...)`。
- 删除 `applicationDidFinishLaunching` 里的 `.checkForUpdates` observer 注册。
- 删除 `@objc private func checkForUpdates()`。
- 删除只用于移除 observer 的 `deinit`。
- 在 `applicationDidFinishLaunching` 里加：

```swift
UpdateManager.shared.startAtLaunch()
```

- 在 `applicationShouldTerminate` 的最前面加：

```swift
if UpdateManager.shared.isInstallingUpdate {
    return .terminateNow
}
```

保留 `applicationShouldTerminateAfterLastWindowClosed`、`applicationShouldHandleReopen`、`applicationWillTerminate` 的现有逻辑。

### Step 2: 编译并运行单测

```bash
cd orbit-app && xcodegen generate
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`。

### Step 3: Commit

```bash
git add orbit-app/Orbit/AppDelegate.swift orbit-app/Orbit.xcodeproj
git commit -m "feat: start update checks at launch and allow install termination"
```

---

## Task 4: 关于窗口

**Files:**
- Create: `orbit-app/Orbit/Views/AboutWindowController.swift`
- Create: `orbit-app/Orbit/Views/AboutView.swift`
- Create: `orbit-app/Orbit/Views/ReleaseNotesView.swift`

### Step 1: `AboutWindowController.swift`

仿照 `orbit-app/Orbit/Views/SettingsWindowController.swift`：

```swift
import SwiftUI
import AppKit

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()

    private var windowController: NSWindowController?

    private override init() {
        super.init()
    }

    func open() {
        UpdateManager.shared.refreshFromUpdater()

        if let wc = windowController, let window = wc.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = AboutView(updateManager: .shared)
            .frame(minWidth: 420, minHeight: 480)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "关于 Orbit"
        window.setContentSize(NSSize(width: 480, height: 640))
        window.minSize = NSSize(width: 420, height: 480)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.delegate = self

        let wc = NSWindowController(window: window)
        windowController = wc
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
    }
}
```

### Step 2: `AboutView.swift`

要求：
- `@ObservedObject var updateManager: UpdateManager`
- 顶部：64pt app icon（`NSApp.applicationIconImage`，没有则 `Image(systemName: "terminal")`）、`Orbit`、`原生 macOS SSH 终端`、`updateManager.currentVersion.displayText`，版本行加 `accessibilityIdentifier("aboutVersionLabel")`。
- `SettingsGroup("更新")`（该组件在 `SettingsView.swift` 是 internal，可直接用）：
  - 状态图标 + `updateManager.status.statusText`，加 `accessibilityIdentifier("aboutUpdateStatusLabel")`。
  - `更新渠道：稳定版`。
  - `上次检查：...`，从未时显示 `从未`，加 `accessibilityIdentifier("aboutLastCheckLabel")`。
  - `Toggle("自动检查更新", isOn: ...)`，读写 `updateManager.automaticallyChecksForUpdates` / `setAutomaticallyChecksForUpdates`，`.toggleStyle(.switch)`，测试模式禁用，加 `accessibilityIdentifier("aboutAutoCheckToggle")`。
  - 主按钮：
    - `.updateAvailable(update)`：`安装更新 \(update.displayVersion)`，调用 `updateManager.checkForUpdates()`，加 `accessibilityIdentifier("aboutInstallUpdateButton")`。
    - 其他：`检查更新`（`.checking` 时显示 `正在检查…`），调用 `updateManager.checkForUpdateInformation()`，加 `accessibilityIdentifier("aboutCheckForUpdatesButton")`。
    - `.disabled(updateManager.isDisabledForTesting || updateManager.status == .checking)`。
- 当 `.updateAvailable(update)` 且 `update.notes` 非空：`SettingsGroup("更新说明")` 内放 `ReleaseNotesView(markdown: notes)`，加 `accessibilityIdentifier("aboutReleaseNotes")`；如果有 `fullNotesURL ?? releasePageURL`，加 `Link("查看完整更新说明", destination: url)`。
- 整体 `ScrollView` + `VStack(alignment: .leading, spacing: 18)` + `.padding(24)`。

状态图标建议：
- `.checking` → `ProgressView().controlSize(.small)`
- `.updateAvailable` → `arrow.down.circle.fill`，accent
- `.upToDate` → `checkmark.circle.fill`，green
- `.failed` → `exclamationmark.triangle.fill`，red
- `.newerThanFeed` → `info.circle.fill`，secondary
- `.disabled` → `gearshape`，secondary
- `.idle` → `clock`，secondary

`lastCheckText`：

```swift
private var lastCheckText: String {
    guard let date = updateManager.lastCheckDate else { return "从未" }
    return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
}
```

### Step 3: `ReleaseNotesView.swift`

- 输入 `let markdown: String`。
- `ReleaseNotesMarkdownParser.parse(markdown)` 渲染：
  - `.heading(level, text)`：1–2 级 15/13pt semibold，3–6 级 12pt semibold。
  - `.paragraph`：12pt。
  - `.bullet`：HStack 圆点 + 文本。
  - `.numbered(n, text)`：HStack `"\(n)."` + 文本。
  - `.code`：等宽 11pt，`Color.primary.opacity(0.05)` 背景，圆角 4。
  - `.quote`：左侧 2pt secondary 竖线 + secondary 文本。
  - `.divider`：`Divider()`。
- 行内 Markdown：

```swift
private func inlineText(_ text: String) -> Text {
    if let attributed = try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) {
        return Text(attributed)
    }
    return Text(text)
}
```

- 不引入 WebView、不引入第三方库。

### Step 4: 编译

```bash
cd orbit-app && xcodegen generate
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`。

### Step 5: Commit

```bash
git add orbit-app/Orbit/Views/AboutWindowController.swift \
        orbit-app/Orbit/Views/AboutView.swift \
        orbit-app/Orbit/Views/ReleaseNotesView.swift \
        orbit-app/Orbit.xcodeproj
git commit -m "feat: add standalone about window with update status"
```

---

## Task 5: 应用菜单

**Files:**
- Modify: `orbit-app/Orbit/OrbitApp.swift`

### Step 1: 修改 `OrbitCommands`

- 在 `OrbitCommands` 里加：

```swift
@ObservedObject private var updateManager = UpdateManager.shared
```

- 删除 `CommandGroup(after: .toolbar)` 里的旧「检查更新...」按钮（大约在 79–81 行）。
- 在 `body` 里加：

```swift
CommandGroup(replacing: .appInfo) {
    Button("关于 Orbit") {
        AboutWindowController.shared.open()
    }
}

CommandGroup(after: .appInfo) {
    Button("检查更新…") {
        updateManager.checkForUpdates()
    }
    .disabled(!updateManager.canCheckForUpdates || updateManager.status == .checking)
}
```

- 删除 extension 里的 `static let checkForUpdates = Notification.Name("checkForUpdates")`。

### Step 2: 编译

```bash
cd orbit-app && xcodegen generate
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`。

### Step 3: Commit

```bash
git add orbit-app/Orbit/OrbitApp.swift orbit-app/Orbit.xcodeproj
git commit -m "feat: expose about and check for updates in app menu"
```

---

## Task 6: Info.plist 更新配置

**Files:**
- Modify: `orbit-app/Orbit/Info.plist`

### Step 1: 修改

保留现有：

```xml
<key>SUAutomaticallyUpdate</key>
<false/>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/ibreez3/orbit/develop/docs/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>KKV9nwM4SemCZDc2S8KqGGGPa5SzX51x1NG7v7KNUdI=</string>
```

新增（放在 `SUPublicEDKey` 后）：

```xml
<key>SURequireSignedFeed</key>
<true/>
<key>SUVerifyUpdateBeforeExtraction</key>
<true/>
```

**注意**：这两个键必须同时开启；Sparkle 启动时会校验。若后续端到端升级测试在 ad-hoc 签名下失败，才允许移除这两个键，并保留 DMG 的 EdDSA 签名校验。

### Step 2: 验证 plist

```bash
plutil -lint orbit-app/Orbit/Info.plist
```

Expected: `orbit-app/Orbit/Info.plist: OK`。

### Step 3: Commit

```bash
git add orbit-app/Orbit/Info.plist
git commit -m "chore: require signed Sparkle feed"
```

---

## Task 7: UI 测试

**Files:**
- Modify: `orbit-app/OrbitUITests/OrbitUITests.swift`

### Step 1: 测试模式环境变量

在 `setUpWithError` 里，`app.launch()` 之前加：

```swift
app.launchEnvironment["ORBIT_DISABLE_UPDATE_CHECKS"] = "1"
```

### Step 2: 新增测试

```swift
func testAboutWindowShowsVersionAndStatus() {
    let appMenu = app.menuBars.menuBarItems["Orbit"]
    XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
    appMenu.click()

    let aboutItem = app.menuItems["关于 Orbit"]
    XCTAssertTrue(aboutItem.waitForExistence(timeout: 5))
    aboutItem.click()

    let about = app.windows["关于 Orbit"]
    XCTAssertTrue(about.waitForExistence(timeout: 10))

    let version = app.staticTexts["aboutVersionLabel"]
    XCTAssertTrue(version.waitForExistence(timeout: 5))
    XCTAssertTrue((version.value as? String ?? "").contains("版本"))

    let status = app.staticTexts["aboutUpdateStatusLabel"]
    XCTAssertTrue(status.exists)
    XCTAssertEqual(status.value as? String, "更新检查已在测试模式下禁用")

    let toggle = app.switches["aboutAutoCheckToggle"]
    XCTAssertTrue(toggle.exists)
    XCTAssertFalse(toggle.isEnabled)

    app.typeKey("w", modifierFlags: [.command])
    XCTAssertFalse(about.waitForExistence(timeout: 2))
}
```

如果 `app.menuBars.menuBarItems["Orbit"]` 找不到，打印 `app.menuBars.menuBarItems.allElementsBoundByIndex.map(\.label)` 确认真实标签；不要用硬编码猜测。

### Step 3: 运行 UI 测试

```bash
cd orbit-app
xcodebuild -project Orbit.xcodeproj -scheme OrbitUITests -configuration Debug \
  -destination 'platform=macOS' test \
  -only-testing:OrbitUITests/OrbitUITests/testAboutWindowShowsVersionAndStatus 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`。

### Step 4: Commit

```bash
git add orbit-app/OrbitUITests/OrbitUITests.swift
git commit -m "test: cover about window from app menu"
```

---

## Task 8: appcast 工具（Python，stdlib only）

**Files:**
- Create: `scripts/appcast_lib.py`
- Create: `scripts/update-appcast.py`
- Create: `scripts/tests/test_appcast_lib.py`

### Step 1: 先写 Python 测试

`scripts/tests/test_appcast_lib.py` 开头加（保证从仓库根目录运行 `unittest discover` 时能 import）：

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scripts.appcast_lib import (
    parse_existing_appcast,
    parse_stable_tag,
    render_appcast,
    sanitize_notes,
    validate_release,
    verify_appcast,
)
```

至少覆盖：

- 稳定 tag：`v0.0.12` 通过；`v0.0.12-pre.1`、`v0.0.12-rc1`、`0.0.12` 拒绝。
- 单调 build：
  - 现有 12，新 13 → 通过。
  - 现有 12，新 11 → 失败。
  - 现有 12，新 12，同一 tag → 通过（重跑）。
  - 现有 12，新 12，不同 tag → 失败。
- `sanitize_notes("a]]>b")` 输出仍能被 XML 解析，且解析回来的文本包含 `a]]>b`。
- 生成的 XML 只有一个 item；channel title 为 `Orbit Updates`；item title 为 `Orbit {version}`；没有 `releaseNotesLink`；有 `description sparkle:format="markdown"`；有 `fullReleaseNotesLink`；enclosure 的 `sparkle:version` 等于 build。
- `verify_appcast` 拒绝：缺 description、缺 full link、出现 releaseNotesLink、build/version 不匹配、要求签名但签名块缺失。

运行：

```bash
python3 -m unittest discover -s scripts/tests -v
```

Expected: 先失败（模块不存在）。**看到失败后再实现。**

### Step 2: `scripts/appcast_lib.py`

关键 API：

```python
STABLE_TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

def parse_stable_tag(tag: str) -> tuple[int, int, int]:
    """不是稳定 tag 就抛 ValueError。"""

def sanitize_notes(markdown: str) -> str:
    """CRLF→LF；删除 XML 非法控制字符；把 ]]> 拆成 ]]]]><![CDATA[>；strip。"""

def parse_existing_appcast(path) -> dict:
    """返回 {'build': int|None, 'tag': str|None, 'pub_date': str|None}。
    文件不存在返回空值。ElementTree 只解析到最后一个 </rss>，忽略签名注释。"""

def validate_release(*, existing, tag, version, build, notes, url, signature, length) -> None:
    """稳定 tag、version 与 tag 一致、build 正整数、notes 非空、
    URL 包含 /download/{tag}/、signature/length 存在、单调 build 校验。"""

def render_appcast(*, tag, version, build, url, signature, length, notes,
                   full_notes_url, pub_date, minimum_system_version="13.0") -> str:
    """单 item 稳定版 XML；description 用 CDATA + sparkle:format="markdown"；
    不写 sparkle:releaseNotesLink。"""

def verify_appcast(path, *, tag, version, build, require_signature=False) -> None:
    """结构校验；require_signature 时检查 raw text 含 sparkle-signatures: 和 edSignature:。"""
```

实现提示：

- 解析 appcast 时，签名块是根元素后的注释，ElementTree 会报 `junk after document element`。先截断到最后一个 `</rss>`：

```python
text = Path(path).read_text(encoding="utf-8")
end = text.rfind("</rss>")
root = ET.fromstring(text[: end + len("</rss>")])
```

- `sparkle:version` 用 `item.find(f"{{{SPARKLE_NS}}}version").text`。
- 从 enclosure URL 提取 tag：`re.search(r"/download/([^/]+)/", url)`。
- `pubDate` 用 `email.utils.format_datetime(datetime.now(timezone.utc))`，格式应类似 `Tue, 10 Nov 2026 00:51:21 +0000`。
- 生成 XML 时 `sparkle:version`、`sparkle:shortVersionString`、`sparkle:minimumSystemVersion` 都是 enclosure 属性。
- 写文件用同目录临时文件 + `os.replace`，保证原子性。

### Step 3: `scripts/update-appcast.py`

CLI：

```bash
python3 scripts/update-appcast.py \
  --appcast docs/appcast.xml \
  --tag v0.0.12 \
  --version 0.0.12 \
  --build 13 \
  --url https://github.com/ibreez3/orbit/releases/download/v0.0.12/Orbit-v0.0.12-AppleSilicon.dmg \
  --signature "$SPARKLE_SIGNATURE" \
  --length "$SPARKLE_LENGTH" \
  --notes-file "$RUNNER_TEMP/orbit-release-notes.md" \
  --full-notes-url https://github.com/ibreez3/orbit/releases/tag/v0.0.12
```

模式：

- `--check`：只做校验，不写文件。
- `--dry-run`：把生成的 XML 打到 stdout，不写文件。
- 默认：原子写入 `--appcast`。
- `--verify --require-signature`：校验已有 appcast（签名步骤之后调用）。

参数 `--minimum-system-version` 默认 `13.0`。`--allow-empty-notes` 只用于测试。

运行本地 tests：

```bash
python3 -m unittest discover -s scripts/tests -v
```

Expected: 全部通过。

### Step 4: Commit

```bash
git add scripts/appcast_lib.py scripts/update-appcast.py scripts/tests/test_appcast_lib.py
git commit -m "feat: add testable Sparkle appcast tooling"
```

---

## Task 9: 发布工作流改造

**Files:**
- Modify: `.github/workflows/release-dmg.yml`

### Step 1: workflow 级 concurrency

在 `permissions:` 后加：

```yaml
concurrency:
  group: orbit-release
  cancel-in-progress: false
```

### Step 2: 去掉危险默认 tag

`workflow_dispatch.inputs.tag` 删除 `default: "v0.0.6-pre"`，改为必填无默认值。更新 `update_appcast` 描述为：

```yaml
description: "Update stable appcast (ignored for preview tags)"
```

### Step 3: Resolve release tag 增加 stable/base_version

在 `Resolve release tag` 里：

```bash
BASE_VERSION="${VERSION%%-*}"
if [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  STABLE="true"
else
  STABLE="false"
fi
echo "base_version=$BASE_VERSION" >> "$GITHUB_OUTPUT"
echo "stable=$STABLE" >> "$GITHUB_OUTPUT"
```

删除不可达的 `else TAG="v0.0.6-pre"`。

### Step 4: 新增版本校验 step（所有 release 都跑）

在 `Prepare toolchain` 之前加 `Validate release versions`：

- tag 格式合法。
- `project.yml` 的 `MARKETING_VERSION` 等于 `BASE_VERSION`。
- `CURRENT_PROJECT_VERSION` 是正整数。
- 找上一个 tag：`PREV_TAG="$(git tag --sort=-creatordate --merged "${TAG}^" | head -1 || true)"`。
- 如果上一个 tag 有 `orbit-app/project.yml`，取它的 `CURRENT_PROJECT_VERSION`。
- 要求 `current_build > previous_build`，否则 `exit 1`。
- 稳定版要求 `SPARKLE_PRIVATE_KEY` 非空，否则 `exit 1`。
- 输出 tag、stable、marketing version、build、previous tag/build。

解析 `project.yml` 的推荐写法（避免 yq 依赖）：

```bash
MARKETING_VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' orbit-app/project.yml | head -1)"
CURRENT_BUILD="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' orbit-app/project.yml | head -1)"
```

### Step 5: 新增 Fetch release notes step

仅稳定版：

```yaml
- name: Fetch release notes
  if: steps.release.outputs.stable == 'true'
  shell: bash
  run: |
    set -euo pipefail
    TAG="${{ steps.release.outputs.tag }}"
    gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json body --jq .body \
      > "$RUNNER_TEMP/orbit-release-notes.md"
    if [ -z "$(tr -d '[:space:]' < "$RUNNER_TEMP/orbit-release-notes.md")" ]; then
      echo "::error::Stable release notes are empty"
      exit 1
    fi
```

### Step 6: 改造 appcast 更新 step

- 条件改为：

```yaml
if: env.SPARKLE_PRIVATE_KEY != '' && steps.release.outputs.stable == 'true' && (github.event_name != 'workflow_dispatch' || inputs.update_appcast)
```

- 切换分支前先 `git checkout -- orbit-app/Orbit.xcodeproj 2>/dev/null || true`。
- 用 `scripts/update-appcast.py` 替代内联 Python：

```bash
python3 scripts/update-appcast.py \
  --appcast docs/appcast.xml \
  --tag "$TAG" \
  --version "$VERSION" \
  --build "$BUILD_VERSION" \
  --url "$URL" \
  --signature "$SPARKLE_SIGNATURE" \
  --length "$SPARKLE_LENGTH" \
  --notes-file "$RUNNER_TEMP/orbit-release-notes.md" \
  --full-notes-url "https://github.com/$GITHUB_REPOSITORY/releases/tag/$TAG"
```

- 在写之前先用现有私钥验证 develop 上的 appcast：

```bash
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - --verify docs/appcast.xml
```

- 写完后 `python3 scripts/update-appcast.py --check ...` 或 `xmllint --noout docs/appcast.xml` 校验。

### Step 7: 签名和推送 step

- 条件同 Step 6。
- `sign_update` 后 `--verify`。
- 再加结构校验：

```bash
python3 scripts/update-appcast.py --verify docs/appcast.xml \
  --tag "$TAG" --version "$VERSION" --build "$BUILD_VERSION" --require-signature
```

- 提交/推送 `develop`。推送失败重试一次：

```bash
git push origin develop || { git pull --rebase origin develop && git push origin develop; }
```

### Step 8: 上传 DMG 的 release 缺失处理

`Upload DMG to GitHub Release` 里，如果 `gh release view` 不存在：

- 稳定版：`echo "::error::Create the GitHub release with notes before dispatching a stable release"; exit 1`。
- 预览版：保留现有 `gh release create ... --notes "Orbit macOS preview release."`。

### Step 9: 验证 YAML

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release-dmg.yml"); puts "YAML OK"'
```

Expected: `YAML OK`。

### Step 10: Commit

```bash
git add .github/workflows/release-dmg.yml scripts/appcast_lib.py scripts/update-appcast.py scripts/tests/test_appcast_lib.py
git commit -m "feat: publish stable-only signed appcast with embedded release notes"
```

---

## Task 10: 文档与 CHANGELOG

**Files:**
- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`
- Modify: `TODO.md`
- Modify: `CHANGELOG.md`

### Step 1: 更新发布流程文档

在 `CLAUDE.md` 和 `AGENTS.md` 的发布流程部分写明：

- 稳定 tag：`vX.Y.Z`；预览 tag：任何带后缀的版本（`-pre`、`-rc`）。
- 只有稳定 tag 会更新 `docs/appcast.xml`；预览版不会进入自动更新通道。
- 每次发布（含预览版）都必须提升 `CURRENT_PROJECT_VERSION`，且严格大于上一个 tag 的 build。
- 稳定版的 GitHub Release 正文必须非空；工作流会把正文嵌入 appcast 作为更新说明。
- 不要手工编辑 `docs/appcast.xml`，它是签名文件。
- 预览版用户需要等下一个 build 更高的稳定版才能自动升级。
- 旧版本（≤ v0.0.8）因公钥轮换仍需一次手动安装。

同时修正 `AGENTS.md` 里“创建 GitHub prerelease”与 `CLAUDE.md` 里“不要勾选 prerelease”的不一致：以 `CLAUDE.md` 为准，GitHub Release 的 Latest/Pre-release 标记不影响 Sparkle；自动更新通道只由 tag 后缀决定。

### Step 2: 更新 TODO/CHANGELOG

- `TODO.md` 里把“自动更新机制（例如 Sparkle）”标记完成，注明“稳定版通道；预览版不更新 appcast”。
- `CHANGELOG.md` 增加 Unreleased：
  - 新增独立「关于 Orbit」窗口和更新状态展示。
  - 启动时自动检查更新。
  - 只发布稳定版到 appcast，更新说明嵌入 appcast。
  - 修复 build 号重复、appcast 无单调校验、旧检查间隔导致不弹窗。
  - 启用签名 feed 校验。

### Step 3: Commit

```bash
git add CLAUDE.md AGENTS.md TODO.md CHANGELOG.md
git commit -m "docs: document stable-only auto-update flow"
```

---

## Task 11: 全量验证

### Step 1: Python

```bash
python3 -m unittest discover -s scripts/tests -v
```

Expected: 全部通过。

### Step 2: Xcode 工程与构建

```bash
cd orbit-app && xcodegen generate && cd ..
./scripts/build-rust.sh
cd orbit-app
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`。

如果本机没有 `cargo` 或 Rust 静态库，记录到最终报告，不要伪造构建成功；优先在 CI 或装好 Rust 的机器上验证。

### Step 3: 单元测试

```bash
cd orbit-app
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -destination 'platform=macOS' test \
  -only-testing:OrbitTests/UpdateStatusTests \
  -only-testing:OrbitTests/ReleaseNotesMarkdownTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`。

### Step 4: UI 测试

```bash
cd orbit-app
xcodebuild -project Orbit.xcodeproj -scheme OrbitUITests -configuration Debug \
  -destination 'platform=macOS' test \
  -only-testing:OrbitUITests/OrbitUITests/testAboutWindowShowsVersionAndStatus 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`。

### Step 5: appcast dry-run

```bash
python3 scripts/update-appcast.py --dry-run \
  --appcast docs/appcast.xml \
  --tag v0.0.12 \
  --version 0.0.12 \
  --build 13 \
  --url https://github.com/ibreez3/orbit/releases/download/v0.0.12/Orbit-v0.0.12-AppleSilicon.dmg \
  --signature TEST_SIGNATURE \
  --length 123456 \
  --notes-file /tmp/orbit-notes.md \
  --full-notes-url https://github.com/ibreez3/orbit/releases/tag/v0.0.12
```

`/tmp/orbit-notes.md` 可先写：

```markdown
### 新增
- 独立的「关于 Orbit」窗口
- 启动时自动检查更新

### 修复
- 修复部分用户收不到更新提示的问题
```

Expected: stdout 输出合法 XML，包含 `<description sparkle:format="markdown">`，不包含 `<sparkle:releaseNotesLink>`。

### Step 6: 手动端到端（有完整工具链时）

1. 安装 build 12 旧版，启动后应自动弹出 build 13 更新窗口，并显示嵌入的更新说明。
2. 打开「关于 Orbit」，检查版本、状态、上次检查时间、自动检查开关和「安装更新」。
3. 关闭自动检查后重启，确认启动不再检查；重新打开后恢复。
4. 安装一个 build 号高于线上稳定版的预览版，确认关于窗口显示「当前版本高于线上稳定版」。
5. 发布下一个更高 build 的稳定版，确认预览版用户能升级。
6. 开启 AI 会话时确认安装更新，app 应直接退出安装而不是弹出会话阻塞提示。
7. 空 release notes 的稳定发布应被工作流拒绝。

### Step 7: 最终报告

写明：
- 实际跑过的命令和结果。
- 哪些验证因环境缺失没跑（例如 cargo/Rust 静态库/UI 测试），不要写“应该通过”。
- 是否有偏离任务书的地方及原因。

---

## 3. 验收标准

- [x] 单元测试：`UpdateStatusTests`、`ReleaseNotesMarkdownTests` 全绿。
- [x] UI 测试：应用菜单能打开「关于 Orbit」，版本/状态/开关存在，测试模式下检查禁用。
- [x] Python 测试：appcast 稳定 tag、单调 build、CDATA、XML 结构、签名块校验全绿。
- [x] `xcodegen generate` 后工程可构建；没有手改 `.pbxproj`。
- [x] 启动时调用 `checkForUpdatesInBackground()`，且只在 `automaticallyChecksForUpdates == true` 时调用。
- [x] 关于窗口「检查更新」用 `checkForUpdateInformation()`，「安装更新」用 `checkForUpdates()`。
- [x] 菜单「关于 Orbit」替换标准 About；「检查更新…」在应用菜单。
- [x] stable tag 才更新 appcast；`-pre`/`-rc` 不更新。
- [x] 发布工作流有单调 build 校验；build 号不递增会失败。
- [x] release notes 嵌入 appcast；没有 `sparkle:releaseNotesLink`。
- [x] 稳定版 release notes 为空时工作流失败。
- [x] `docs/appcast.xml` 未被手工修改。
- [x] 功能分支未修改 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`。

## 4. 风险与注意

- **`SURequireSignedFeed` + ad-hoc 签名**：必须做一次真实「旧版 → 新版」升级验证；若失败，移除 `SURequireSignedFeed` 和 `SUVerifyUpdateBeforeExtraction`，保留 DMG 的 EdDSA 签名校验。
- **`SPARKLE_PRIVATE_KEY` 与 `SUPublicEDKey` 不匹配**：工作流只能验证签名自洽，无法证明与 app 公钥匹配；密钥轮换时必须同步更新 Info.plist。
- **旧版本（≤ v0.0.8）** 因公钥轮换无法自动安装，仍需一次手动安装；下个稳定版 release notes 要保留说明。
- **raw.githubusercontent.com 在部分网络不可达**：当前 feed 不变；后续可上 CDN/镜像，不在本任务范围。
- **关于窗口 Markdown 渲染是简化版**：复杂表格/图片降级为文本，完整内容通过「查看完整更新说明」打开。
- **不要创建第二个 updater**：`UpdateManager.shared` 是唯一 owner；`SPUStandardUpdaterController` 用 `startingUpdater: false`，在 `applicationDidFinishLaunching` 里手动 `startUpdater()`。
- **不要用 KVO**：状态由 delegate 回调和显式刷新驱动，避免 Swift 5.9 actor 隔离问题。
- **`checkForUpdateInformation()` 会更新 `SULastCheckTime` 并重排下次检查**：只在用户点击「检查更新」时调用，不要在关于窗口出现时调用。
- **`didFinishUpdateCycleFor` 的 `SUNoUpdateError` / `SUInstallationCanceledError` 不是失败**：不要显示红色错误。
- **`SUAllowsAutomaticUpdates` 不要加**：`SUAutomaticallyUpdate=false` 已经表达“不静默下载安装”，额外设置没有收益。
- **本地环境限制**：当前机器 `cargo` 不在 PATH、Rust 静态库未构建；完整构建和 UI 测试建议在 CI 或装好 Rust 后执行。


## 5. 本次执行记录（2026-11-10）

本地实现与可执行验证已完成，保留在 `feat/auto-update-about` 工作区。未提交、推送、创建 tag 或发布版本。上方工作流验收项由本地脚本执行和隔离输入验证，尚未触发真实 GitHub Release 工作流。

- [x] Task 1：先新增测试并实际观察类型缺失导致失败，再实现状态模型与 Markdown 解析器；测试通过。
- [x] Task 2–5：逐项加入 UpdateManager、AppDelegate 接入、关于窗口、菜单；每项均执行 Debug 构建并通过。
- [x] Task 6：签名 feed 配置与 plist 校验通过。
- [x] Task 7：关于窗口 UI 测试通过。
- [x] Task 8：先观察 Python 模块缺失导致测试失败，再实现 appcast 工具；11 项测试通过。
- [x] Task 9：工作流 YAML、所有 run 段的 Shell 语法和 12 个版本/渠道/说明校验场景通过。
- [x] Task 10：同步发布规则、TODO 与 CHANGELOG。
- [x] Task 11：完成本地构建、定向单元测试、UI 测试、appcast dry-run 与临时密钥签名验证。
- [ ] Task 11 手动端到端：正式签名旧版 → 新版下载、安装、重启，以及活动 AI 会话下的安装退出。
- [ ] Task 11 手动端到端：自动检查开关跨重启、预览版高于线上稳定版、后续更高 build 稳定版升级。

实际运行及结果（Xcode 命令在 `orbit-app` 目录执行）：

| 命令 / 验证 | 结果 |
|---|---|
| `PATH=/Users/sunyang/.cargo/bin:$PATH ./scripts/build-rust.sh` | 成功，生成 Apple Silicon Rust 静态库；本机实际已有 Rust，只是不在默认 PATH |
| `xcodegen generate` | 成功，工程仅由 XcodeGen 生成 |
| `xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build` | Task 2–5 分步构建成功 |
| `xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' test -only-testing:OrbitTests/UpdateStatusTests -only-testing:OrbitTests/ReleaseNotesMarkdownTests` | 最终 7 项测试通过，包含正常 Sparkle 结束与网络错误区分的回归测试 |
| `xcodebuild -project Orbit.xcodeproj -scheme OrbitUITests -configuration Debug -destination 'platform=macOS' test -only-testing:OrbitUITests/OrbitUITests/testAboutWindowShowsVersionAndStatus` | 最终 1 项 UI 测试通过，覆盖菜单、版本、状态、上次检查、禁用开关和按钮、关闭窗口 |
| `PATH=/Users/sunyang/.cargo/bin:$PATH make build-app` | Release 构建与签名、权限校验通过 |
| `./scripts/build-app.sh` | 最后一次按钮调整后重新构建并验证通过 |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v` | 11 项测试通过 |
| `ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release-dmg.yml"); puts "YAML OK"'` | YAML OK |
| 工作流全部 run 段执行 `bash -n`；在临时目录执行实际版本/渠道/说明校验脚本，隔离 Git/GitHub 输入 | 12 个场景通过，包含重复/倒退 build、版本不符、缺签名密钥、预览渠道、空说明拒绝 |
| `plutil -lint orbit-app/Orbit/Info.plist` | OK |
| 按 Task 11 参数执行 `scripts/update-appcast.py --dry-run` | 合法 XML，内嵌 Markdown，无外部 releaseNotesLink；未写入仓库 appcast |
| Sparkle 2.9.3 `sign_update --ed-key-file -` / `--verify`，再执行 `update-appcast.py --verify ... --require-signature` | 临时随机测试密钥签名文件与 feed、密码学验签、结构校验全部通过；未读取真实发布私钥 |
| `git diff --check` | 通过 |
| `git diff --exit-code -- docs/appcast.xml orbit-app/project.yml orbit-rs/include/orbit.h` | 无变化；版本号、公钥与 feed 地址未修改 |

与任务书示例的差异及原因：

- 修复示例 `didAbortWithError` 将 `SUNoUpdateError` 误标为失败的问题；只忽略 Sparkle 错误域内的无更新/取消安装，其他错误正常显示。
- 显式刷新检查状态；已有 Sparkle 更新会话时保留已发现版本状态，避免仅聚焦安装窗口后丢失可用版本提示。
- UI 测试首次受 macOS 恢复无窗口状态影响，在 setup 的首页断言失败；测试启动添加 `-ApplePersistenceIgnoreState YES` 后通过。版本与状态文本沿用项目现有 `textValue` 辅助方法。
- appcast 读取兼容 item 子节点及现有 enclosure 属性版本。发布脚本在切换 develop 前保存当前 tag 的工具副本，确保执行已验证的工具代码。
- 依据本会话授权规则，任务书中的提交步骤未执行。

未验证：真实 GitHub Actions 发布、正式密钥与 app 公钥匹配、真实跨版本安装/重启、旧版公钥迁移；本地临时密钥验签不替代这些验证。保留 `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`，发布前仍需按 Task 11 执行真实升级验收。构建中的既有 AgentGateway Swift 6 并发警告未在本任务修改。

## 6. 独立审查与修复（2026-11-10）

独立审查结论：无 Critical。两条 Important 已修复；一条 Minor 因可能破坏签名 feed 一并修复；其余 Minor 记录为待决。

已修复：

1. 发布工作流在 DMG 上传后切换 `develop` 时，可能被构建改写的 tracked 文件（`Cargo.lock`、cbindgen 头文件、Xcode 工程）阻塞。改为 `git switch --discard-changes develop`，强制丢弃这些改动后再拉取，避免“DMG 已发布但 appcast 未更新”。
2. 旧 feed 的预验签在签名密钥轮换时必然失败，且发生在 DMG 上传之后。改为非致命 warning：继续用当前密钥重新生成并签名；签名后的 `sign_update --verify` 与结构校验仍然强制。
3. 更新说明正文若包含 `<!-- sparkle-signatures:\n`，`sign_update` 会把它当作旧签名块截断，导致签名后的 feed 损坏。`sanitize_notes` 将该标记改写为 `<!-- sparkle-signatures :`，并新增回归测试。

独立复验：

- Swift 单测 7/7、关于窗口 UI 测试 1/1。
- Python 测试 12/12（含新增签名标记回归）。
- `plutil -lint`、工作流 YAML、`git diff --check` 通过。
- `PATH=/Users/sunyang/.cargo/bin:$PATH make build-app` Release 构建、codesign、权限校验通过。
- `docs/appcast.xml`、`orbit-app/project.yml`、`orbit-rs/include/orbit.h` 未修改。
- 审查者用 CryptoKit/Ed25519 验证当前 `docs/appcast.xml` 与 `SUPublicEDKey` 匹配。

仍待决（Minor）：

- `UpdateManager` 的启动检查与 delegate 到状态的路径缺少直接自动化覆盖（现有测试覆盖 reducer、错误过滤和 UI 菜单/窗口）。
- 关于窗口按钮未把 `canCheckForUpdates` 纳入 disabled 条件；极端 Sparkle 会话状态下可能点击无反馈。
- 未实现 skip-version delegate；用户在 Sparkle 弹窗选择“跳过此版本”后，关于窗口可能短暂保留安装按钮。
- 工作流 previous-tag 校验按 creatordate 只取一个 tag，回移/乱序 tag 场景下是启发式；appcast 已发布 build 校验仍是主防线。
- “12 个工作流场景”没有提交到仓库的测试 harness，当前可复现的只有单元测试与手工验证记录。

未验证：真实 GitHub Actions 发布、正式密钥轮换、真实跨版本下载安装/重启、活动 AI 会话下的安装退出。
