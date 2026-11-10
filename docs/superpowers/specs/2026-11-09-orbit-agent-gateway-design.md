# Orbit AI Agent 接入设计

## 1. 目标

让本机运行的 AI Agent（Claude Code、Codex、DeepSeek Harness）通过 Orbit 使用已保存服务器的 SSH 执行能力，完成日志查看、容器排查、命令执行等运维工作，而 AI 永远拿不到服务器密码或私钥。

Orbit 承担三件事：

- 服务器的凭据保存、解密和 SSH 登录。
- 把“机器的执行能力”以稳定、结构化的方式暴露给 AI。
- 准入授权、写操作授权和完整审计。

## 2. 已确认的产品决策

- AI 都在本机运行，不需要远程或公网访问。
- Orbit 暴露给 AI 的服务器和工具默认可用；读操作不打断用户。
- 写操作第一次在 Orbit 弹一次授权，按“AI 会话 + 服务器”记住，当前会话有效。
- 读模式仍会拦截明显的写操作，命中后升级为写授权。
- MCP 服务可以常开，但任何接入都必须先获得准入 token。
- 所有调用都必须携带准入 token，包括 shell 和容器操作。
- 一次性命令和持久 shell 由 AI 自己选择；容器操作也走通用命令，不单独封装。
- Orbit 不暴露容器级专用工具：AI 通过 `orbit_exec` / shell 自己执行 `docker ps`、`docker logs`、`docker exec` 等命令。
- 准入 token 按“每次 AI 会话首次连接时授权，会话结束即失效”处理。
- 凭据、私钥、token 不出现在 AI 的上下文和工具回执里。

## 3. 不在本次范围

- 远程网络接入、跨设备访问、团队共享。
- Docker、容器、数据库等专用工具封装；这些能力通过通用命令执行。
- SFTP、数据库、端口转发、监控等非执行类能力（后续按同一网关扩展）。
- 对 AI 命令的强沙箱。读模式拦截是安全网，不是对抗恶意本地进程的边界。
- 内置 AI 助手（AI 面板）的改造。
- 长期保存在 Agent 配置里的持久 token。
- 对远端输出中的业务密钥做自动脱敏。

## 4. 角色和典型场景

用户在 `10.1.101.132` 上有一套 Docker 测试服务。用户在 Orbit 里保存了该服务器。Claude Code 需要排查容器问题：

1. Claude Code 启动时加载 `orbit-mcp`。
2. 第一次调用工具前，Orbit 弹窗让用户确认“Claude Code 请求接入 Orbit”。
3. 用户批准，bridge 拿到只存在于内存中的准入 token。
4. AI 调用 `orbit_list_servers`，看到 `10.1.101.132`。
5. AI 调用 `orbit_exec` 执行 `docker ps`、`docker logs --tail 200 <container>` 查看容器和日志，不需要额外确认。
6. AI 判断需要重启容器或进入容器。第一次写调用时，Orbit 弹窗“允许本会话在 10.1.101.132 上的写操作”。用户批准。
7. 后续同一会话对该服务器的写操作不再询问，直到 MCP 会话断开、空闲超时或用户在 Orbit 里撤销。
8. 所有接入、命令、回执摘要进入 Orbit 的 AI 审计面板。

## 5. 安全模型

### 5.1 不变量

- 服务器密码、私钥、passphrase 只存在于 Rust 加密存储和进程内存中；任何 MCP/CLI 返回值、日志和审计记录都不包含它们。
- Agent Gateway 只监听本机 Unix Domain Socket，不监听 TCP 端口。
- Socket 目录权限 `0700`，socket 文件权限 `0600`。
- 所有工具调用必须携带有效准入 token；没有 token 直接返回 `unauthorized`，不触发任何 SSH 操作。
- 写操作除了 token 还需要写授权；持久 shell（包括进入容器的 shell）视为写能力。
- 每个 token 绑定一个 bridge 会话；会话结束、空闲超时或用户撤销后立即失效。
- 会话和写授权状态只在内存里；进程退出即清空。
- 所有工具调用约 55 秒内返回；长任务转为 job 轮询，不依赖客户端的 MCP 超时配置。
- 有活跃 AI 会话时，Orbit 不因关闭最后一个窗口而退出；显式退出会先终止会话。
- `ping` 只检查连接，不延长会话空闲时间。

