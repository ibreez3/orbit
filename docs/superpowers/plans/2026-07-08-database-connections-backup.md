# Database Connections Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the MVP database feature: persisted database assets, SSH remote SQLite via remote `sqlite3` with confirmed installation, MySQL/PostgreSQL query access, full schema+data backup, restore, and SQLite backup import into MySQL with field mapping.

**Architecture:** Rust owns all database core behavior behind JSON FFI: persistence, remote SQLite command execution, MySQL/PostgreSQL short connections, backup artifacts, restore, and import planning/running. Swift owns native UI, app state, asset tree integration, query presentation, and confirmation flows. Database operations reuse existing SSH server records, encryption, `SessionPool`, and `last_error` patterns.

**Tech Stack:** Rust 2021, rusqlite, ssh2, serde, mysql crate, postgres crate, Swift 5.9, SwiftUI, XcodeGen.

## Global Constraints

- Current checkout may contain unrelated user edits; do not revert or rewrite work outside the files owned by the assigned task.
- `project.yml` is the source of Xcode project configuration; do not manually edit `.pbxproj`.
- Do not commit build artifacts, static libraries, DerivedData, or generated temporary backups.
- Database passwords must be encrypted at rest with the existing `crypto` module.
- Remote SQLite must execute on the remote machine through `sqlite3`; do not implement local SFTP download fallback.
- Missing remote `sqlite3` must be installed only after explicit UI confirmation.
- Backups must include table structure and table data.
- SQLite backup import into MySQL must support mapping source field names to different target field names, including `system` to `system1`.
- MVP backup artifact is a single `.orbit-db-backup.json` file for small and medium databases.
- Rust tests must be written before production code for pure logic.
- Verification commands: `cd orbit-rs && cargo test`; `cd orbit-app && xcodegen generate`; `cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build`.

---

## File Structure

Rust worker owns:

- Create: `orbit-rs/src/database/mod.rs`
- Create: `orbit-rs/src/database/models.rs`
- Create: `orbit-rs/src/database/store.rs`
- Create: `orbit-rs/src/database/sql.rs`
- Create: `orbit-rs/src/database/sqlite_remote.rs`
- Create: `orbit-rs/src/database/mysql.rs`
- Create: `orbit-rs/src/database/postgres.rs`
- Create: `orbit-rs/src/database/backup.rs`
- Create: `orbit-rs/src/database/import_mysql.rs`
- Modify: `orbit-rs/src/lib.rs`
- Modify: `orbit-rs/src/db.rs`
- Modify: `orbit-rs/src/ffi.rs`
- Modify: `orbit-rs/Cargo.toml`
- Regenerate: `orbit-rs/include/orbit.h`

Swift/UI worker owns after Rust FFI exists:

