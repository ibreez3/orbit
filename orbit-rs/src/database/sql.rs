pub fn is_write_statement(sql: &str) -> bool {
    let token = first_sql_token(sql);
    if token.as_deref() == Some("with") {
        return with_contains_write(sql);
    }
    matches!(
        token.as_deref(),
        Some("insert")
            | Some("update")
            | Some("delete")
            | Some("drop")
            | Some("alter")
            | Some("create")
            | Some("replace")
            | Some("truncate")
            | Some("vacuum")
            | Some("attach")
            | Some("detach")
            | Some("pragma")
    )
}

pub fn allows_read_query(sql: &str, engine: &str) -> bool {
    let token = first_sql_token(sql);
    let allowed = matches!(token.as_deref(), Some("select" | "with" | "explain" | "values"))
        || (engine == "mysql" && matches!(token.as_deref(), Some("show" | "describe" | "desc")));
    if !allowed || is_write_statement(sql) {
        return false;
    }
    if engine == "mysql" && (sql.contains("/*!") || sql.contains("/*M!")) {
        return false;
    }
    if engine == "remote_sqlite" {
        for (index, _) in sql.match_indices(';') {
            if !sql[index + 1..].trim().is_empty() {
                let Ok(prefix) = std::ffi::CString::new(&sql[..=index]) else { return false };
                if unsafe { rusqlite::ffi::sqlite3_complete(prefix.as_ptr()) } != 0 {
                    return false;
                }
            }
        }
    }
    true
}

pub fn allows_agent_query(sql: &str, engine: &str) -> bool {
    matches!(first_sql_token(sql).as_deref(), Some("select" | "with"))
        && allows_read_query(sql, engine)
        && !(engine == "mysql" && sql.split(|c: char| !c.is_alphanumeric() && c != '_')
            .any(|word| word.eq_ignore_ascii_case("outfile") || word.eq_ignore_ascii_case("dumpfile")))
        && !(engine == "mysql" && sql.contains("/*+"))
}

pub fn mysql_type_for_sqlite(sqlite_type: &str) -> String {
    let normalized = sqlite_type.trim().to_uppercase();

    match normalized.as_str() {
        "INTEGER" => "BIGINT",
        "REAL" => "DOUBLE",
        "TEXT" => "TEXT",
        "BLOB" => "BLOB",
        "NUMERIC" => "DECIMAL(38,10)",
        _ => "TEXT",
    }
    .to_string()
}

fn first_sql_token(sql: &str) -> Option<String> {
    let mut rest = sql.trim_start();

    loop {
        if let Some(after_comment) = rest.strip_prefix("--") {
            rest = after_comment
                .split_once('\n')
                .map(|(_, after)| after)
                .unwrap_or_default()
                .trim_start();
            continue;
        }

        if let Some(after_open) = rest.strip_prefix("/*") {
            rest = after_open
                .split_once("*/")
                .map(|(_, after)| after)
                .unwrap_or_default()
                .trim_start();
            continue;
        }

        break;
    }

    let token: String = rest
        .chars()
        .take_while(|ch| ch.is_ascii_alphabetic() || *ch == '_')
        .collect();

    if token.is_empty() {
        None
    } else {
        Some(token.to_ascii_lowercase())
    }
}

fn with_contains_write(sql: &str) -> bool {
    let normalized = sql_without_comments_or_string_literals(sql);
    let mut chars = normalized.chars().peekable();
    let mut depth = 0usize;
    let mut previous_significant = '\0';

    while let Some(ch) = chars.next() {
        if ch == '(' {
            depth += 1;
            previous_significant = ch;
            continue;
        }
        if ch == ')' {
            depth = depth.saturating_sub(1);
            previous_significant = ch;
            continue;
        }
        if ch.is_whitespace() || !ch.is_ascii_alphabetic() {
            if !ch.is_whitespace() {
                previous_significant = ch;
            }
            continue;
        }

        let mut token = String::new();
        token.push(ch);
        while let Some(next) = chars.peek() {
            if next.is_ascii_alphabetic() || *next == '_' {
                token.push(*next);
                chars.next();
            } else {
                break;
            }
        }

        if is_write_token(&token) && (depth == 0 || previous_significant == '(') {
            return true;
        }
        previous_significant = token.chars().last().unwrap_or(previous_significant);
    }
    false
}

fn is_write_token(token: &str) -> bool {
    matches!(
        token,
        "insert"
            | "update"
            | "delete"
            | "drop"
            | "alter"
            | "create"
            | "replace"
            | "truncate"
            | "vacuum"
            | "attach"
            | "detach"
            | "pragma"
    )
}