### 5.2 威胁模型说明

- 这是“授权 + 审计 + 凭据隔离”机制，不是对抗恶意本地进程的沙箱。AI 以当前用户权限运行，理论上可以读取用户的文件和 Orbit 数据库；本设计的目标是让正常工作的 Agent 无法拿到服务器密码，并让所有操作可见、可控。
- AI 在远端执行 `cat .env`、读取容器环境变量时，仍然可以把远端密钥带回自己的上下文。Orbit 不能阻止，只能审计命令。若需要，后续可增加输出脱敏策略。
- 读模式的写操作拦截基于命令文本分析，属于 best-effort 安全网；无法解析或不确定的命令一律升级为写授权，而不是放行。

## 6. 总体架构

```
Claude Code / Codex / DeepSeek Harness
        │  MCP stdio（JSON-RPC）
        ▼
   orbit-mcp（bridge，App 内置可执行文件）
        │  Unix Socket（JSON lines）
        ▼
   Orbit App：AgentGateway
        ├─ 会话 / token / 写授权
        ├─ 审批窗口（接入、写操作）
        ├─ 审计事件 → AI 审计面板 / 日志
        ├─ AgentJobManager（长任务、轮询、取消）
        └─ AgentExecutor
              ├─ 一次性 exec（含 docker ps/logs/exec 等任意命令）
              └─ 持久 SSH shell
                    │
                    ▼
              Rust SshManager / SessionPool / DockerManager
```

另有 `orbit-cli` 作为不支持 MCP 的 harness 的入口，复用同一个 Unix Socket 和工具语义。

### 6.1 组件职责

- **orbit-mcp**：只做 MCP 协议、工具 schema、参数校验、token 保管和网关转发。不直接访问数据库，不接触凭据。
- **orbit-cli**：`auth`、`servers`、`containers`、`logs`、`exec`、`container-exec`、`shell` 等子命令；输出 JSON，供只支持 shell 的 Agent 使用。
- **AgentGateway**：App 内 Swift 组件，负责 socket server、准入审批、token 校验、会话状态、写授权、审计和请求分发。
- **AgentJobManager**：App 内的 job 生命周期管理，负责 `waitMs` 之后的异步命令、输出缓冲、轮询、取消和会话清理。
- **AgentExecutor**：App 内的执行层，复用 Rust SSH 池；负责通用命令、输出上限、超时、退出码和 shell 会话；不感知 Docker 语义。
- **AgentApproval UI**：独立的浮动面板，展示接入请求和写请求；主窗口不可见时也能出现。
- **AI 审计面板**：展示接入、授权、命令、结果摘要；支持按会话和服务器过滤。

## 7. 接入与准入 token

### 7.1 连接流程

1. Agent 启动 `orbit-mcp`，bridge 读取 `~/Library/Application Support/Orbit/agent/agent.sock`。
2. Socket 不存在时，bridge 尝试用自身所在 App Bundle 启动 Orbit（`open <bundle>`），最多等待 10 秒；CLI 同样自动拉起 Orbit。
3. 第一次工具调用时，bridge 建立连接并发送 `hello`：包含 MCP `clientInfo`（名称、版本）、bridge 版本、父进程 pid 和可执行文件路径。
4. Gateway 通过 `LOCAL_PEERPID` 获取对端进程，记录其可执行文件路径；如果路径是本 App Bundle 内的 `orbit-mcp`，在审批面板中显示“已验证路径”，否则显示实际路径并标记为“未验证”。
5. Gateway 在 Orbit 弹出接入面板，显示“声称的 Agent 名称 + 父进程路径”。
6. 批准后，Gateway 生成准入 token（32 字节随机数，base64url），绑定到该连接和会话；bridge 在后台轮询 `admission_status` 拿到 token 并只保存在内存中。
7. 工具调用最多等待 5 秒审批；用户未在 5 秒内处理时，调用返回 `{"status":"pending_approval","requestId":...}`，不执行任何操作。审批面板继续保留 120 秒，批准后 bridge 在下一次调用或 retry 时直接使用 token。
8. 用户拒绝或 120 秒无响应：请求返回 `admission_denied` / `approval_timeout`，不创建会话。

信任锚点：