- Modify: `orbit-app/Orbit/Models/Models.swift`
- Modify: `orbit-app/Orbit/OrbitBridge.swift`
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`
- Modify: `orbit-app/Orbit/ViewModels/InventoryState.swift`
- Modify: `orbit-app/Orbit/Views/AssetTreeView.swift`
- Modify: `orbit-app/Orbit/Views/DatabaseView.swift`
- Modify: `orbit-app/Orbit/Views/SettingsView.swift`
- Create: `orbit-app/Orbit/Views/DatabaseConnectionDialog.swift`
- Create: `orbit-app/Orbit/Views/DatabaseBackupSheet.swift`
- Create: `orbit-app/Orbit/Views/DatabaseImportMappingView.swift`
- Modify: `orbit-app/project.yml` only if source inclusion needs adjustment.

Review agent owns no writes unless dispatched with findings after implementation.

---

### Task 1: Rust Database Models, Store, and Migrations

**Files:**
- Create: `orbit-rs/src/database/models.rs`
- Create: `orbit-rs/src/database/store.rs`
- Create: `orbit-rs/src/database/mod.rs`
- Modify: `orbit-rs/src/lib.rs`
- Modify: `orbit-rs/src/db.rs`
- Modify: `orbit-rs/src/ffi.rs`

**Interfaces:**
- Produces: `DatabaseConnection`, `DatabaseConnectionInput`, `DatabaseBackupRecord`, `DatabaseOperationResult`
- Produces: `DatabaseStore::list_connections`, `add_connection`, `update_connection`, `delete_connection`, `get_connection`, `add_backup_record`, `list_backup_records`
- Consumes: existing `crate::crypto`, `crate::db::Database`, `json_to_out`, `parse_json_input`

- [ ] **Step 1: Write failing Rust store tests**

Add tests in `orbit-rs/src/database/store.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;

    fn test_db() -> Database {
        Database::new(":memory:").expect("in-memory db")
    }

    #[test]
    fn stores_and_decrypts_database_connection_password() {
        let db = test_db();
        let input = DatabaseConnectionInput {
            name: "prod mysql".into(),
            group_name: Some("prod".into()),
            engine: "mysql".into(),
            ssh_server_id: Some("ssh-1".into()),
            use_ssh_tunnel: Some(true),
            host: Some("mysql.internal".into()),
            port: Some(3306),
            database_name: Some("app".into()),
            username: Some("app_user".into()),
            password: Some("secret".into()),
            sqlite_path: None,
            ssl_mode: Some("prefer".into()),
        };

        let saved = DatabaseStore::add_connection(&db, &input).expect("add");
        let loaded = DatabaseStore::get_connection(&db, &saved.id).expect("get");

        assert_eq!(loaded.name, "prod mysql");
        assert_eq!(loaded.engine, "mysql");
        assert_eq!(loaded.password, "secret");
        assert!(loaded.use_ssh_tunnel);
    }

    #[test]
    fn backup_records_are_listed_newest_first() {
        let db = test_db();
        DatabaseStore::add_backup_record(
            &db,
            &DatabaseBackupRecordInput {
                connection_id: "c1".into(),
                connection_name: "sqlite".into(),
                engine: "remote_sqlite".into(),
                artifact_path: "/tmp/a.orbit-db-backup.json".into(),
                operation: "backup".into(),
                status: "success".into(),
                summary: "1 table, 2 rows".into(),
            },
        )
        .expect("record");

        let records = DatabaseStore::list_backup_records(&db).expect("records");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].operation, "backup");
    }
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `cd orbit-rs && cargo test database::store -- --nocapture`

Expected: FAIL because `database` module and store types do not exist.

- [ ] **Step 3: Implement migrations**

In `orbit-rs/src/db.rs`, extend `Database::new` to create `database_connections` and `database_backup_records` using the schema from the design spec. Keep existing server and credential tables unchanged.

- [ ] **Step 4: Implement models and store**

Create `models.rs` with serde DTOs matching the spec:

```rust
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DatabaseConnection {
    pub id: String,
    pub name: String,
    pub group_name: String,
    pub engine: String,
    pub ssh_server_id: String,
    pub use_ssh_tunnel: bool,
    pub host: String,
    pub port: u16,
    pub database_name: String,
    pub username: String,
    pub password: String,
    pub sqlite_path: String,
    pub ssl_mode: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DatabaseConnectionInput {
    pub name: String,
    pub group_name: Option<String>,
    pub engine: String,
    pub ssh_server_id: Option<String>,
    pub use_ssh_tunnel: Option<bool>,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub database_name: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub sqlite_path: Option<String>,
    pub ssl_mode: Option<String>,
}
```

Add backup record DTOs and operation result DTOs in the same file.

- [ ] **Step 5: Add FFI CRUD functions**

Add these functions to `orbit-rs/src/ffi.rs`:

