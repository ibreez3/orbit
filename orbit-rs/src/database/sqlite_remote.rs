use std::collections::HashMap;
use std::time::Instant;

use anyhow::{anyhow, Result};

use crate::database::models::{
    DatabaseColumnSchema, DatabaseOperationResult, DatabaseQueryResult, DatabaseTableSchema,
};
use crate::database::sql::is_write_statement;
use crate::db::Database;
use crate::models::Server;
use crate::ssh;
use crate::transport;

pub struct SqliteRemote;

pub enum SqliteRemoteCommand {
    DetectSqlite,
    Read { path: String, sql: String },
    Write { path: String, sql: String },
}

impl SqliteRemoteCommand {
    pub fn detect_sqlite() -> Self {
        Self::DetectSqlite
    }

    pub fn read(path: &str, sql: &str) -> Self {
        Self::Read {
            path: path.into(),
            sql: sql.into(),
        }
    }

    pub fn write(path: &str, sql: &str) -> Self {
        Self::Write {
            path: path.into(),
            sql: sql.into(),
        }
    }

    pub fn to_shell(&self) -> String {
        match self {
            Self::DetectSqlite => "command -v sqlite3".into(),
            Self::Read { path, sql } => {
                format!(
                    "sqlite3 -readonly -json {} {}",
                    shell_quote(path),
                    shell_quote(sql)
                )
            }
            Self::Write { path, sql } => {
                let wrapped = format!(
                    "BEGIN IMMEDIATE; {}; SELECT changes() AS affected_rows; COMMIT;",
                    sql.trim().trim_end_matches(';')
                );
                format!(
                    "sqlite3 -json {} {}",
                    shell_quote(path),
                    shell_quote(&wrapped)
                )
            }
        }
    }
}

impl SqliteRemote {
    pub fn test_connection(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        install_sqlite: bool,
    ) -> Result<DatabaseOperationResult> {
        let check = ssh::SshManager::exec_command(
            pool,
            server,
            db,
            &SqliteRemoteCommand::detect_sqlite().to_shell(),
        )?;
        if !check.trim().is_empty() {
            return Ok(DatabaseOperationResult {
                ok: true,
                code: "ok".into(),
                message: "sqlite3 is available".into(),
                artifact_path: None,
                affected_rows: None,
            });
        }

        let manager = Self::detect_package_manager(pool, server, db)?;
        if !install_sqlite {
            return Ok(missing_sqlite_result(manager.as_deref()));
        }

        let install_command = manager
            .as_deref()
            .and_then(sqlite_install_command)
            .ok_or_else(|| {
                anyhow!("sqlite3 is not installed and no supported package manager was found")
            })?;

        ssh::SshManager::exec_command(pool, server, db, install_command)?;
        let recheck = ssh::SshManager::exec_command(
            pool,
            server,
            db,
            &SqliteRemoteCommand::detect_sqlite().to_shell(),
        )?;
        if recheck.trim().is_empty() {
            return Err(anyhow!(
                "sqlite3 installation command completed but sqlite3 is still unavailable"
            ));
        }

        Ok(DatabaseOperationResult {
            ok: true,
            code: "installed".into(),
            message: "sqlite3 installed successfully".into(),
            artifact_path: None,
            affected_rows: None,
        })
    }

    pub fn list_table_names(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        sqlite_path: &str,
    ) -> Result<String> {
        let sql = "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name";
        let command = SqliteRemoteCommand::read(sqlite_path, sql).to_shell();
        ssh::SshManager::exec_command(pool, server, db, &command)
    }

    pub fn table_info(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        sqlite_path: &str,
        table_name: &str,
    ) -> Result<String> {
        let sql = format!("PRAGMA table_info({})", sqlite_ident(table_name));
        let command = SqliteRemoteCommand::read(sqlite_path, &sql).to_shell();
        ssh::SshManager::exec_command(pool, server, db, &command)
    }

