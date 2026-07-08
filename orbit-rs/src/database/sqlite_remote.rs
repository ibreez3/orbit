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

const SQLITE_COLUMN_SEPARATOR: &str = "\x1f";
const SQLITE_NULL_VALUE: &str = "__ORBIT_SQLITE_NULL__";

pub enum SqliteRemoteCommand {
    DetectSqlite,
    Read { path: String, sql: String },
    Write { path: String, sql: String },
    Script { path: String, sql: String },
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

    pub fn script(path: &str, sql: &str) -> Self {
        Self::Script {
            path: path.into(),
            sql: sql.into(),
        }
    }

    pub fn to_shell(&self) -> String {
        match self {
            Self::DetectSqlite => {
                "if command -v sqlite3 >/dev/null 2>&1; then command -v sqlite3; fi".into()
            }
            Self::Read { path, sql } => {
                format!(
                    "sqlite3 -header -separator {} -nullvalue {} {} {}",
                    shell_quote(SQLITE_COLUMN_SEPARATOR),
                    shell_quote(SQLITE_NULL_VALUE),
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
                    "sqlite3 -header -separator {} -nullvalue {} {} {}",
                    shell_quote(SQLITE_COLUMN_SEPARATOR),
                    shell_quote(SQLITE_NULL_VALUE),
                    shell_quote(path),
                    shell_quote(&wrapped)
                )
            }
            Self::Script { path, sql } => {
                format!("sqlite3 {} {}", shell_quote(path), shell_quote(sql))
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
        let check = ssh::SshManager::exec_command_checked(
            pool,
            server,
            db,
            &SqliteRemoteCommand::detect_sqlite().to_shell(),
            "detect remote sqlite3",
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

        ssh::SshManager::exec_command_checked(
            pool,
            server,
            db,
            install_command,
            "install remote sqlite3",
        )?;
        let recheck = ssh::SshManager::exec_command_checked(
            pool,
            server,
            db,
            &SqliteRemoteCommand::detect_sqlite().to_shell(),
            "verify remote sqlite3 installation",
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
        ssh::SshManager::exec_command_checked(pool, server, db, &command, "list SQLite tables")
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
        ssh::SshManager::exec_command_checked(
            pool,
            server,
            db,
            &command,
            &format!("read SQLite table info for {}", table_name),
        )
    }

    pub fn list_schema(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        sqlite_path: &str,
    ) -> Result<Vec<DatabaseTableSchema>> {
        let tables_output = Self::list_table_names(pool, server, db, sqlite_path)?;
        let table_rows = parse_sqlite_output("list schema tables", &tables_output)?.row_maps();
        let mut tables = Vec::new();
        for row in table_rows {
            let Some(name) = row.get("name").and_then(|value| value.as_deref()) else {
                continue;
            };
            let info_output = Self::table_info(pool, server, db, sqlite_path, name)?;
            let info_rows =
                parse_sqlite_output(&format!("read schema for table {}", name), &info_output)?
                    .row_maps();
            let columns = info_rows
                .into_iter()
                .filter_map(|info| {
                    let name = info.get("name")?.clone()?;
                    Some(DatabaseColumnSchema {
                        name,
                        db_type: info
                            .get("type")
                            .and_then(|value| value.as_deref())
                            .unwrap_or("TEXT")
                            .to_string(),
                        nullable: info
                            .get("notnull")
                            .and_then(|value| value.as_deref())
                            .and_then(|value| value.parse::<i64>().ok())
                            .unwrap_or(0)
                            == 0,
                        primary_key: info
                            .get("pk")
                            .and_then(|value| value.as_deref())
                            .and_then(|value| value.parse::<i64>().ok())
                            .unwrap_or(0)
                            != 0,
                        default_value: info.get("dflt_value").cloned().flatten(),
                        auto_generated: false,
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
        ssh::SshManager::exec_command_checked(pool, server, db, &command, "execute SQLite command")
    }

    pub fn execute_script(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        sqlite_path: &str,
        sql: &str,
    ) -> Result<String> {
        let command = SqliteRemoteCommand::script(sqlite_path, sql).to_shell();
        ssh::SshManager::exec_command_checked(pool, server, db, &command, "execute SQLite script")
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
            let parsed = parse_sqlite_output("parse SQLite write result", &output)?;
            let affected_rows = parsed
                .first_value("affected_rows")
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(0);
            return Ok(DatabaseQueryResult::empty_message(
                "Query executed",
                affected_rows,
                elapsed_ms,
            ));
        }

        let parsed = parse_sqlite_output("parse SQLite query result", &output)?;
        let columns = parsed.columns;
        let result_rows = parsed.rows;

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
        let output = ssh::SshManager::exec_command_checked(
            pool,
            server,
            db,
            &command,
            "detect package manager",
        )?;
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

#[derive(Debug, PartialEq)]
pub(crate) struct SqliteOutput {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Option<String>>>,
}

impl SqliteOutput {
    pub fn row_maps(&self) -> Vec<HashMap<String, Option<String>>> {
        self.rows
            .iter()
            .map(|row| {
                self.columns
                    .iter()
                    .cloned()
                    .zip(row.iter().cloned())
                    .collect::<HashMap<_, _>>()
            })
            .collect()
    }

    fn first_value(&self, column: &str) -> Option<&str> {
        let index = self.columns.iter().position(|name| name == column)?;
        self.rows
            .first()
            .and_then(|row| row.get(index))
            .and_then(|value| value.as_deref())
    }
}

pub(crate) fn parse_sqlite_output(context: &str, output: &str) -> Result<SqliteOutput> {
    let mut lines = output.lines();
    let Some(header) = lines.next() else {
        return Ok(SqliteOutput {
            columns: Vec::new(),
            rows: Vec::new(),
        });
    };
    if header.is_empty() {
        return Ok(SqliteOutput {
            columns: Vec::new(),
            rows: Vec::new(),
        });
    }

    let columns = header
        .split(SQLITE_COLUMN_SEPARATOR)
        .map(str::to_string)
        .collect::<Vec<_>>();
    let mut rows = Vec::new();

    for (index, line) in lines.enumerate() {
        let values = line
            .split(SQLITE_COLUMN_SEPARATOR)
            .map(|value| {
                if value == SQLITE_NULL_VALUE {
                    None
                } else {
                    Some(value.to_string())
                }
            })
            .collect::<Vec<_>>();
        if values.len() != columns.len() {
            return Err(anyhow!(
                "{}: malformed SQLite output row {}: expected {} columns, got {}",
                context,
                index + 1,
                columns.len(),
                values.len()
            ));
        }
        rows.push(values);
    }

    Ok(SqliteOutput { columns, rows })
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
    fn quotes_remote_sqlite_path_and_sql_for_shell_without_readonly_flag() {
        assert_eq!(
            shell_quote("/tmp/prod's db.sqlite"),
            "'/tmp/prod'\"'\"'s db.sqlite'"
        );
        let command = SqliteRemoteCommand::read("/tmp/prod's db.sqlite", "SELECT 'ok'").to_shell();
        assert!(!command.contains("-readonly"));
        assert!(!command.contains("-json"));
        assert!(command.contains("-header"));
        assert!(command.contains("-separator"));
        assert!(command.contains("'/tmp/prod'\"'\"'s db.sqlite'"));
    }

    #[test]
    fn builds_write_command_wrapped_in_transaction() {
        let command =
            SqliteRemoteCommand::write("/tmp/app.db", "UPDATE users SET name='a'").to_shell();
        assert!(!command.contains("-json"));
        assert!(command.contains("-header"));
        assert!(command.contains(
            "'BEGIN IMMEDIATE; UPDATE users SET name='\"'\"'a'\"'\"'; SELECT changes() AS affected_rows; COMMIT;'"
        ));
    }

    #[test]
    fn parses_legacy_sqlite_separator_output() {
        let output = format!(
            "id{name_sep}name{name_sep}missing\n1{name_sep}alice{name_sep}{null_value}\n",
            name_sep = SQLITE_COLUMN_SEPARATOR,
            null_value = SQLITE_NULL_VALUE
        );
        let parsed = parse_sqlite_output("query users", &output).expect("legacy output");

        assert_eq!(parsed.columns, vec!["id", "name", "missing"]);
        assert_eq!(
            parsed.rows,
            vec![vec![Some("1".into()), Some("alice".into()), None,]]
        );
    }

    #[test]
    fn malformed_legacy_sqlite_output_reports_context() {
        let output = format!("id{name_sep}name\n1\n", name_sep = SQLITE_COLUMN_SEPARATOR);
        let err = parse_sqlite_output("query users", &output).expect_err("malformed row");

        assert!(err.to_string().contains("query users"));
        assert!(err.to_string().contains("expected 2 columns"));
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