- v1 不使用 Developer ID/notarization 作为硬性前提；当前 App 和 helper 是 ad-hoc 签名，签名校验只能作为提示，不能作为安全边界。
- 真正的准入边界是：socket 文件权限 0600 + 用户审批 + 绑定连接的随机 token。
- Debug/DerivedData 构建、或用户把 `orbit-mcp` 复制到别处时，只要用户批准仍可接入；审批面板会显示实际路径，用户自行判断。
- Developer ID 签名和 notarization 后续单独做，不阻塞本功能。

### 7.2 会话

- 每个 bridge 连接是一个 AI 会话；会话包含：id、agent 名称、clientInfo、父进程信息、创建时间、最后活动时间。
- MCP 会话在 bridge 进程退出、socket 断开或空闲 30 分钟后结束；最长 8 小时。
- 空闲判定只认工具调用、审批响应、shell 操作和 job 轮询，不认 `ping`；存在运行中的 job 或 shell 时会话不因空闲过期（8 小时上限仍然有效）。
- 写授权按 `(sessionId, serverId)` 存储；会话结束即清空。
- 会话过期后 bridge 清空本地 token；下一次工具调用重新触发接入审批。
- Orbit 设置页展示活跃会话，可手动撤销；撤销立即关闭该会话的 shells、终止 jobs 并使 token 失效。

### 7.3 CLI 的准入

- `orbit-cli auth --client "DeepSeek Harness"` 触发同样的接入面板；每次 `auth` 创建一个**独立的新会话**（session UUID），不会按 client 名称复用旧会话。
- 批准后把 `sessionId + token + clientName` 写入 `~/Library/Application Support/Orbit/agent/cli-sessions/<sessionId>.json`（目录 0700，文件 0600）。
- 后续 CLI 命令通过 `--session <id>` 或 `ORBIT_AGENT_SESSION` 选择会话；未指定时使用该 client 最近一次未过期会话，但不会把写授权共享给另一个同名会话。
- `orbit-cli auth` 输出 `sessionId` 与建议的 `export ORBIT_AGENT_SESSION=...`（只输出 session id，不输出 token）。并发 harness 应使用不同 client 名称或显式 session id。
- `orbit-cli sessions` 列出会话，`orbit-cli revoke <sessionId>` 撤销。
- CLI 会话与 MCP 会话一样有 30 分钟空闲 / 8 小时上限；token 不打印到 stdout，进程退出不影响会话，直到过期或撤销。

### 7.4 Orbit 生命周期

- 只要还有活跃 AI 会话（含运行中的 job 或 shell），关闭最后一个窗口不会退出 Orbit；App 保留在 Dock，可点击重新打开主窗口。没有活跃 AI 会话时维持现有“关闭最后一个窗口即退出”的行为；如果窗口已关闭、最后一个会话随后结束，App 退出。
- 显式退出时如果有活跃 AI 会话，弹出确认：“有 N 个 AI 会话正在使用 Orbit，退出会终止它们。” 退出会关闭 socket、shells、jobs 并清空 token；bridge 收到断连，后续调用返回 `orbit_unavailable`，Agent 需要重新拉起 Orbit 并重新准入。
- Sparkle 更新/重启会终止所有 AI 会话；bridge 返回 `orbit_restarting`，Agent 可重试并在 Orbit 重启后重新准入。
- Orbit 的设置页和菜单中提供“退出 Orbit”入口；是否增加菜单栏状态项由构建者决定。

## 8. 服务器暴露与开关语义

- 设置中增加“AI Agent 接入”总开关（默认开启，但只有授权会话能访问）。
- 每台服务器有“允许 AI 访问”开关，默认开启；关闭后不出现在 `orbit_list_servers`，也不能被执行。
- 关闭总开关是硬性 kill switch：立即结束所有 AI 会话、关闭所有 agent shells、取消 jobs、撤销 token 和写授权、停止 gateway socket。
- 关闭某台服务器的开关会立即：关闭该服务器的 agent shells、取消该服务器的 jobs、撤销该服务器的写授权、拒绝新调用并从列表中隐藏；其他服务器的会话不受影响。重新开启后该会话的读调用可直接恢复，写调用需要重新授权。
- Agent 只能用服务器 id、唯一名称或 host 定位服务器；不返回密码、私钥、passphrase。
- 暴露字段：`id`、`name`、`host`、`port`、`username`、`folder`、`tags`、`aiEnabled`。