    pub fn list_schema(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        sqlite_path: &str,
    ) -> Result<Vec<DatabaseTableSchema>> {
        let tables_json = Self::list_table_names(pool, server, db, sqlite_path)?;
        let table_rows: Vec<HashMap<String, serde_json::Value>> =
            serde_json::from_str(&tables_json).unwrap_or_default();
        let mut tables = Vec::new();
        for row in table_rows {
            let Some(name) = row.get("name").and_then(|value| value.as_str()) else {
                continue;
            };
            let info_json = Self::table_info(pool, server, db, sqlite_path, name)?;
            let info_rows: Vec<HashMap<String, serde_json::Value>> =
                serde_json::from_str(&info_json).unwrap_or_default();
            let columns = info_rows
                .into_iter()
                .filter_map(|info| {
                    let name = info.get("name")?.as_str()?.to_string();
                    Some(DatabaseColumnSchema {
                        name,
                        db_type: info
                            .get("type")
                            .and_then(|value| value.as_str())
                            .unwrap_or("TEXT")
                            .to_string(),
                        nullable: info
                            .get("notnull")
                            .and_then(|value| value.as_i64())
                            .unwrap_or(0)
                            == 0,
                        primary_key: info.get("pk").and_then(|value| value.as_i64()).unwrap_or(0)
                            != 0,
                        default_value: info
                            .get("dflt_value")
                            .and_then(|value| value.as_str())
                            .map(str::to_string),
                    })
                })
                .collect();
            tables.push(DatabaseTableSchema {
                name: name.to_string(),
                columns,
            });
        }
        Ok(tables)
    }

    pub fn execute_raw(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        sqlite_path: &str,
        sql: &str,
    ) -> Result<String> {
        let command = if is_write_statement(sql) {
            SqliteRemoteCommand::write(sqlite_path, sql)
        } else {
            SqliteRemoteCommand::read(sqlite_path, sql)
        }
        .to_shell();
        ssh::SshManager::exec_command(pool, server, db, &command)
    }

    pub fn execute(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        sqlite_path: &str,
        sql: &str,
    ) -> Result<DatabaseQueryResult> {
        let started = Instant::now();
        let write_statement = is_write_statement(sql);
        let output = Self::execute_raw(pool, server, db, sqlite_path, sql)?;
        let elapsed_ms = started.elapsed().as_millis() as u64;

        if write_statement {
            let rows: Vec<HashMap<String, serde_json::Value>> =
                serde_json::from_str(&output).unwrap_or_default();
            let affected_rows = rows
                .first()
                .and_then(|row| row.get("affected_rows"))
                .and_then(|value| value.as_u64())
                .unwrap_or(0);
            return Ok(DatabaseQueryResult::empty_message(
                "Query executed",
                affected_rows,
                elapsed_ms,
            ));
        }

        let rows: Vec<HashMap<String, serde_json::Value>> =
            serde_json::from_str(&output).unwrap_or_default();
        let columns = rows
            .first()
            .map(|row| row.keys().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        let result_rows = rows
            .into_iter()
            .map(|row| {
                columns
                    .iter()
                    .map(|column| json_value_to_string(row.get(column)))
                    .collect()
            })
            .collect();

        Ok(DatabaseQueryResult {
            columns,
            rows: result_rows,
            affected_rows: 0,
            elapsed_ms,
            message: String::new(),
        })
    }

    fn detect_package_manager(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
    ) -> Result<Option<String>> {
        let command = package_manager_detection_command();
        let output = ssh::SshManager::exec_command(pool, server, db, &command)?;
        Ok(output
            .lines()
            .next()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string))
    }
}

fn sqlite_ident(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}

fn json_value_to_string(value: Option<&serde_json::Value>) -> Option<String> {
    match value {
        Some(serde_json::Value::Null) | None => None,
        Some(serde_json::Value::String(value)) => Some(value.clone()),
        Some(value) => Some(value.to_string()),
    }
}

fn missing_sqlite_result(manager: Option<&str>) -> DatabaseOperationResult {
    let message = match manager.and_then(sqlite_install_command) {
        Some(command) => format!("sqlite3 is not installed. Suggested command: {}", command),
        None => "sqlite3 is not installed and no supported package manager was found".into(),
    };

    DatabaseOperationResult {
        ok: false,
        code: "sqlite_missing".into(),
        message,
        artifact_path: None,
        affected_rows: None,
    }
}

pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

pub fn sqlite_install_command(manager: &str) -> Option<&'static str> {
    match manager {
        "apt-get" => Some("sudo apt-get update && sudo apt-get install -y sqlite3"),
        "dnf" => Some("sudo dnf install -y sqlite"),
        "yum" => Some("sudo yum install -y sqlite"),
        "pacman" => Some("sudo pacman -Sy --noconfirm sqlite"),
        "zypper" => Some("sudo zypper --non-interactive install sqlite3"),
        "apk" => Some("sudo apk add sqlite"),
        _ => None,
    }
}