fn sql_without_comments_or_string_literals(sql: &str) -> String {
    let mut result = String::with_capacity(sql.len());
    let mut chars = sql.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '-' && chars.peek() == Some(&'-') {
            chars.next();
            for next in chars.by_ref() {
                if next == '\n' {
                    result.push(' ');
                    break;
                }
            }
            continue;
        }
        if ch == '/' && chars.peek() == Some(&'*') {
            chars.next();
            let mut previous = '\0';
            for next in chars.by_ref() {
                if previous == '*' && next == '/' {
                    result.push(' ');
                    break;
                }
                previous = next;
            }
            continue;
        }
        if ch == '\'' {
            result.push(' ');
            while let Some(next) = chars.next() {
                if next == '\'' {
                    if chars.peek() == Some(&'\'') {
                        chars.next();
                    } else {
                        break;
                    }
                }
            }
            continue;
        }
        result.push(ch.to_ascii_lowercase());
    }
    result
}

#[cfg(test)]
mod tests {
    #[test]
    fn agent_queries_only_admit_read_shapes() {
        for engine in ["mysql", "postgres", "remote_sqlite"] {
            for sql in ["SELECT 1", "WITH t AS (SELECT 1) SELECT * FROM t"] {
                assert!(super::allows_agent_query(sql, engine));
            }
            for sql in ["UPDATE t SET n=1", "WITH t AS (DELETE FROM x RETURNING *) SELECT * FROM t",
                        "EXPLAIN ANALYZE DELETE FROM t", "PRAGMA query_only=OFF"] {
                assert!(!super::allows_agent_query(sql, engine));
            }
        }
        assert!(!super::allows_agent_query("SELECT 1; SELECT 2", "remote_sqlite"));
        assert!(!super::allows_agent_query("SELECT 1 INTO OUTFILE 'x'", "mysql"));
    }

    use super::*;

    #[test]
    fn detects_write_statements_with_leading_comments() {
        assert!(is_write_statement(
            "  -- change row\nUPDATE users SET name='a'"
        ));
        assert!(is_write_statement("/* ddl */ CREATE TABLE t(id INTEGER)"));
        assert!(!is_write_statement(
            "WITH recent AS (SELECT 1) SELECT * FROM recent"
        ));
        assert!(!is_write_statement("SELECT * FROM users LIMIT 10"));
    }

    #[test]
    fn detects_data_modifying_ctes_as_writes() {
        assert!(is_write_statement(
            "WITH updated AS (UPDATE users SET name = 'a' RETURNING id) SELECT * FROM updated"
        ));
        assert!(is_write_statement(
            "WITH removed AS (DELETE FROM users WHERE id = 1 RETURNING id) SELECT * FROM removed"
        ));
        assert!(is_write_statement(
            "WITH inserted AS (INSERT INTO users(name) VALUES ('a') RETURNING id) SELECT * FROM inserted"
        ));
        assert!(is_write_statement(
            "WITH made AS (CREATE TABLE scratch(id INTEGER) RETURNING id) SELECT * FROM made"
        ));
        assert!(!is_write_statement(
            "WITH recent AS (SELECT * FROM update_log) SELECT * FROM recent"
        ));
    }

    #[test]
    fn detects_write_main_statement_after_read_only_cte() {
        assert!(is_write_statement(
            "WITH recent AS (SELECT 1) DELETE FROM users WHERE id = 1"
        ));
        assert!(is_write_statement(
            "WITH recent AS (SELECT 1) UPDATE users SET name = 'a'"
        ));
        assert!(is_write_statement(
            "WITH recent AS (SELECT 1) INSERT INTO users(name) VALUES ('a')"
        ));
        assert!(!is_write_statement(
            "WITH recent AS (SELECT 1), logs AS (SELECT * FROM update_log) SELECT * FROM recent"
        ));
    }

    #[test]
    fn query_policy_accepts_one_read_and_preserves_quoted_semicolons() {
        assert!(allows_read_query("SELECT 'a;b';", "remote_sqlite"));
        assert!(!allows_read_query("SELECT 1; SELECT 2", "remote_sqlite"));
        for engine in ["remote_sqlite", "mysql", "postgres"] {
            assert!(!allows_read_query("BEGIN", engine));
            assert!(!allows_read_query("DELETE FROM users", engine));
            assert!(allows_read_query("WITH t AS (SELECT 1) SELECT * FROM t", engine));
        }
    }

    #[test]
    fn maps_sqlite_types_to_mysql_defaults() {
        assert_eq!(mysql_type_for_sqlite("INTEGER"), "BIGINT");
        assert_eq!(mysql_type_for_sqlite("REAL"), "DOUBLE");
        assert_eq!(mysql_type_for_sqlite("TEXT"), "TEXT");
        assert_eq!(mysql_type_for_sqlite("BLOB"), "BLOB");
        assert_eq!(mysql_type_for_sqlite("NUMERIC"), "DECIMAL(38,10)");
        assert_eq!(mysql_type_for_sqlite("INT"), "TEXT");
        assert_eq!(mysql_type_for_sqlite("BOOLEAN"), "TEXT");
        assert_eq!(mysql_type_for_sqlite("DATE"), "TEXT");
        assert_eq!(mysql_type_for_sqlite("DATETIME"), "TEXT");
        assert_eq!(mysql_type_for_sqlite("VARCHAR(255)"), "TEXT");
        assert_eq!(mysql_type_for_sqlite("custom_type"), "TEXT");
    }
}