```rust
#[no_mangle]
pub extern "C" fn orbit_db_list_connections(app: *mut OrbitApp, out_json: *mut *mut c_char) -> i32
#[no_mangle]
pub extern "C" fn orbit_db_add_connection(app: *mut OrbitApp, json_input: *const c_char, out_json: *mut *mut c_char) -> i32
#[no_mangle]
pub extern "C" fn orbit_db_update_connection(app: *mut OrbitApp, id: *const c_char, json_input: *const c_char, out_json: *mut *mut c_char) -> i32
#[no_mangle]
pub extern "C" fn orbit_db_delete_connection(app: *mut OrbitApp, id: *const c_char) -> i32
#[no_mangle]
pub extern "C" fn orbit_db_list_backup_records(app: *mut OrbitApp, out_json: *mut *mut c_char) -> i32
```

Each function must call `app.clear_error()`, set detailed `last_error` on failures, and return JSON using the existing `json_to_out`.

- [ ] **Step 6: Verify GREEN**

Run: `cd orbit-rs && cargo test database::store -- --nocapture`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add orbit-rs/src/database orbit-rs/src/lib.rs orbit-rs/src/db.rs orbit-rs/src/ffi.rs
git commit -m "feat: add database connection store"
```

---

### Task 2: Rust SQL Helpers, Remote SQLite, and Import Planning

**Files:**
- Create: `orbit-rs/src/database/sql.rs`
- Create: `orbit-rs/src/database/sqlite_remote.rs`
- Create: `orbit-rs/src/database/import_mysql.rs`
- Modify: `orbit-rs/src/database/models.rs`
- Modify: `orbit-rs/src/database/mod.rs`

**Interfaces:**
- Produces: `is_write_statement(sql: &str) -> bool`
- Produces: `mysql_type_for_sqlite(sqlite_type: &str) -> String`
- Produces: `validate_mysql_import_plan(plan: &DatabaseImportPlan) -> Result<()>`
- Produces: `SqliteRemote::test_connection`, `list_schema`, `execute`
- Consumes: `SshManager::exec_command`, `SessionPool`, `Server`

- [ ] **Step 1: Write failing helper tests**

Add tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_write_statements_with_leading_comments() {
        assert!(is_write_statement("  -- change row\nUPDATE users SET name='a'"));
        assert!(is_write_statement("/* ddl */ CREATE TABLE t(id INTEGER)"));
        assert!(!is_write_statement("WITH recent AS (SELECT 1) SELECT * FROM recent"));
        assert!(!is_write_statement("SELECT * FROM users LIMIT 10"));
    }

    #[test]
    fn maps_sqlite_types_to_mysql_defaults() {
        assert_eq!(mysql_type_for_sqlite("INTEGER"), "BIGINT");
        assert_eq!(mysql_type_for_sqlite("REAL"), "DOUBLE");
        assert_eq!(mysql_type_for_sqlite("TEXT"), "TEXT");
        assert_eq!(mysql_type_for_sqlite("BLOB"), "BLOB");
        assert_eq!(mysql_type_for_sqlite("NUMERIC"), "DECIMAL(38,10)");
        assert_eq!(mysql_type_for_sqlite("VARCHAR(255)"), "TEXT");
    }

    #[test]
    fn accepts_field_rename_mapping_from_system_to_system1() {
        let plan = DatabaseImportPlan::single_table_for_test(
            "source_table",
            "target_table",
            vec![("id", "id"), ("system", "system1")],
        );

        validate_mysql_import_plan(&plan).expect("valid mapping");
    }
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `cd orbit-rs && cargo test database::sql database::import_mysql -- --nocapture`

Expected: FAIL because helper modules and import plan models do not exist.

- [ ] **Step 3: Implement SQL helper functions**

Implement comment-stripping and first-token detection in `sql.rs`. Treat these first tokens as write statements: `insert`, `update`, `delete`, `drop`, `alter`, `create`, `replace`, `truncate`, `vacuum`, `attach`, `detach`, `pragma`.

- [ ] **Step 4: Implement SQLite remote command builder**

`sqlite_remote.rs` must build commands for:

```bash
command -v sqlite3
sqlite3 -readonly -json '<path>' '<sql>'
sqlite3 -json '<path>' 'BEGIN IMMEDIATE; <sql>; SELECT changes() AS affected_rows; COMMIT;'
```

Use a local shell quoting helper:

```rust
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}
```

Package manager detection must return the exact install commands from the design spec.

- [ ] **Step 5: Implement import plan models and validation**

Add models for `DatabaseImportPlan`, `DatabaseImportTablePlan`, `DatabaseImportColumnMapping`, and validation that rejects missing required target fields in existing-table mode while accepting renamed mappings.

- [ ] **Step 6: Verify GREEN**

Run: `cd orbit-rs && cargo test database::sql database::import_mysql database::sqlite_remote -- --nocapture`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add orbit-rs/src/database
git commit -m "feat: add database sql helpers and sqlite import planning"
```

