# Orbit TODO

## 优化项

- [x] SSH 连接复用 — Monitor 轮询和 SFTP 操作每次新建连接，应在 transport 层加连接池复用 SessionGuard
- [ ] SFTP 大文件流式传输 — 当前全量 read\_to\_end 再写，大文件会 OOM，改为分块流式读写
- [ ] 凭据加密存储 — 密码/密钥明文存 SQLite，改用 macOS Keychain 或 AES-256 加密
- [ ] 跳板机连接错误提示 — channel\_direct\_tcpip 失败时区分"TCP 转发被禁用"和"目标不可达"
- [ ] Terminal 关闭确认 — 长连接关闭 Tab 时弹确认框
- [ ] ActiveSession 拆分 — ssh.rs 的 connect + spawn\_reader\_and\_insert 合并简化

## 新功能

- [ ] 命令片段 — 保存常用命令，右键服务器一键执行
- [ ] 多服务器批量执行 — 选中多个服务器执行同一命令，结果汇总展示
- [ ] 本地端口转发管理 — 基于 channel\_direct\_tcpip 暴露用户可配置的端口转发规则（ssh -L）
- [ ] 终端分屏 — 左右/上下分屏同时查看多台服务器
- [ ] 服务器搜索过滤 — Sidebar 支持快速搜索服务器
- [ ] 配置导入/导出 — 导出服务器列表为 JSON，方便团队共享和设备迁移
- [ ] 连接日志 — 记录每次连接的时间、时长、流量
- [ ] 终端录制/回放 — 录制终端操作，用于问题排查或培训

