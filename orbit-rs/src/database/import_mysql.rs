use std::collections::HashSet;

use anyhow::{anyhow, Result};

use crate::database::models::DatabaseImportPlan;

pub fn validate_mysql_import_plan(plan: &DatabaseImportPlan) -> Result<()> {
    if plan.backup_path.trim().is_empty() {
        return Err(anyhow!("backup path is required"));
    }
    if plan.target_connection_id.trim().is_empty() {
        return Err(anyhow!("target MySQL connection is required"));
    }
    if plan.tables.is_empty() {
        return Err(anyhow!("import plan must include at least one table"));
    }

    let existing_table_mode = matches!(
        plan.mode.as_str(),
        "existing_table" | "existing" | "append_existing"
    );

    for table in &plan.tables {
        if table.source_table.trim().is_empty() {
            return Err(anyhow!("source table is required"));
        }
        if table.target_table.trim().is_empty() {
            return Err(anyhow!(
                "target table is required for {}",
                table.source_table
            ));
        }

        let mut target_columns = HashSet::new();
        for column in &table.columns {
            let target_column = column.target_column.as_deref().unwrap_or_default().trim();
            let source_column = column.source_column.trim();

            if existing_table_mode
                && column.required_without_default
                && (source_column.is_empty() || target_column.is_empty())
            {
                let field_name = if target_column.is_empty() {
                    source_column
                } else {
                    target_column
                };
                return Err(anyhow!(
                    "target table {} requires field {} without a default value",
                    table.target_table,
                    field_name
                ));
            }

            if target_column.is_empty() {
                continue;
            }

            if !target_columns.insert(target_column.to_ascii_lowercase()) {
                return Err(anyhow!(
                    "target table {} maps target column {} more than once",
                    table.target_table,
                    target_column
                ));
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::models::{DatabaseImportColumnMapping, DatabaseImportTablePlan};

    #[test]
    fn accepts_field_rename_mapping_from_system_to_system1() {
        let plan = DatabaseImportPlan::single_table_for_test(
            "source_table",
            "target_table",
            vec![("id", "id"), ("system", "system1")],
        );

        validate_mysql_import_plan(&plan).expect("valid mapping");
    }

    #[test]
    fn rejects_required_existing_target_field_without_source_mapping() {
        let mut plan = DatabaseImportPlan::single_table_for_test(
            "source_table",
            "target_table",
            vec![("id", "id")],
        );
        plan.mode = "existing_table".into();
        plan.tables[0].columns.push(DatabaseImportColumnMapping {
            source_column: String::new(),
            target_column: Some("created_at".into()),
            target_type: "DATETIME".into(),
            required_without_default: true,
        });

        let err = validate_mysql_import_plan(&plan).expect_err("invalid mapping");
        assert!(err.to_string().contains("created_at"));
        assert!(err.to_string().contains("target_table"));
    }

    #[test]
    fn accepts_unmapped_source_fields_as_skipped_columns() {
        let plan = DatabaseImportPlan {
            backup_path: "/tmp/source.orbit-db-backup.json".into(),
            target_connection_id: "target-mysql".into(),
            mode: "existing_table".into(),
            tables: vec![DatabaseImportTablePlan {
                source_table: "source_table".into(),
                target_table: "target_table".into(),
                columns: vec![
                    DatabaseImportColumnMapping {
                        source_column: "id".into(),
                        target_column: Some("id".into()),
                        target_type: "BIGINT".into(),
                        required_without_default: false,
                    },
                    DatabaseImportColumnMapping {
                        source_column: "legacy_only".into(),
                        target_column: None,
                        target_type: "TEXT".into(),
                        required_without_default: false,
                    },
                ],
            }],
        };

        validate_mysql_import_plan(&plan).expect("skipped source field");
    }
}