---

### Task 3: Rust Query Engines, Backup, Restore, and FFI

**Files:**
- Create: `orbit-rs/src/database/mysql.rs`
- Create: `orbit-rs/src/database/postgres.rs`
- Create: `orbit-rs/src/database/backup.rs`
- Modify: `orbit-rs/src/database/mod.rs`
- Modify: `orbit-rs/src/database/models.rs`
- Modify: `orbit-rs/src/database/sqlite_remote.rs`
- Modify: `orbit-rs/src/database/import_mysql.rs`
- Modify: `orbit-rs/src/ffi.rs`
- Modify: `orbit-rs/Cargo.toml`
- Regenerate: `orbit-rs/include/orbit.h`

**Interfaces:**
- Produces: `DatabaseManager::test_connection`, `list_schema`, `execute`, `backup`, `restore`, `prepare_import`, `run_import`
- Produces FFI functions from the design spec
- Consumes: Task 1 store, Task 2 helpers

- [ ] **Step 1: Write failing backup/import tests**

Add tests in `backup.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backup_artifact_round_trips_schema_and_rows() {
        let artifact = DatabaseBackupArtifact::single_table_for_test(
            "users",
            vec![("id", "INTEGER"), ("system", "TEXT")],
            vec![vec![("id", Some("1")), ("system", Some("prod"))]],
        );

        let json = serde_json::to_string(&artifact).expect("serialize");
        let parsed: DatabaseBackupArtifact = serde_json::from_str(&json).expect("parse");

        assert_eq!(parsed.tables[0].name, "users");
        assert_eq!(parsed.tables[0].columns[1].name, "system");
        assert_eq!(parsed.tables[0].rows[0].get("system").unwrap().as_deref(), Some("prod"));
    }
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `cd orbit-rs && cargo test database::backup -- --nocapture`

Expected: FAIL until backup artifact helpers are implemented.

- [ ] **Step 3: Add dependencies**

In `orbit-rs/Cargo.toml`, add:

```toml
mysql = "25"
postgres = "0.19"
```

Use default TLS behavior for MVP. Keep dependency changes limited to database drivers.

- [ ] **Step 4: Implement DatabaseManager routing**

`DatabaseManager` must:

- Load connection config by id using `DatabaseStore`.
- Route `remote_sqlite` to `SqliteRemote`.
- Route `mysql` to `MysqlEngine`.
- Route `postgres` to `PostgresEngine`.
- Use temporary SSH port forwarding for MySQL/PostgreSQL when `use_ssh_tunnel` is true.

- [ ] **Step 5: Implement backup and restore**

Backup must write `.orbit-db-backup.json` under `~/Library/Application Support/orbit/backups/` and create a backup record. Restore must support same-engine overwrite mode for MVP and create a restore record.

- [ ] **Step 6: Implement SQLite backup to MySQL import**

`prepare_import` must generate default plans for new-table and existing-table modes. `run_import` must validate mappings, create tables in new-table mode, and batch insert rows with a batch size of 500.

- [ ] **Step 7: Add FFI operations**

Add:

```rust
orbit_db_test_connection
orbit_db_list_schema
orbit_db_execute
orbit_db_backup
orbit_db_restore
orbit_db_prepare_import
orbit_db_run_import
```

All functions must set detailed `last_error` on failure and use `apiErrorWithMessage` on the Swift side later.

- [ ] **Step 8: Regenerate C header**

Run: `cd orbit-rs && cargo build`

Expected: `orbit-rs/include/orbit.h` includes all new `orbit_db_*` declarations.

- [ ] **Step 9: Verify GREEN**

Run: `cd orbit-rs && cargo test`

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add orbit-rs/Cargo.toml orbit-rs/Cargo.lock orbit-rs/src/database orbit-rs/src/ffi.rs orbit-rs/include/orbit.h
git commit -m "feat: add database engines backup and import ffi"
```