## 9. 工具与权限

### 9.1 工具列表（v1）

| 工具 | 权限 | 说明 |
|---|---|---|
| `orbit_list_servers` | 读 | 返回暴露的服务器 |
| `orbit_exec` | 读或写 | 一次性 SSH 命令；`mode` 参数区分 |
| `orbit_job_status` | 读 | 查询一次性命令 job 的状态 |
| `orbit_job_output` | 读 | 分页读取 job 的输出 |
| `orbit_job_cancel` | 读 | 取消 job |
| `orbit_approval_status` | 读 | 查询写授权请求状态 |
| `orbit_shell_open` | 写 | 打开持久 SSH shell；需要写授权 |
| `orbit_shell_exec` | 写 | 在持久 shell 里执行命令并等待完成标记 |
| `orbit_shell_close` | 写 | 关闭 shell |

持久 shell 是写能力：它能保持 `cd` 和环境变量，但无法保证后续命令是只读的。只读排查优先使用一次性 `orbit_exec`；需要状态或写操作时才申请 shell 授权。

Docker/容器操作不单独封装：AI 通过 `orbit_exec` 执行 `docker ps`、`docker logs`、`docker exec ...`，或通过持久 shell 进入容器。Orbit 只在读模式下检查命令是否真的只读。

### 9.2 `orbit_exec` 参数与返回

```json
{
  "server": "server-id-or-unique-name-or-host",
  "command": "docker logs --tail 200 my-container",
  "mode": "read",
  "timeoutMs": 30000,
  "waitMs": 30000,
  "maxOutputBytes": 262144,
  "idempotencyKey": "optional-client-generated-uuid"
}
```

返回（命令在 `waitMs` 内完成）：

```json
{
  "status": "completed",
  "serverId": "...",
  "stdout": "...",
  "stderr": "...",
  "exitCode": 0,
  "durationMs": 123,
  "truncated": false,
  "stdoutBytes": 1024,
  "stderrBytes": 0,
  "mode": "read",
  "escalated": false
}
```

返回（命令仍在运行）：

```json
{
  "status": "running",
  "serverId": "...",
  "jobId": "job-uuid",
  "durationMs": 30012,
  "stdoutBytes": 4096,
  "stderrBytes": 0,
  "mode": "read",
  "escalated": false
}
```

- `timeoutMs` 是命令的总执行上限（默认 30 秒，最大 300 秒）；超过后终止并返回 `status: "timed_out"`。
- `waitMs` 是本次工具调用等待完成的上限（默认 30 秒，最大 50 秒）；超过后返回 `status: "running"` 和 `jobId`，命令继续执行。
- 所有工具调用必须在约 55 秒内返回；长命令通过 `orbit_job_status` / `orbit_job_output` 轮询，避免 MCP 客户端超时。
- 写模式建议携带 `idempotencyKey`；相同 key 的重试返回同一个 job，不会重复执行。未提供时 Gateway 用 `(serverId, command)` 在 60 秒窗口内去重。
- 默认输出上限 256 KiB/流，最大 1 MiB；超出截断并设置 `truncated`。
- ANSI 控制序列在返回前剥离；日志类工具保留原始文本（可选 `stripAnsi` 参数）。

### 9.3 读模式检查

`mode` 由 AI 声明；Orbit 仍对命令做保守检查：

- 出现未引用的 `>` / `>>`、`tee`、`sed -i`、`perl -i`、`truncate`、`dd`、`mkfs*` 等 → 升级写授权。
- 出现 `rm`、`mv`、`cp`、`chmod`、`chown`、`kill`、`pkill`、`killall`、`shutdown`、`reboot`、`mount`、`umount` → 升级。
- `systemctl` 除 `status|show|list-*|is-active|is-enabled|cat` 外 → 升级。
- `service` 除 `status` 外 → 升级。
- 包管理器 `install/remove/update`、`pip/npm/yarn` 安装类 → 升级。
- `sh -c`、`bash -c`、`eval`、`python -c`、`node -e`、`perl -e`、`ruby -e` → 升级（无法安全分析）。
- `docker` 的 `ps/logs/stats/inspect` 允许；`docker exec` 解析容器后的内层命令并按同一规则检查，`docker exec -it` 或内层命令命中写规则时升级；`docker run/rm/restart/stop/start/kill/cp` 等变更类子命令升级。
- 命令链按 `;`、`&&`、`||`、`|` 分段检查；任一段命中即升级；无法解析的引号/heredoc 直接升级。
- 升级不是拒绝：返回 `write_grant_required`，AI 可以用 `mode: "write"` 重试，触发一次写授权。

