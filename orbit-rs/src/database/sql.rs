pub fn is_write_statement(sql: &str) -> bool {
    let token = first_sql_token(sql);
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

#[cfg(test)]
mod tests {
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
