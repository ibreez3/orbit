# Hostwren AI Agent 接入

Hostwren 可以让本机 AI Agent（Claude Code、Codex、DeepSeek Harness）访问已开放的服务器，以及只读查询已开放的数据库连接。连接凭据由 Hostwren 管理。

## 前置条件

- Hostwren 已启动，且设置 → AI Agent 中“允许 MCP / CLI Agent 接入”已开启。
- 需要被 AI 使用的服务器在设置中保持“允许 AI 访问”（默认开启）。
- 所有接入都需要在 Hostwren 里由用户批准，并签发只存在于当前会话的准入 token。

## Claude Code

```bash
claude mcp add orbit -- /Applications/Orbit.app/Contents/MacOS/orbit-mcp
```

启动 Claude Code 后第一次调用 Hostwren 工具时，Hostwren 会弹出接入确认。批准后即可使用：

- `orbit_list_servers`
- `orbit_exec`
- `orbit_job_status` / `orbit_job_output` / `orbit_job_cancel`
- `orbit_shell_open` / `orbit_shell_exec` / `orbit_shell_close`
- `orbit_approval_status`

当前阶段只提供通用执行能力，不提供 `orbit_list_containers`、`orbit_docker_logs` 等专用工具。AI 直接执行：

```text
docker ps -a
docker logs --tail 200 <container>
docker exec <container> cat /app/config.yml
```

## Codex

在 `~/.codex/config.toml` 中增加：

```toml
[mcp_servers.orbit]
command = "/Applications/Orbit.app/Contents/MacOS/orbit-mcp"
```

## DeepSeek Harness / 仅支持 shell 的 Agent

使用 Hostwren 内置 CLI：

```bash
/Applications/Orbit.app/Contents/MacOS/orbit-cli auth --client "DeepSeek Harness"
# 按输出设置：
export ORBIT_AGENT_SESSION=<sessionId>

/Applications/Orbit.app/Contents/MacOS/orbit-cli servers
/Applications/Orbit.app/Contents/MacOS/orbit-cli exec --server <服务器名> --mode read -- "docker ps -a"
/Applications/Orbit.app/Contents/MacOS/orbit-cli exec --server <服务器名> --mode read -- "docker logs --tail 200 <container>"

# 第一次写操作会弹出 Hostwren 授权面板；授权后本会话对该服务器免问
/Applications/Orbit.app/Contents/MacOS/orbit-cli exec --session <sessionId> --server <服务器名> --mode write -- "docker restart <container>"

# 长命令返回 jobId 后，用 job 子命令轮询或取消
/Applications/Orbit.app/Contents/MacOS/orbit-cli job status --session <sessionId> --job <jobId>
/Applications/Orbit.app/Contents/MacOS/orbit-cli job output --session <sessionId> --job <jobId> --cursor 0
/Applications/Orbit.app/Contents/MacOS/orbit-cli job cancel --session <sessionId> --job <jobId>

# 持久 shell（写能力，首次需要写授权；保持 cd/环境变量）
/Applications/Orbit.app/Contents/MacOS/orbit-cli shell open --session <sessionId> --server <服务器名>
/Applications/Orbit.app/Contents/MacOS/orbit-cli shell exec --session <sessionId> --shell <shellId> -- "pwd; ls"
/Applications/Orbit.app/Contents/MacOS/orbit-cli shell exec --session <sessionId> --shell <shellId> -- "docker exec -it <container> sh"
/Applications/Orbit.app/Contents/MacOS/orbit-cli shell close --session <sessionId> --shell <shellId>
```

`orbit_exec` 在 `waitMs` 内没有结束时返回 `jobId`。MCP 客户端用 `orbit_job_status` 查看状态，用 `orbit_job_output` 从 `cursor` 开始读取增量输出，用 `orbit_job_cancel` 终止任务。CLI 调用可以传入 `--wait-ms` 控制等待时间。

## 持久 shell

一次性排查优先用 `orbit_exec`（读操作无需确认）。需要保持 `cd`、环境变量，或进入容器交互式 shell 时，才打开持久 shell：