### 9.4 容器操作

- 不提供 `orbit_list_containers`、`orbit_docker_logs`、`orbit_container_exec`、容器 shell 之类的专用工具；AI 通过通用 `orbit_exec` 执行 `docker ps`、`docker logs`、`docker exec`，或通过持久 shell 进入容器。
- `docker exec` 在读模式下解析容器 id/名称之后的命令，并按 9.3 检查；`docker exec -it` 或内层命令命中写规则时升级为写授权。
- 一次性容器命令使用 `orbit_exec` 的 job/`waitMs` 语义；交互式容器使用 `orbit_shell_open` 后执行 `docker exec -it ... sh`，写授权覆盖整个 shell。
- Orbit 的 Docker 管理面板保持现状，与 Agent 工具无关。

### 9.5 持久 shell 的请求/响应

- `orbit_shell_open` 返回 `shellId`；一次写授权覆盖该 shell 的后续命令。
- `orbit_shell_exec` 写入 `command`，再写入一个随机标记 `printf '\n__ORBIT_DONE_<uuid>__%s\n' "$?"`；Gateway 读取输出直到标记行，返回 `{output, exitCode, truncated}`。
- `orbit_shell_exec` 最多等待 50 秒；未收到标记时返回 `shell_timeout`，命令可能仍在运行，AI 应关闭 shell 或改用一次性 job。
- 标记包含随机 UUID，降低输出中碰撞的概率；命令中包含交互式程序（vim/top）时不保证可用，AI 应使用一次性命令。
- `orbit_shell_close` 关闭 channel；会话结束时 Gateway 自动关闭所有 shell。
- 活跃 shell 计入会话活动，不会被 30 分钟空闲清理。

### 9.6 Job 与审批

- `orbit_exec` 在 `waitMs` 内未完成时创建 job；job 状态：`running`、`completed`、`failed`、`timed_out`、`cancelled`。
- `orbit_job_status(jobId)` 返回状态、exitCode、durationMs、stdoutBytes、stderrBytes、truncated。
- `orbit_job_output(jobId, cursor?)` 返回自 cursor 起的输出块、`nextCursor`、`eof`；缓冲区上限与一次性返回一致。
- `orbit_job_cancel(jobId)` 关闭 SSH channel；job 所属会话结束时自动取消所有 job。
- 写模式 job 使用 `idempotencyKey` 去重；相同 key 的重试返回已有 job。未提供 key 时 Gateway 在 60 秒窗口内按 `(serverId, command)` 去重。
- 审批请求（准入或写授权）最多阻塞工具调用 5 秒；未完成时返回 `{"status":"pending_approval","requestId":...}`，不执行操作。用户批准后，bridge/AI 重试同一调用即可继续；`orbit_approval_status(requestId)` 可查询写授权状态。
- 所有工具调用约 55 秒内返回，长任务通过 job 轮询，不依赖任何 MCP 客户端的超时配置。

## 10. 协议

### 10.1 Bridge ↔ Gateway

- Unix Domain Socket，newline-delimited JSON。
- 请求：`{"id","op","sessionId","token",...}`。
- `op`：`hello`、`admission_status`、`call`、`revoke`、`ping`。
- `hello` 和 `admission_status` 不需要 token（它们只服务于尚未签发的准入请求）；`call` 和 `revoke` 必须带有效 token。
- `ping` 只用于连接健康检查，不更新 `lastActivity`，不阻止空闲过期；返回 `{"alive":true,"sessionExpired":false}`。
- 响应：`{"id","ok":true,"result":...}` 或 `{"id","ok":false,"error":{"code","message"}}`。
- `call` 的 `tool` 和 `args` 原样转发；审批未完成时 `result` 为 `{"status":"pending_approval","requestId":...}`。

### 10.2 MCP