---

### Task 4: Swift Models, Bridge, and App State

**Files:**
- Modify: `orbit-app/Orbit/Models/Models.swift`
- Modify: `orbit-app/Orbit/OrbitBridge.swift`
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`
- Modify: `orbit-app/Orbit/ViewModels/InventoryState.swift`

**Interfaces:**
- Consumes: Rust FFI declarations in `orbit-rs/include/orbit.h`
- Produces: Swift Codable mirrors for all database DTOs
- Produces: bridge methods for every `orbit_db_*` FFI function
- Produces: AppState loaders and CRUD methods for database connections and backup records

- [ ] **Step 1: Add Swift DTOs**

Add Codable structs for:

```swift
struct DatabaseConnection: Codable, Identifiable {
    let id: String
    let name: String
    let group_name: String
    let engine: String
    let ssh_server_id: String
    let use_ssh_tunnel: Bool
    let host: String
    let port: UInt16
    let database_name: String
    let username: String
    let password: String
    let sqlite_path: String
    let ssl_mode: String
    let created_at: String
    let updated_at: String
}

struct DatabaseConnectionInput: Codable {
    var name: String
    var group_name: String?
    var engine: String
    var ssh_server_id: String?
    var use_ssh_tunnel: Bool?
    var host: String?
    var port: UInt16?
    var database_name: String?
    var username: String?
    var password: String?
    var sqlite_path: String?
    var ssl_mode: String?
}

struct DatabaseSchema: Codable {
    let connection_id: String
    let engine: String
    let tables: [DatabaseTableSchema]
}

struct DatabaseTableSchema: Codable, Identifiable {
    let name: String
    let columns: [DatabaseColumnSchema]
    var id: String { name }
}

struct DatabaseColumnSchema: Codable, Identifiable {
    let name: String
    let db_type: String
    let nullable: Bool
    let primary_key: Bool
    let default_value: String?
    var id: String { name }
}

struct DatabaseQueryRequest: Codable {
    var sql: String
    var read_only: Bool
    var timeout_ms: UInt32
}

struct DatabaseQueryResult: Codable {
    let columns: [String]
    let rows: [[String?]]
    let affected_rows: UInt64
    let elapsed_ms: UInt64
    let message: String
}

struct DatabaseBackupRecord: Codable, Identifiable {
    let id: String
    let connection_id: String
    let connection_name: String
    let engine: String
    let artifact_path: String
    let operation: String
    let status: String
    let summary: String
    let created_at: String
}

struct DatabaseOperationResult: Codable {
    let ok: Bool
    let code: String
    let message: String
    let artifact_path: String?
    let affected_rows: UInt64?
}

struct DatabaseRestoreRequest: Codable {
    var backup_path: String
    var target_connection_id: String
    var mode: String
}

struct DatabaseImportPlan: Codable {
    var backup_path: String
    var target_connection_id: String
    var mode: String
    var tables: [DatabaseImportTablePlan]
}

struct DatabaseImportTablePlan: Codable, Identifiable {
    var source_table: String
    var target_table: String
    var columns: [DatabaseImportColumnMapping]
    var id: String { source_table }
}