1. `orbit_shell_open` / `orbit-cli shell open` 需要该服务器的写授权；首次会弹一次面板，本会话内该服务器后续 shell 不再询问。
2. `orbit_shell_exec` / `orbit-cli shell exec` 会等待命令完成标记，最多 50 秒；超时返回 `shell_timeout`，命令可能仍在运行。此时应关闭 shell，或改用一次性 job。
3. `orbit_shell_close` / `orbit-cli shell close` 关闭 channel；会话撤销、服务器从 AI 暴露中关闭或 Hostwren 退出时也会自动关闭。
4. 进入容器：先打开 shell，再执行 `docker exec -it <container> sh`；后续 `shell exec` 命令会进入该容器 shell，关闭 shell 即退出。

## 授权模型

- **准入 token**：第一次工具调用触发 Hostwren 接入面板；批准后 bridge 拿到 token。token 只保存在 bridge 内存中，会话结束、空闲超时或手动撤销即失效。
- **读操作**：直接执行，不需要逐条确认。
- **写操作**：第一次写操作在 Hostwren 弹一次授权，按“AI 会话 + 服务器”记住；当前会话内该服务器后续写操作不再询问。
- **shell**：持久 shell 需要写授权。
- **审计**：接入、写授权、命令、退出码和输出长度记录在 `~/Library/Application Support/Orbit/agent/audit.log`，并显示在设置 → AI Agent → AI 活动。
- **CLI 会话**：每次 `orbit-cli auth` 创建独立会话；token 存在 `~/Library/Application Support/Orbit/agent/cli-sessions/<sessionId>.json`（0600），不打印到 stdout。

## 安全边界

- 服务器凭据只在 Rust 加密存储和进程内存中；工具返回、日志和审计都不包含密码、私钥或完整 token。
- 网关只监听本机 Unix socket（`agent.sock`，0600），不开放 TCP。
- 读模式会拦截明显的写命令（重定向、`rm`、重启、`docker rm`、`docker exec` 的写内层命令等）；命中后升级为写授权。
- 单次 `orbit_exec` 的等待上限为 50 秒、命令超时上限为 300 秒、输出上限为 1 MiB。持久 shell 的输出超过 1 MiB 时保留尾部并返回 `truncated: true`。
- 这是“凭据隔离 + 授权 + 审计”机制，不是对抗恶意本地进程的沙箱。AI 读取远端 `.env` 等文件时仍可能把远端密钥带进自己的上下文。

## 常见问题

- **Hostwren 没有弹窗**：确认 Hostwren 正在运行，且设置 → AI Agent 总开关开启；bridge 会在 socket 不存在时尝试拉起 Hostwren。
- **没有服务器**：检查服务器的“允许 AI 访问”开关，以及服务器是否已保存。
- **会话过期**：重新执行 `orbit-cli auth` 或重新调用工具触发接入审批。
- **Claude Code 工具超时**：所有调用约 55 秒内返回；长命令会返回 job id，通过 `orbit_job_status` / `orbit_job_output` 轮询。
- **shell 超时**：`orbit_shell_exec` 最多等待 50 秒；命令可能仍在运行，关闭 shell 或改用 `orbit_exec` 的 job 语义。
- **shell 不存在**：会话撤销、服务器从 AI 暴露中关闭或 Hostwren 退出都会关闭 shell；重新打开即可。

## macOS 数据库只读访问

在设置 → AI Agent → 数据库只读访问中启用要开放的连接。新连接和已有连接均默认关闭。已批准的 CLI 或 MCP 会话可以查询该连接账号可读的数据，关闭开关后再次调用即被拒绝。使用专用只读数据库账号可限制可见的数据和可执行的数据库函数。

```bash
orbit-cli db list
orbit-cli db schema --db <连接ID>
orbit-cli db schema --db <连接ID> --table <上一步返回的表ID>
orbit-cli db query --db <连接ID> --sql 'SELECT COUNT(*) FROM orders'
```

MCP 对应工具为 `orbit_db_list`、`orbit_db_schema`、`orbit_db_query`。MySQL 连接未指定库名时，先用 schema 查看 catalogs，再在 schema 或 query 中传入 `--catalog`（MCP 参数为 `catalog`）。查询支持单条 SELECT 或只读 WITH，语句超时为 15 秒，结果最多返回 200 行，列和行的 JSON 大小预算为 256 KiB。返回的 `truncated` 表示是否省略了结果行。远程 SQLite 查询需要远端 sqlite3 支持 `-safe`、`-readonly` 和 `-json`。