- `orbit-mcp` 是 stdio MCP Server，支持 `initialize`、`notifications/initialized`、`tools/list`、`tools/call`、`ping`。
- `initialize` 立即返回 server info 和 tools capability；准入在第一次 `tools/call` 时懒触发。
- 工具调用返回 MCP `content: [{type:"text", text:<JSON>}]`；业务错误用 `isError: true` + JSON 错误体。`status: pending_approval` 和 `status: running` 是正常结果，不是错误。
- 工具调用最多阻塞 5 秒等待审批，然后返回 pending；不依赖 MCP 客户端的长超时。
- 不在 `initialize` 时弹授权，避免 Agent 只是启动 MCP 就被打断。
- 工具描述中明确说明：长任务使用 job 轮询；写调用建议带 `idempotencyKey`；读模式会拦截明显的写命令。

### 10.3 CLI

- 统一输出 JSON（`--json` 默认），错误写到 stderr 并以非零退出码结束。
- 命令示例：
  - `orbit-cli auth --client "Claude Code"`（创建新会话，输出 sessionId 和 `export ORBIT_AGENT_SESSION=...`）
  - `orbit-cli sessions` / `orbit-cli revoke <sessionId>`
  - `orbit-cli servers`
  - `orbit-cli exec --server 10.1.101.132 --mode read -- "docker ps -a"`
  - `orbit-cli exec --server 10.1.101.132 --mode read -- "docker logs --tail 200 api"`
  - `orbit-cli exec --server 10.1.101.132 --mode read -- "grep ERROR /var/log/api.log"`
  - `orbit-cli job status <jobId>` / `orbit-cli job output <jobId> [--cursor N]` / `orbit-cli job cancel <jobId>`
- `--session <id>` 或 `ORBIT_AGENT_SESSION` 选择会话；未指定时使用该 client 最近一次未过期会话，但每个 `auth` 仍是独立会话，写授权不会跨会话共享。
- 写命令支持 `--idempotency-key`；长命令返回 `status: running` + `jobId`，由 CLI 继续轮询或交给 Agent 轮询。

## 11. 审批 UI

### 11.1 接入审批

- 浮动面板，标题“AI Agent 请求接入 Orbit”。
- 内容：Agent 名称、MCP clientInfo、父进程路径、路径是否位于当前 App Bundle、bridge 版本、请求时间。
- 按钮：允许 / 拒绝。
- 允许后立即生成 token；拒绝后 bridge 收到 `admission_denied`。
- 120 秒无响应自动拒绝；面板关闭。工具调用本身最多等 5 秒，随后返回 `pending_approval`，不会一直阻塞 MCP 客户端。
- 多个请求排队；面板需要把 Orbit 激活到前台，主窗口最小化也可见。

### 11.2 写授权

- 标题“AI 请求写权限”。
- 内容：Agent、服务器、命令/操作（打开 shell，可能用于进入容器）、`mode=write`、可能的风险提示。
- 按钮：允许本会话在此服务器的写操作 / 拒绝。
- 批准后写授权写入会话；同一会话同一服务器不再弹窗。
- 拒绝或 120 秒超时返回 `write_denied` / `approval_timeout`；工具调用 5 秒内未获批准时先返回 `pending_approval`，批准后由 AI 重试。
- 面板需要把 Orbit 激活到前台；主窗口最小化也可见。

## 12. 审计

- 记录事件：
  - `agent.admission.requested` / `approved` / `denied` / `timeout`
  - `agent.session.started` / `ended` / `revoked`
  - `agent.write.granted` / `denied`
  - `agent.tool.call`：session、agent、server、tool、mode、command、exitCode、durationMs、stdoutBytes、stderrBytes、truncated、result
  - `agent.job.started` / `finished` / `cancelled` / `timed_out`
  - `agent.shell.opened` / `closed`
  - `agent.switch.globalDisabled` / `agent.switch.serverDisabled`
- 审计不记录 token、密码、私钥；默认不记录完整输出，只记录长度和命令。可选“记录完整输出”默认关闭。
- v1 存内存 + 追加 `~/Library/Application Support/Orbit/agent/audit.log`（JSON lines）；UI 提供“AI 活动”面板；后续可迁移到 SQLite。
- 用户可通过审计面板看到“哪个 Agent 在哪台机器上执行了什么、结果如何”。

