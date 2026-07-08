use anyhow::{anyhow, Result};

use crate::database::models::DatabaseOperationResult;
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

    pub fn list_schema(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        sqlite_path: &str,
    ) -> Result<String> {
        let sql = "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name";
        let command = SqliteRemoteCommand::read(sqlite_path, sql).to_shell();
        ssh::SshManager::exec_command(pool, server, db, &command)
    }

    pub fn execute(
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
        assert!(result.message.contains(
            "Suggested command: sudo apt-get update && sudo apt-get install -y sqlite3"
        ));
    }
}
