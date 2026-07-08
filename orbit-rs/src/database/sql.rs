pub fn is_write_statement(sql: &str) -> bool {
    let token = first_sql_token(sql);
    if token.as_deref() == Some("with") {
        return with_contains_data_modifying_cte(sql);
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

fn with_contains_data_modifying_cte(sql: &str) -> bool {
    let normalized = sql_without_comments_or_string_literals(sql);
    let mut chars = normalized.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '(' {
            continue;
        }
        while chars.peek().is_some_and(|next| next.is_whitespace()) {
            chars.next();
        }
        let token: String = chars
            .by_ref()
            .take_while(|next| next.is_ascii_alphabetic() || *next == '_')
            .collect();
        if matches!(
            token.as_str(),
            "insert" | "update" | "delete" | "create" | "replace"
        ) {
            return true;
        }
    }
    false
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