## 13. 凭据与数据边界

- Gateway 只从 `OrbitBridge`/Rust 获取执行结果；构造给 Agent 的 DTO 明确排除 `password`、`private_key`、`key_passphrase`。
- Rust 的 `Server` 模型包含加密字段；Agent 相关 FFI 只接受 `server_id`，不返回凭据。
- 错误信息不得回显连接字符串中的密码；对 `ssh://user:pass@host` 之类的输入做脱敏。
- 审计日志和 bridge 日志不得打印 token；日志中 token 只显示前 4 位用于调试。

## 14. 代码复用与改动

### 14.1 Rust

- 复用 `transport::SessionPool`、`SshManager::exec_command_output_with_timeout`、`DockerManager`。
- 新增 `agent` 模块：
  - `exec_agent_command(server_id, command, timeout_ms, max_bytes) -> AgentExecOutput`，并发读取 stdout/stderr（现有实现顺序读取，需修正 stderr 满导致死锁的风险），输出截断，返回 exit code。
  - job 版本：`start_agent_job`、`poll_agent_job`、`read_agent_job_output`、`cancel_agent_job`，在 Rust 侧持有 channel 和输出缓冲，避免 Swift 侧管理 SSH 生命周期。
  - `shell_open/shell_exec/shell_close`（PTY channel + 输出缓冲 + sentinel 解析），供持久 shell 使用。
- 新增 FFI：`orbit_agent_exec`、`orbit_agent_job_*`、`orbit_agent_shell_*`，遵守现有 C ABI/JSON DTO 风格。
- Agent 不调用 `DockerManager`；Docker 面板保持 UI 专用。AI 传入的 `docker ...` 命令按普通命令执行，读模式检查在 Gateway/命令解析层完成。
- 所有 agent 入口只接受 `server_id`，不返回凭据。

### 14.2 Swift

- 新增 `AgentGateway`（socket server、会话、token、准入/写审批、审计）。
- 新增 `AgentJobManager`（job 生命周期、轮询、取消、会话清理）。
- 新增 `AgentExecutor`（调用 OrbitBridge/Rust，管理 shell 会话和通用命令）。
- 新增 `AgentApprovalWindowController` 和审批视图。
- 新增设置页“AI Agent”分类：总开关、服务器暴露列表、活跃会话、审计入口、MCP/CLI 配置说明。
- 服务器编辑弹窗增加“允许 AI 访问”开关（默认开）。
- 修改 `AppDelegate`：
  - 启动时启动 Gateway；关闭最后一个窗口时，如果有活跃 AI 会话则不退出。
  - 显式退出时如有活跃会话，显示确认并清理全部 agent 状态。
  - 处理 Dock 重新打开主窗口。
- 现有内置 AI 面板不改。

### 14.3 打包

- `project.yml` 增加 `orbit-mcp` 和 `orbit-cli` 两个 `type: tool` target。
- App target 通过 Copy Files 阶段把两个可执行文件放入 `Orbit.app/Contents/MacOS/`。
- 更新 `scripts/build-app.sh` 验证嵌套可执行文件的签名和权限。
- v1 保持 ad-hoc 签名；不引入 Developer ID/notarization 作为本功能前置条件。审批面板显示 helper 的实际路径；路径验证只作提示。
- 安装说明：
  - Claude Code：`claude mcp add orbit -- /Applications/Orbit.app/Contents/MacOS/orbit-mcp`
  - Codex：`~/.codex/config.toml` 的 `[mcp_servers.orbit] command = "/Applications/Orbit.app/Contents/MacOS/orbit-mcp"`
  - DeepSeek Harness：支持 MCP 时同上；否则使用 `orbit-cli`。

## 15. 分阶段交付

### 阶段 1：准入与只读排查

- Gateway、socket、token、接入审批（含 5 秒 pending 契约）。
- Orbit 生命周期：有活跃 AI 会话时不因关窗退出。
- `orbit-mcp` + `orbit-cli` 骨架。
- 服务器列表、只读 `orbit_exec`（含 `docker ps`、`docker logs`）。
- 审计事件和 AI 活动面板。

### 阶段 2：写授权与 job