pub fn package_manager_detection_command() -> String {
    [
        "if command -v apt-get >/dev/null 2>&1; then echo apt-get",
        "elif command -v dnf >/dev/null 2>&1; then echo dnf",
        "elif command -v yum >/dev/null 2>&1; then echo yum",
        "elif command -v pacman >/dev/null 2>&1; then echo pacman",
        "elif command -v zypper >/dev/null 2>&1; then echo zypper",
        "elif command -v apk >/dev/null 2>&1; then echo apk",
        "else echo ''",
        "fi",
    ]
    .join("; ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_remote_sqlite_path_and_sql_for_shell() {
        assert_eq!(
            shell_quote("/tmp/prod's db.sqlite"),
            "'/tmp/prod'\"'\"'s db.sqlite'"
        );
        assert_eq!(
            SqliteRemoteCommand::read("/tmp/prod's db.sqlite", "SELECT 'ok'").to_shell(),
            "sqlite3 -readonly -json '/tmp/prod'\"'\"'s db.sqlite' 'SELECT '\"'\"'ok'\"'\"''"
        );
    }

    #[test]
    fn builds_write_command_wrapped_in_transaction() {
        assert_eq!(
            SqliteRemoteCommand::write("/tmp/app.db", "UPDATE users SET name='a'").to_shell(),
            "sqlite3 -json '/tmp/app.db' 'BEGIN IMMEDIATE; UPDATE users SET name='\"'\"'a'\"'\"'; SELECT changes() AS affected_rows; COMMIT;'"
        );
    }

    #[test]
    fn maps_package_managers_to_exact_install_commands() {
        assert_eq!(
            sqlite_install_command("apt-get"),
            Some("sudo apt-get update && sudo apt-get install -y sqlite3")
        );
        assert_eq!(
            sqlite_install_command("dnf"),
            Some("sudo dnf install -y sqlite")
        );
        assert_eq!(
            sqlite_install_command("yum"),
            Some("sudo yum install -y sqlite")
        );
        assert_eq!(
            sqlite_install_command("pacman"),
            Some("sudo pacman -Sy --noconfirm sqlite")
        );
        assert_eq!(
            sqlite_install_command("zypper"),
            Some("sudo zypper --non-interactive install sqlite3")
        );
        assert_eq!(sqlite_install_command("apk"), Some("sudo apk add sqlite"));
        assert_eq!(sqlite_install_command("unknown"), None);
    }

    #[test]
    fn package_manager_detection_uses_explicit_if_elif_chain_in_order() {
        let command = package_manager_detection_command();
        let expected_parts = [
            "if command -v apt-get >/dev/null 2>&1; then echo apt-get",
            "elif command -v dnf >/dev/null 2>&1; then echo dnf",
            "elif command -v yum >/dev/null 2>&1; then echo yum",
            "elif command -v pacman >/dev/null 2>&1; then echo pacman",
            "elif command -v zypper >/dev/null 2>&1; then echo zypper",
            "elif command -v apk >/dev/null 2>&1; then echo apk",
            "else echo ''",
            "fi",
        ];

        let mut previous_index = 0;
        for part in expected_parts {
            let index = command.find(part).expect("expected command part");
            assert!(index >= previous_index);
            previous_index = index;
        }
    }

    #[test]
    fn missing_sqlite_result_reports_unsupported_manager_without_install_command() {
        let result = missing_sqlite_result(None);

        assert!(!result.ok);
        assert_eq!(result.code, "sqlite_missing");
        assert!(result.message.contains("sqlite3 is not installed"));
        assert!(result
            .message
            .contains("no supported package manager was found"));
        assert!(!result.message.contains("Suggested command:"));
    }

    #[test]
    fn missing_sqlite_result_includes_suggested_command_for_supported_manager() {
        let result = missing_sqlite_result(Some("apt-get"));

        assert!(!result.ok);
        assert_eq!(result.code, "sqlite_missing");
        assert!(result
            .message
            .contains("Suggested command: sudo apt-get update && sudo apt-get install -y sqlite3"));
    }
}
