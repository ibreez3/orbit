# 数据库连接、备份与 SQLite 导入 MySQL 设计

## 概述

Orbit 的 Database 面板目前是 mock UI。本设计把它升级为可持久化的数据库资产管理与访问能力：支持 SSH 远端 SQLite、MySQL、PostgreSQL 的连接测试、schema 浏览、SQL 查询/修改、一键全量备份、从备份恢复，以及 SQLite 备份导入 MySQL。

本期按 MVP 范围实现，核心逻辑放在 Rust `orbit-core`，Swift 负责原生配置、展示和交互。数据库连接作为资产树中的“数据库”节点持久化保存，凭据沿用现有本机加密机制。

## 目标

- 数据库连接配置持久化保存，并在资产树中展示。
- 支持 SSH 远端 SQLite，连接阶段要求远端可用 `sqlite3`；如果不存在，Orbit 在用户确认后尝试通过远端包管理器安装。
- 支持 MySQL 和 PostgreSQL 的查询与修改；可直连，也可通过某台已配置 SSH 服务器建立临时隧道连接。
- 支持真实 schema 浏览，替换当前 mock 表列表。
- 支持一键全量备份，备份内容包含表结构和数据本身。
- 支持从备份恢复。
- 支持 SQLite 备份导入 MySQL。
- 支持 SQLite 到 MySQL 导入时的表名与字段名映射，例如源字段 `system` 导入到目标字段 `system1`。

## 非目标

- 不实现增量备份。
- 不实现大库 streaming/chunked 备份文件格式；MVP 使用单个 JSON artifact，面向中小型数据库。
- 不实现 MySQL 到 SQLite、PostgreSQL 到 SQLite、PostgreSQL 到 MySQL 等任意跨库迁移。
- 不实现长期驻留的数据库连接池；MVP 每次操作短连接，用完释放。
- 不上传 Orbit 自带远端 SQLite helper；远端 SQLite 只使用远程机器上的 `sqlite3` 命令。

## 推荐方案

采用方案 A：Rust 内置数据库引擎层。

Rust 新增数据库模块，统一处理连接资产、查询执行、schema 读取、备份、恢复和 SQLite 到 MySQL 导入。Swift 通过 FFI 发送 JSON 请求并展示结果。

这个方案符合 Orbit 现有架构：SSH、SFTP、Docker、监控等核心能力已经由 Rust 实现，Swift 主要承载原生 macOS UI。把数据库核心逻辑放在 Rust 可以降低 FFI 边界复杂度，便于后续测试与扩展。

## 数据持久化

### database_connections

新增本地配置表：