- 写授权面板、会话级授权。
- `orbit_exec(mode=write)`。
- 读模式检查与升级，包括 `docker exec` 的内层命令检查。
- job 模型、`waitMs`、`orbit_job_*`、幂等键。
- 总开关/服务器开关的 kill switch 语义。
- 活跃会话管理、撤销。

### 阶段 3：持久会话与 CLI 完善

- 持久 SSH shell（AI 可自行执行 `docker exec -it ... sh` 进入容器）。
- sentinel 执行、shell 生命周期、超时和清理。
- CLI 的 session 文件、`sessions`/`revoke`、job 子命令完善。

## 16. 测试策略

- Rust 单元：输出截断、超时、stdout/stderr 并发读取、job 生命周期、读模式分类、`docker exec` 内层命令解析。
- Swift 单元：token 生成/校验/过期、session/写授权、CLI 独立会话、服务器解析、MCP JSON 编解码。
- 集成：假 MCP client 通过 stdio 连接 bridge，验证 initialize/tools/list/tools/call、无 token 拒绝、5 秒 pending、审批批准后重试成功、job 轮询、幂等写不重复执行。
- UI 测试：接入审批面板、写授权面板、总开关/服务器开关 kill switch、活跃会话撤销、审计面板、关窗不退出与退出确认。
- 安全测试：无 token、错误 token、过期 token、未暴露服务器、读模式写命令升级、`ping` 不延长会话、返回值不含密码/私钥/token。
- 客户端兼容：用一个模拟 60 秒工具超时的 MCP client 验证所有调用都在预算内返回；Claude Code 和 Codex 各跑通“列服务器 → `docker ps`/`docker logs` → 写操作授权 → `docker exec` → 长任务 job 轮询”。
- 真实服务器使用环境变量提供，不提交凭据。

## 17. 留给构建者的决定

- Unix socket 的具体实现（POSIX + DispatchSource 或 Network.framework）和消息 framing。
- MCP 协议版本、stdio 的 JSON 分帧细节。
- token 的具体编码、常量时间比较和会话存储结构。
- 读模式命令解析器的实现方式和完整规则表。
- 持久 shell 的 sentinel 细节和输出缓冲大小。
- job 输出缓冲大小、cursor 语义和保留时长。
- 审计日志的轮转、保留周期和 UI 展示密度。
- 审批面板的具体视觉样式和是否增加菜单栏状态项。
- 两个 CLI 工具在 App Bundle 内的签名/嵌入细节。
- 服务器暴露开关放在设置页还是服务器编辑页的具体交互（设计默认：两处都可访问，默认开启）。
- Sparkle 更新与活跃 AI 会话的交互：重启前提示、延迟更新或直接重启，由构建者选择并在发布说明中写清。
- 是否在 v1 就提供 `orbit-cli` 的持久 shell 子命令。

## 18. 验收标准

- Claude Code 可以在不接收服务器密码的情况下列出服务器、通过 `orbit_exec` 执行 `docker ps`/`docker logs` 并拿到回执。
- Orbit 不提供容器级专用工具；AI 通过通用命令即可完成容器排查。
- 第一次写操作时 Orbit 弹出一次授权；同一会话同一服务器的后续写操作不再询问。
- 没有准入 token 的任何调用都返回 `unauthorized`，且不会建立 SSH 连接。
- 所有工具调用在约 55 秒内返回；长命令返回 `jobId`，可通过 job 工具继续读取，不会因 MCP 客户端超时而丢失结果。
- 重复的写调用使用同一 `idempotencyKey` 不会执行两次。
- shell 调用同样需要 token 和写授权；AI 可以在 shell 中自行执行 `docker exec -it` 进入容器。
- 关闭总开关会立即终止所有 AI 会话；关闭服务器开关会立即终止该服务器的 agent shells/jobs 并撤销写授权。
- 有活跃 AI 会话时关闭主窗口不会退出 Orbit；显式退出会提示并终止会话。
- `ping` 不延长会话；存在活跃 job/shell 时会话不会因 30 分钟空闲过期。
- CLI 每次 `auth` 创建独立会话；同名 client 的两个会话不共享写授权。
- AI 的任何返回值、Orbit 审计日志和 bridge 日志中都不出现密码、私钥或完整 token。
- 用户可以在 Orbit 中看到活跃 AI 会话、写授权并随时撤销。
- 现有内置 AI 面板、普通终端和服务器管理功能不受影响。