struct DatabaseImportColumnMapping: Codable, Identifiable {
    var source_column: String
    var target_column: String?
    var target_type: String
    var required_without_default: Bool
    var id: String { source_column }
}

struct DatabaseImportRequest: Codable {
    var plan: DatabaseImportPlan
}
```

Use field names matching Rust JSON exactly.

- [ ] **Step 2: Add OrbitBridge database wrappers**

Implement sync and async wrappers:

```swift
func listDatabaseConnections() throws -> [DatabaseConnection]
func addDatabaseConnection(input: DatabaseConnectionInput) throws -> DatabaseConnection
func updateDatabaseConnection(id: String, input: DatabaseConnectionInput) throws -> DatabaseConnection
func deleteDatabaseConnection(id: String) throws
func testDatabaseConnection(id: String, installSqlite: Bool) throws -> DatabaseOperationResult
func listDatabaseSchema(connectionId: String) throws -> DatabaseSchema
func executeDatabaseQuery(connectionId: String, request: DatabaseQueryRequest) throws -> DatabaseQueryResult
func backupDatabase(connectionId: String) throws -> DatabaseOperationResult
func listDatabaseBackupRecords() throws -> [DatabaseBackupRecord]
func restoreDatabase(request: DatabaseRestoreRequest) throws -> DatabaseOperationResult
func prepareDatabaseImport(backupPath: String, targetConnectionId: String, mode: String) throws -> DatabaseImportPlan
func runDatabaseImport(request: DatabaseImportRequest) throws -> DatabaseOperationResult
```

Every wrapper must throw `OrbitError.apiErrorWithMessage(rc, lastErrorMessage())` on non-zero database operation returns.

- [ ] **Step 3: Add AppState storage and methods**

Add published state:

```swift
@Published var databaseConnections: [DatabaseConnection] = []
@Published var databaseBackupRecords: [DatabaseBackupRecord] = []
@Published var editingDatabaseConnection: DatabaseConnection?
@Published var databaseOperationLoading: Bool = false
@Published var databasePanelSnapshots: [String: DatabasePanelSnapshot] = [:]
```

Add `loadDatabaseConnections`, `loadDatabaseBackupRecords`, `addDatabaseConnection`, `updateDatabaseConnection`, `deleteDatabaseConnection`, and snapshot methods.

- [ ] **Step 4: Verify build**

Run: `cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build`

Expected: build reaches any UI references not yet implemented or succeeds if no view references exist.

- [ ] **Step 5: Commit**

```bash
git add orbit-app/Orbit/Models/Models.swift orbit-app/Orbit/OrbitBridge.swift orbit-app/Orbit/ViewModels/AppState.swift orbit-app/Orbit/ViewModels/InventoryState.swift
git commit -m "feat: add database swift bridge and state"
```

---

### Task 5: Swift Asset Tree, Connection Dialog, and Database View

**Files:**
- Modify: `orbit-app/Orbit/Views/AssetTreeView.swift`
- Modify: `orbit-app/Orbit/Views/DatabaseView.swift`
- Modify: `orbit-app/Orbit/Views/MainView.swift`
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`
- Create: `orbit-app/Orbit/Views/DatabaseConnectionDialog.swift`

**Interfaces:**
- Consumes: AppState database connection methods from Task 4
- Produces: database asset tree nodes and connection editor
- Produces: live schema/query DatabaseView replacing mock data

- [ ] **Step 1: Replace mock DatabaseView state**

Remove `mockTables` and `mockResults`. Add state:

```swift
@State private var schema: DatabaseSchema?
@State private var queryResult: DatabaseQueryResult?
@State private var errorMessage: String?
@State private var isLoadingSchema = false
@State private var isExecuting = false
```

- [ ] **Step 2: Load schema on appear**

On appear, call `appState.bridge.listDatabaseSchemaAsync(connectionId:)`. Render tables from returned schema.

- [ ] **Step 3: Execute SQL**

Execution builds:

```swift
DatabaseQueryRequest(
    sql: sqlText,
    read_only: dbReadOnlyMode,
    timeout_ms: UInt32(dbQueryTimeout * 1000)
)
```

Show `queryResult.columns` and `queryResult.rows` in the results area.

- [ ] **Step 4: Add connection dialog**

`DatabaseConnectionDialog` must support remote SQLite, MySQL, and PostgreSQL fields. Remote SQLite requires SSH server and path. MySQL/PostgreSQL support SSH tunnel selection and SSL mode.

- [ ] **Step 5: Add asset tree database section**

Under the asset tree, render database connections grouped by `group_name`, with menu actions for open, test, backup, edit, delete.

- [ ] **Step 6: Verify build**

Run: `cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add orbit-app/Orbit/Views/AssetTreeView.swift orbit-app/Orbit/Views/DatabaseView.swift orbit-app/Orbit/Views/MainView.swift orbit-app/Orbit/Views/DatabaseConnectionDialog.swift orbit-app/Orbit/ViewModels/AppState.swift
git commit -m "feat: add database assets and live query view"
```

---

### Task 6: Swift Backup, Restore, Import Mapping UI

**Files:**
- Create: `orbit-app/Orbit/Views/DatabaseBackupSheet.swift`
- Create: `orbit-app/Orbit/Views/DatabaseImportMappingView.swift`
- Modify: `orbit-app/Orbit/Views/DatabaseView.swift`
- Modify: `orbit-app/Orbit/ViewModels/AppState.swift`

**Interfaces:**
- Consumes: bridge backup/restore/import methods from Task 4
- Produces: one-click backup flow, restore flow, SQLite-to-MySQL import mapping flow

- [ ] **Step 1: Add backup action**

Add a toolbar button in `DatabaseView` that calls `backupDatabaseAsync(connectionId:)` and displays the returned artifact path and summary.

- [ ] **Step 2: Add restore sheet**

`DatabaseBackupSheet` must allow selecting `.orbit-db-backup.json`, choosing target connection, and running restore.

- [ ] **Step 3: Add SQLite to MySQL import mapping**

`DatabaseImportMappingView` must display tables and columns from `DatabaseImportPlan`. It must allow editing target table names and mapping source field `system` to target field `system1`.

- [ ] **Step 4: Block invalid import**

Disable import when the plan contains a required target field without source mapping or default value. Show the exact target table and field name in the message.

- [ ] **Step 5: Run import**

Call `runDatabaseImportAsync(request:)`, then display imported table count, row count, skipped fields, and error summary.

- [ ] **Step 6: Verify build**

Run: `cd orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add orbit-app/Orbit/Views/DatabaseBackupSheet.swift orbit-app/Orbit/Views/DatabaseImportMappingView.swift orbit-app/Orbit/Views/DatabaseView.swift orbit-app/Orbit/ViewModels/AppState.swift
git commit -m "feat: add database backup restore import ui"
```

---

### Task 7: Final Verification and Review

**Files:**
- Review all files changed since commit `43eddf3`.

**Interfaces:**
- Consumes: Tasks 1-6
- Produces: reviewed implementation ready for user validation

- [ ] **Step 1: Run full verification**

```bash
cd orbit-rs && cargo test
cd ../orbit-app && xcodegen generate
cd ../orbit-app && xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release build
```

Expected: Rust tests pass and Xcode build succeeds.

- [ ] **Step 2: Request coding review**

Dispatch a code review agent with:

- Requirements: `docs/superpowers/specs/2026-07-08-database-connections-backup-design.md`
- Plan: `docs/superpowers/plans/2026-07-08-database-connections-backup.md`
- Base SHA: `43eddf3`
- Head SHA: current HEAD

- [ ] **Step 3: Fix Critical and Important findings**

Apply fixes for any Critical or Important review findings. Re-run the focused tests and then the full verification commands.

- [ ] **Step 4: Final report**

Report changed files, commits, verification output, known limitations, and any remaining Minor review items.
