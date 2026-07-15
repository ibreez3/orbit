# AI 助手 Session 管理 + 数据隔离 + Agent 自动执行

## 概述

当前 AI 助手的消息全局存储在 `UserDefaults` 单一 key 下，所有服务器共享对话历史，无 session 概念。本次改造实现：
1. 按服务器隔离 AI 对话数据
2. Session 管理（/new, /sessions, /compact）
3. AI Agent 自动执行命令（读→执行→观察→再执行闭环）
4. 命令安全白名单
5. AI 面板可拖拽调节宽度

## 数据模型

### AISession

```swift
struct AISession: Codable, Identifiable {
    let id: String          // UUID
    let serverId: String    // 所属服务器
    var title: String       // 从首条用户消息截取
    var messages: [AIChatMessage]
    var createdAt: Date
    var updatedAt: Date
}
```

### AppState 变更

- **移除** `aiMessages: [AIChatMessage]`
- **新增**：
  - `aiSessions: [String: [AISession]]` — serverId → sessions 字典
  - `activeAISessionId: [String: String]` — tabId → sessionId
  - `aiPanelWidth: CGFloat = 280`
  - `aiPendingCommand: (command: String, sessionId: String)? = nil`

## 持久化

- 每个 serverId 独立存储：`UserDefaults` key `aiSessions_{serverId}` → JSON encode `[AISession]`
- `loadAISessions(serverId:)` / `saveAISessions(serverId:)`
- 面板宽度：`UserDefaults` key `aiPanelWidth`

## Session 生命周期

| 操作 | 行为 |
|------|------|
| 打开面板 | 加载当前 tab 的活跃 session（无则创建新 session，title=""） |
| 发送消息 | 追加到当前 session → 自动持久化 |
| 切换 tab | 切换活跃 session 到对应服务器的 |
| `/new` | 保存当前，创建空白新 session 为活跃 |
| `/sessions` | 显示当前服务器的 session 选择栏 |
| 关闭面板 | session 保留不丢 |

## Slash Commands

输入框中以 `/` 开头：

| 命令 | 功能 |
|------|------|
| `/new` | 保存当前 session，创建空 session 并激活 |
| `/sessions` | 在消息区顶部展示 session 列表（标题 + 时间），点击加载 |
| `/compact` | 取前 70% 消息发给 AI 做摘要，替换为一条 system summary 消息 |

### /compact 详细

1. 计算当前 session 消息总字符数
2. 取前 70% 消息 → 发送给 AI 做摘要（内部调用，不展示回复）
3. 替换前 70% 为一条 `role: "system"` 摘要消息
4. 后 30% + 新消息继续作为完整上下文

## AI Agent 自动执行

### 协议

AI 回复中使用特殊代码块：

````
```execute
ls -la /var/log
```
````

### 执行流程

```
User 提问 → AI 回复（含 ```execute） → 自动在 SSH session 执行
  → 捕获 stdout/stderr + exit code
  → 结果注入对话（role: "system"）
  → AI 继续分析输出 → 可再次 ```execute
  → 循环至无 ```execute → 给出最终结论
```

### AIChatMessage 扩展

新增 `AIChatMessage.commandResults: [AICommandResult]?` 字段，关联该消息的 execute 块。

## 命令安全白名单

### 自动执行（只读/诊断）

| 类别 | 命令例 |
|------|--------|
| 文件查看 | `ls`, `cat`, `head`, `tail`, `file`, `stat`, `du` |
| 文本处理 | `grep`, `awk`, `sed -n`, `wc`, `sort`, `uniq`, `cut`, `tr` (只读) |
| 系统信息 | `ps`, `top -bn1`, `free`, `df`, `uptime`, `uname`, `hostname`, `whoami`, `id` |
| 网络诊断 | `ping -c`, `curl -I`, `ss -tlnp`, `netstat`, `ip addr show`, `nslookup`, `dig` |
| 服务查看 | `systemctl status`, `journalctl`, `service ... status` |
| 进程 | `pgrep`, `pidof`, `lsof -p` (只读) |
| 日志 | `dmesg`, `last` |

### 需用户确认

- `rm`, `mv`, `cp`（写入文件）
- `chmod`, `chown`
- `kill`, `pkill`, `killall`
- `systemctl start/stop/restart`
- `apt install/remove`, `yum`, `brew`
- `dd`, `mkfs`
- `shutdown`, `reboot`
- 含 `sudo` 的任何命令
- 不在白名单中的命令

### 确认 UI

消息 bubble 中显示：
```
⚠️ AI 想执行: rm -rf /tmp/cache
[确认执行] [拒绝]
```

确认后执行并继续 Agent 循环；拒绝则告知 AI "用户拒绝了该操作"。

## AI 面板宽度可调

- 左边缘拖拽调节，范围 160pt ~ 600pt
- 宽度偏好持久化到 UserDefaults

## 实施范围

### 修改文件
- `AppState.swift` — 数据模型、session 管理、持久化
- `AIChatView.swift` — UI 重构、session 选择器、命令确认、面板宽度拖拽
- `OpenAIService.swift` — agent loop 支持
- `Models.swift` — 新增 `AISession`, `AICommandResult`

### 不涉及
- Rust/FFI 层
- 其他 View 组件