```sql
CREATE TABLE IF NOT EXISTS database_connections (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    group_name TEXT NOT NULL DEFAULT '',
    engine TEXT NOT NULL,
    ssh_server_id TEXT NOT NULL DEFAULT '',
    use_ssh_tunnel INTEGER NOT NULL DEFAULT 0,
    host TEXT NOT NULL DEFAULT '',
    port INTEGER NOT NULL DEFAULT 0,
    database_name TEXT NOT NULL DEFAULT '',
    username TEXT NOT NULL DEFAULT '',
    password TEXT NOT NULL DEFAULT '',
    sqlite_path TEXT NOT NULL DEFAULT '',
    ssl_mode TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

`engine` 支持：

- `remote_sqlite`
- `mysql`
- `postgres`

凭据字段 `password` 使用现有 `crypto` 加密写入，读取时解密给 Rust driver 使用。远端 SQLite 使用 `ssh_server_id + sqlite_path` 定位文件。MySQL/PostgreSQL 可直接使用 `host/port`，也可设置 `use_ssh_tunnel=1` 并通过 `ssh_server_id` 建立临时隧道。

### database_backup_records

新增备份/恢复历史表：

```sql
CREATE TABLE IF NOT EXISTS database_backup_records (
    id TEXT PRIMARY KEY,
    connection_id TEXT NOT NULL,
    connection_name TEXT NOT NULL,
    engine TEXT NOT NULL,
    artifact_path TEXT NOT NULL,
    operation TEXT NOT NULL,
    status TEXT NOT NULL,
    summary TEXT NOT NULL,
    created_at TEXT NOT NULL
);
```

`operation` 支持：

- `backup`
- `restore`
- `import_to_mysql`

`status` 支持：

- `success`
- `failed`

字段映射不在 MVP 中持久化为 preset。导入时由 `prepare_import` 生成一次性 `ImportPlan`，Swift 允许用户编辑后提交。

## FFI 与 JSON 模型

Swift 与 Rust 通过 JSON DTO 通信。新增主要模型：

- `DatabaseConnection`
- `DatabaseConnectionInput`
- `DatabaseSchema`
- `DatabaseTableSchema`
- `DatabaseColumnSchema`
- `DatabaseQueryRequest`
- `DatabaseQueryResult`
- `DatabaseBackupRecord`
- `DatabaseBackupArtifact`
- `DatabaseImportPlan`
- `DatabaseImportRequest`
- `DatabaseOperationResult`

查询结果统一为：

```json
{
  "columns": ["id", "system1"],
  "rows": [["1", "prod"]],
  "affected_rows": 0,
  "elapsed_ms": 12,
  "message": ""
}
```

所有单元格 MVP 先以字符串或 JSON null 返回，列类型从 schema 获取。这样 Swift 表格渲染稳定，FFI 结构也保持简单。

新增 FFI：

```c
orbit_db_list_connections(app, out_json)
orbit_db_add_connection(app, json_input, out_json)
orbit_db_update_connection(app, id, json_input, out_json)
orbit_db_delete_connection(app, id)
orbit_db_test_connection(app, id, install_sqlite, out_json)
orbit_db_list_schema(app, connection_id, out_json)
orbit_db_execute(app, connection_id, json_request, out_json)
orbit_db_backup(app, connection_id, out_json)
orbit_db_list_backup_records(app, out_json)
orbit_db_restore(app, json_request, out_json)
orbit_db_prepare_import(app, backup_path, target_connection_id, mode, out_json)
orbit_db_run_import(app, json_request, out_json)
```

FFI 继续返回 `i32`，详细错误写入 `OrbitApp.last_error`。Swift Database wrapper 使用 `apiErrorWithMessage`，把安装失败、权限不足、SQL 错误、字段映射缺失等原因展示给用户。

## Rust 模块结构

新增目录：

```text
orbit-rs/src/database/
├── mod.rs
├── models.rs
├── store.rs
├── sqlite_remote.rs
├── mysql.rs
├── postgres.rs
├── backup.rs
└── import_mysql.rs
```

职责：

- `mod.rs`：对外门面 `DatabaseManager`，负责根据 engine 路由。
- `models.rs`：数据库连接、schema、查询、备份、导入 DTO。
- `store.rs`：`database_connections` 和 `database_backup_records` CRUD。
- `sqlite_remote.rs`：SSH 远端 `sqlite3` 检测、安装、schema、查询和写入。
- `mysql.rs`：MySQL 连接、schema、查询和批量写入。
- `postgres.rs`：PostgreSQL 连接、schema 和查询。
- `backup.rs`：统一备份 artifact 生成、读取和同类型恢复。
- `import_mysql.rs`：SQLite backup 到 MySQL 的类型转换、字段映射校验和导入。

`lib.rs` 增加：

```rust
mod database;
```

`OrbitApp` 不需要长驻数据库连接池。DatabaseManager 的方法接收 `&Database`、`&SessionPool` 和连接配置，短连接执行后释放。

## 远端 SQLite 执行逻辑

### sqlite3 检测和安装

远端 SQLite 只通过远程 `sqlite3` 命令执行。连接测试和首次操作前执行：

```bash
command -v sqlite3
```

如果不存在，Rust 检测包管理器并生成安装命令：

- apt-get: `sudo apt-get update && sudo apt-get install -y sqlite3`
- dnf: `sudo dnf install -y sqlite`
- yum: `sudo yum install -y sqlite`
- pacman: `sudo pacman -Sy --noconfirm sqlite`
- zypper: `sudo zypper --non-interactive install sqlite3`
- apk: `sudo apk add sqlite`

当 `install_sqlite=false` 时，测试连接返回缺失状态和建议命令，不执行安装。当 `install_sqlite=true` 时，Rust 通过 SSH 执行安装命令。安装失败时返回 stdout/stderr 摘要和可复制的手动安装命令。

安装不是静默行为。Swift 在远端缺失 `sqlite3` 时弹出确认，显示将执行的命令。用户确认后再次调用 `orbit_db_test_connection(..., install_sqlite=true, ...)`。

如果 sudo 需要交互式密码、当前用户无 sudo 权限、包管理器不可识别，操作失败并提示用户在目标服务器手动安装 `sqlite3`。

### schema

SQLite schema 读取：

- 表列表：查询 `sqlite_master`
- 字段：逐表执行 `PRAGMA table_info`

### 查询和写入

查询语句使用：

```bash
sqlite3 -readonly -json <db_path> <sql>
```

写语句不使用 `-readonly`，并由 Rust 包装事务：

```sql
BEGIN IMMEDIATE;
<user sql>;
SELECT changes() AS affected_rows;
COMMIT;
```

写入结果从 `changes()` 读取 affected rows。DDL 或无法稳定统计行数的语句返回 `affected_rows=0` 和执行成功消息。

路径和 SQL 必须通过 shell-safe 引用。Rust 不把未经引用的 SQL 直接拼进 shell 命令。

只读模式下，Swift 先拦截明显写语句，Rust 再做最终保护。

## MySQL 和 PostgreSQL 执行逻辑

Rust 新增 MySQL 和 PostgreSQL driver 依赖。MVP 使用短连接模型：

- 每次测试、schema、查询、备份、导入创建连接。
- 操作完成后释放连接。
- 不在 Swift 状态中维护 driver session。

连接策略：

- 直连：driver 连接配置中的 `host:port`。
- SSH 隧道：Rust 使用现有端口转发能力创建临时本地端口，driver 连接 `127.0.0.1:<local_port>`，操作结束后停止转发。

PostgreSQL schema 使用 `information_schema` 和必要的 `pg_catalog`。MySQL schema 使用 `information_schema`。

查询结果规范：

- `SELECT` 或带返回行的语句返回 `columns + rows`。
- `INSERT`、`UPDATE`、`DELETE`、DDL 返回 `affected_rows + message`。
- NULL 返回 JSON null。
- 非 NULL 值在 MVP 中转为字符串。

## 备份 artifact

默认备份目录：

```text
~/Library/Application Support/orbit/backups/
```

备份文件扩展名：

```text
.orbit-db-backup.json
```

文件结构：

```json
{
  "format_version": 1,
  "source": {
    "engine": "remote_sqlite",
    "connection_name": "prod sqlite"
  },
  "created_at": "2026-07-08T00:00:00Z",
  "tables": [
    {
      "name": "users",
      "columns": [
        {
          "name": "id",
          "db_type": "INTEGER",
          "nullable": false,
          "primary_key": true,
          "default_value": null
        }
      ],
      "rows": [
        {
          "id": "1",
          "name": "alice"
        }
      ]
    }
  ]
}
```

备份包含表结构和数据本身。MVP 全量读取所有表数据并写入单个 JSON 文件。

## 恢复与导入

### 同类型恢复

从备份恢复到同类型连接时，Rust 读取 artifact：

- 根据 artifact schema 创建目标表。
- 如果目标表已存在，MVP 提供覆盖模式：先删除再重建。
- 批量插入数据。
- 操作结果写入 `database_backup_records`。

### SQLite 备份导入 MySQL

导入分两种模式。

新建表模式：

- `prepare_import` 读取 SQLite backup artifact。
- Rust 生成默认 MySQL schema。
- UI 允许编辑目标表名和字段名。
- 用户可以把源字段 `system` 映射到目标字段 `system1`。
- `run_import` 创建表并批量插入。

已有表模式：

- `prepare_import` 读取目标 MySQL 表 schema。
- 自动匹配同名字段。
- 不同名字段由 UI 让用户选择目标字段。
- 未映射源字段跳过。
- 如果目标表存在非空、无默认值、无自动生成逻辑的必填字段，并且没有映射来源，则阻止导入并显示原因。
- `run_import` 不修改目标表结构，只插入映射字段。

SQLite 到 MySQL 类型映射：

- `INTEGER` -> `BIGINT`
- `REAL` -> `DOUBLE`
- `TEXT` -> `TEXT`
- `BLOB` -> `BLOB`
- `NUMERIC` -> `DECIMAL(38,10)`
- 未识别类型 -> `TEXT`

批量插入默认每批 500 行。失败时错误中包含表名、批次、字段名和 driver 原始错误摘要。

## Swift UI 设计

### 资产树

资产树新增“数据库”分组：

- 数据库连接按 `group_name` 分组。
- 每个连接显示名称、类型 badge 和 SSH/隧道状态。
- 右键菜单包含打开、测试连接、备份、编辑、删除。

### 连接配置

新增 `DatabaseConnectionDialog.swift`：

- 名称、分组
- 类型选择：远程 SQLite、MySQL、PostgreSQL
- 远程 SQLite：SSH 服务器、SQLite 远端路径、连接时自动安装 sqlite3
- MySQL/PostgreSQL：host、port、database、username、password、是否使用 SSH 隧道、SSH 服务器、SSL mode

### DatabaseView

替换当前 mock 实现：

- 左侧真实 schema tree。
- 中间 SQL 编辑器。
- 执行按钮调用 `executeDatabaseQueryAsync`。
- 结果区展示真实查询表格或 affected rows。
- 顶部工具栏包含刷新 schema、测试连接、备份、从备份恢复/导入。
- 只读模式继续从 Settings 读取，并在 Swift 与 Rust 双层拦截写语句。

### 备份和导入

MVP 使用 sheet 流程：

1. 点击备份后直接执行全量备份，完成后展示 artifact 路径和备份记录。
2. 点击恢复/导入后选择 `.orbit-db-backup.json` 和目标连接。
3. 如果是 SQLite 到 MySQL，进入字段映射页面。
4. 新建表模式可编辑目标表名和目标字段名。
5. 已有表模式选择目标表并映射字段。
6. 导入完成后展示导入表数、行数、跳过字段和失败原因。

### AppState

新增状态：

- `databaseConnections`
- `databaseBackupRecords`
- `editingDatabaseConnection`
- `databaseOperationLoading`
- `databasePanelSnapshots`

Database tab 需要保存 SQL、选中表、最近结果摘要，继续给 AI 面板生成上下文。

## 安全与错误处理

- 数据库密码沿用本机加密存储。
- 远程安装 `sqlite3` 必须用户确认。
- SQLite 路径和 SQL shell 参数必须安全引用。
- 只读模式由 Swift 和 Rust 双层保护。
- SSH 隧道使用临时本地端口，操作结束后关闭。
- 备份文件包含结构和数据，可能包含敏感业务数据；UI 需要明确提示备份文件应妥善保管。
- 所有 Database FFI 错误都应写入 `last_error`，Swift 展示具体错误。

## 测试策略

Rust 单元测试优先覆盖纯逻辑：

- `database::store` CRUD 与密码加密/解密。
- 只读 SQL 判断。
- SQLite 类型到 MySQL 类型转换。
- 字段映射校验，包括 `system` 到 `system1`。
- 未映射字段跳过。
- 目标必填字段无默认值时报错。
- backup artifact 序列化和反序列化。
- import plan 生成。

集成测试：

- 远端 SQLite 安装和执行依赖真实 SSH 环境，不作为 CI 必跑测试。
- MySQL/PostgreSQL driver 实连测试后续可用 docker-compose 增加。

本期验证命令：

```bash
cd orbit-rs && cargo test
cd orbit-app && xcodegen generate
cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build
```

## 风险与约束

- 全量 JSON 备份不适合很大的数据库。MVP 明确面向中小数据库。
- 远程安装 `sqlite3` 依赖目标服务器的包管理器、网络和 sudo 权限。
- SSH 隧道短连接模型简单可靠，但频繁操作会增加连接成本。
- SQLite 写入通过远端 `sqlite3` 执行，仍需用户理解目标服务是否同时使用该 SQLite 文件。
- PostgreSQL/MySQL 类型系统比 SQLite 更严格，SQLite 到 MySQL 导入必须允许用户调整字段名和目标类型。

## 交付拆分建议

1. 持久化数据库连接资产和资产树入口。
2. Rust Database DTO、store、FFI、Swift bridge。
3. 远端 SQLite 检测、安装、schema、查询和修改。
4. MySQL/PostgreSQL 直连与 SSH 隧道查询。
5. DatabaseView 替换 mock。
6. 全量备份 artifact 和备份记录。
7. 同类型恢复。
8. SQLite 到 MySQL prepare/import 和字段映射 UI。
9. 构建和测试验证。
