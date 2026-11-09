# Orbit AI Agent 接入

Orbit 可以让本机 AI Agent（Claude Code、Codex、DeepSeek Harness）使用已保存服务器的 SSH 执行能力，而 Agent 不会拿到服务器密码或私钥。

## 前置条件

- Orbit 已启动，且设置 → AI Agent 中“允许 MCP / CLI Agent 接入”已开启。
- 需要被 AI 使用的服务器在设置中保持“允许 AI 访问”（默认开启）。
- 所有接入都需要在 Orbit 里由用户批准，并签发只存在于当前会话的准入 token。

## Claude Code

```bash
claude mcp add orbit -- /Applications/Orbit.app/Contents/MacOS/orbit-mcp
```

启动 Claude Code 后第一次调用 Orbit 工具时，Orbit 会弹出接入确认。批准后即可使用：

- `orbit_list_servers`
- `orbit_exec`

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

使用 Orbit 内置 CLI：

```bash
/Applications/Orbit.app/Contents/MacOS/orbit-cli auth --client "DeepSeek Harness"
# 按输出设置：
export ORBIT_AGENT_SESSION=<sessionId>

/Applications/Orbit.app/Contents/MacOS/orbit-cli servers
/Applications/Orbit.app/Contents/MacOS/orbit-cli exec --server <服务器名> --mode read -- "docker ps -a"
/Applications/Orbit.app/Contents/MacOS/orbit-cli exec --server <服务器名> --mode read -- "docker logs --tail 200 <container>"
```

## 授权模型

- **准入 token**：第一次工具调用触发 Orbit 接入面板；批准后 bridge 拿到 token。token 只保存在 bridge 内存中，会话结束、空闲超时或手动撤销即失效。
- **读操作**：直接执行，不需要逐条确认。
- **写操作**：第一次写操作在 Orbit 弹一次授权，按“AI 会话 + 服务器”记住；当前会话内该服务器后续写操作不再询问。
- **shell**：持久 shell 需要写授权。
- **审计**：接入、写授权、命令、退出码和输出长度记录在 `~/Library/Application Support/Orbit/agent/audit.log`，并显示在设置 → AI Agent → AI 活动。
- **CLI 会话**：每次 `orbit-cli auth` 创建独立会话；token 存在 `~/Library/Application Support/Orbit/agent/cli-sessions/<sessionId>.json`（0600），不打印到 stdout。

## 安全边界

- 服务器凭据只在 Rust 加密存储和进程内存中；工具返回、日志和审计都不包含密码、私钥或完整 token。
- 网关只监听本机 Unix socket（`agent.sock`，0600），不开放 TCP。
- 读模式会拦截明显的写命令（重定向、`rm`、重启、`docker rm` 等）；命中后升级为写授权。
- 这是“凭据隔离 + 授权 + 审计”机制，不是对抗恶意本地进程的沙箱。AI 读取远端 `.env` 等文件时仍可能把远端密钥带进自己的上下文。

## 常见问题

- **Orbit 没有弹窗**：确认 Orbit 正在运行，且设置 → AI Agent 总开关开启；bridge 会在 socket 不存在时尝试拉起 Orbit。
- **没有服务器**：检查服务器的“允许 AI 访问”开关，以及服务器是否已保存。
- **会话过期**：重新执行 `orbit-cli auth` 或重新调用工具触发接入审批。
- **Claude Code 工具超时**：所有调用约 55 秒内返回；长命令会返回 job id，通过 job 工具轮询（后续阶段）。
