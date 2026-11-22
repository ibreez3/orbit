use super::backup::{quote_ident, sql_literal};
use super::models::DatabaseConnection;
use super::mysql::MysqlEngine;
use super::sqlite_remote::shell_quote;
use super::{with_driver_connection, Database};
use crate::transport;
use anyhow::{anyhow, bail, ensure, Context, Result};
use std::fs::{File, OpenOptions};
use std::io::{self, BufWriter, Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};

pub fn export(
    db: &Database,
    c: &DatabaseConnection,
    namespace: &str,
    table: &str,
    data: bool,
    path: &Path,
) -> Result<()> {
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(path)?;
    let result = match c.engine.as_str() {
        "remote_sqlite" => sqlite(db, c, table, data, file),
        "mysql" => with_driver_connection(db, c, |conn| {
            MysqlEngine::export_table(conn, table, data, file)
        }),
        "postgres" => {
            with_driver_connection(db, c, |conn| postgres(conn, namespace, table, data, file))
        }
        _ => Err(anyhow!("不支持此数据库类型")),
    };
    if result.is_err() {
        let _ = std::fs::remove_file(path);
    }
    result
}

fn postgres(
    c: &DatabaseConnection,
    namespace: &str,
    table: &str,
    data: bool,
    file: File,
) -> Result<()> {
    let tool = [
        "/opt/homebrew/bin/pg_dump",
        "/usr/local/bin/pg_dump",
        "/opt/homebrew/opt/libpq/bin/pg_dump",
        "/usr/local/opt/libpq/bin/pg_dump",
    ]
    .into_iter()
    .find(|p| Path::new(p).is_file())
    .unwrap_or("pg_dump");
    let pattern = format!(
        "{}.{}",
        quote_ident(namespace, "postgres"),
        quote_ident(table, "postgres")
    );
    let mut cmd = Command::new(tool);
    cmd.args([
        "--format=plain",
        "--strict-names",
        "--no-owner",
        "--no-acl",
        "--no-password",
        "--table-and-children",
        &pattern,
    ])
    .env("PGHOST", &c.host)
    .env("PGPORT", c.port.to_string())
    .env("PGUSER", &c.username)
    .env("PGDATABASE", &c.database_name)
    .env("PGPASSWORD", &c.password);
    if !data {
        cmd.arg("--schema-only");
    }
    let output =
        cmd.stdout(file).stderr(Stdio::piped()).output().context(
            "无法运行 pg_dump，请安装 PostgreSQL 16 或更新版本的客户端，且版本不低于服务器",
        )?;
    ensure!(
        output.status.success(),
        "pg_dump: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(())
}

fn sqlite(
    db: &Database,
    c: &DatabaseConnection,
    table: &str,
    data: bool,
    file: File,
) -> Result<()> {
    let server = db.get_server(&c.ssh_server_id)?;
    let guard = transport::create_session(&server, db)?;
    let cmd = |sql: &str| {
        format!(
            "sqlite3 -readonly -batch -bail -noheader {} {}",
            shell_quote(&c.sqlite_path),
            shell_quote(sql)
        )
    };
    let name = sql_literal(Some(table));
    let mut meta = guard.session.channel_session()?;
    meta.exec(&cmd(&format!("BEGIN; SELECT json_array(schema_version,(SELECT encoding FROM pragma_encoding),EXISTS(SELECT 1 FROM sqlite_master WHERE name='sqlite_sequence')) FROM pragma_schema_version; SELECT json_quote(name) FROM pragma_table_xinfo({name}) WHERE hidden=0 ORDER BY cid; COMMIT;")))?;
    let mut text = String::new();
    meta.read_to_string(&mut text)?;
    meta.wait_close()?;
    ensure!(meta.exit_status()? == 0, "读取 SQLite 字段失败");
    let mut lines = text.lines();
    let (version, encoding, sequences): (i64, String, i64) =
        serde_json::from_str(lines.next().context("无法读取 SQLite 结构版本")?)?;
    let mut columns = Vec::new();
    for line in lines {
        columns.push(serde_json::from_str::<String>(line)?);
    }
    ensure!(!columns.is_empty(), "找不到可导出的表字段");
    let script = sqlite_script(table, &columns, data, version, &encoding, sequences != 0);
    let mut channel = guard.session.channel_session()?;
    channel.handle_extended_data(ssh2::ExtendedData::Merge)?;
    channel.exec(&cmd(&script))?;
    let mut writer = BufWriter::new(file);
    io::copy(&mut channel, &mut writer)?;
    channel.wait_close()?;
    if channel.exit_status()? != 0 {
        bail!("SQLite 导出失败，请刷新表结构并确认该对象是普通表");
    }
    writer.flush()?;
    Ok(())
}

fn sqlite_script(
    table: &str,
    columns: &[String],
    data: bool,
    version: i64,
    encoding: &str,
    sequences: bool,
) -> String {
    let name = sql_literal(Some(table));
    let ident = quote_ident(table, "sqlite");
    let cols: Vec<_> = columns.iter().map(|s| quote_ident(s, "sqlite")).collect();
    let encoding_pragma = sql_literal(Some(&format!(
        "PRAGMA encoding={};",
        sql_literal(Some(encoding))
    )));
    let mut sql = format!("BEGIN;
        SELECT '' WHERE abs(CASE WHEN (SELECT schema_version FROM pragma_schema_version)={version}
        AND EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name={name} AND upper(sql) NOT LIKE 'CREATE VIRTUAL TABLE%')
        THEN 0 ELSE -9223372036854775808 END)<0;
        SELECT {encoding_pragma}; SELECT 'BEGIN;';
        SELECT sql || ';' FROM sqlite_master WHERE type='table' AND name={name};");
    if data {
        let prefix = sql_literal(Some(&format!(
            "INSERT INTO {ident} ({}) VALUES (",
            cols.join(", ")
        )));
        let values = cols.iter().map(|col| format!("CASE typeof({col}) WHEN 'text' THEN CASE WHEN instr({col},char(0))=0 THEN quote({col}) ELSE 'CAST(X''' || hex({col}) || ''' AS TEXT)' END WHEN 'real' THEN CASE WHEN abs({col})>1.7976931348623157e308 THEN CASE WHEN {col}<0 THEN '-1e999' ELSE '1e999' END ELSE printf('%!.26g', {col}) END ELSE quote({col}) END")).collect::<Vec<_>>().join(" || ',' || ");
        sql.push_str(&format!(
            " SELECT {prefix} || {values} || ');' FROM {ident};"
        ));
        if sequences {
            let delete = sql_literal(Some(&format!(
                "DELETE FROM sqlite_sequence WHERE name={name};"
            )));
            let prefix = sql_literal(Some(&format!(
                "INSERT INTO sqlite_sequence(name,seq) VALUES({name},"
            )));
            sql.push_str(&format!(" SELECT {delete} FROM sqlite_sequence WHERE name={name}; SELECT {prefix} || seq || ');' FROM sqlite_sequence WHERE name={name};"));
        }
    }
    sql.push_str(&format!(" SELECT sql || ';' FROM sqlite_master WHERE tbl_name={name} AND type IN ('index','trigger') AND sql IS NOT NULL ORDER BY type,name; SELECT 'COMMIT;'; COMMIT;"));
    sql
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    #[test]
    fn sqlite_export_replays_structure_indexes_and_optional_rows() -> Result<()> {
        let dir = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        std::fs::create_dir(&dir)?;
        let source = dir.join("source.db");
        let db = rusqlite::Connection::open(&source)?;
        db.execute_batch("CREATE TABLE event_log(id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT DEFAULT 'x', raw BLOB, ts DATETIME, derived AS (length(note)));
            CREATE UNIQUE INDEX ix_event ON event_log(note DESC,id) WHERE ts IS NULL;
            INSERT INTO event_log(note,raw,ts) VALUES('one'||char(0)||'two',X'FF00',NULL);
            UPDATE sqlite_sequence SET seq=100 WHERE name='event_log';
            CREATE TABLE eventXlog(id);")?;
        let version = db.query_row("PRAGMA schema_version", [], |r| r.get(0))?;
        let fields = ["id", "note", "raw", "ts"].map(String::from);
        for include in [false, true] {
            let sql = sqlite_script("event_log", &fields, include, version, "UTF-8", true);
            let dump = Command::new("sqlite3")
                .arg("-bail")
                .arg(&source)
                .arg(sql)
                .output()?;
            ensure!(
                dump.status.success(),
                "{}",
                String::from_utf8_lossy(&dump.stderr)
            );
            let copy = rusqlite::Connection::open_in_memory()?;
            copy.execute_batch(std::str::from_utf8(&dump.stdout)?)?;
            let count: i64 = copy.query_row("SELECT count(*) FROM event_log", [], |r| r.get(0))?;
            assert_eq!(count, i64::from(include));
            let objects: i64 = copy.query_row(
                "SELECT count(*) FROM sqlite_master WHERE name IN ('ix_event','event_log')",
                [],
                |r| r.get(0),
            )?;
            assert_eq!(objects, 2);
            if include {
                let correct: bool = copy.query_row("SELECT note='one'||char(0)||'two' AND raw=X'FF00' AND ts IS NULL AND (SELECT seq FROM sqlite_sequence)=100 FROM event_log", [], |r|r.get(0))?;
                assert!(correct);
            }
        }
        drop(db);
        std::fs::remove_dir_all(dir)?;
        Ok(())
    }
}
