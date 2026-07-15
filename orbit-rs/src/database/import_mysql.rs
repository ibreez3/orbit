use std::collections::HashSet;

use anyhow::{anyhow, Result};

use crate::database::models::{
    DatabaseBackupArtifact, DatabaseImportColumnMapping, DatabaseImportPlan,
    DatabaseImportTablePlan, DatabaseTableSchema,
};
use crate::database::sql::mysql_type_for_sqlite;

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

pub fn validate_mysql_import_sources(
    plan: &DatabaseImportPlan,
    artifact: &DatabaseBackupArtifact,
) -> Result<()> {
    for table_plan in &plan.tables {
        let source_table = artifact
            .tables
            .iter()
            .find(|table| table.name == table_plan.source_table)
            .ok_or_else(|| {
                anyhow!(
                    "source table {} not found in backup",
                    table_plan.source_table
                )
            })?;
        let source_columns = source_table
            .columns
            .iter()
            .map(|column| column.name.as_str())
            .collect::<HashSet<_>>();

        for mapping in &table_plan.columns {
            let target_column = mapping.target_column.as_deref().unwrap_or_default().trim();
            let source_column = mapping.source_column.trim();
            if target_column.is_empty() || source_column.is_empty() {
                continue;
            }
            if !source_columns.contains(source_column) {
                return Err(anyhow!(
                    "source table {} does not contain mapped source column {}",
                    table_plan.source_table,
                    source_column
                ));
            }
        }
    }

    Ok(())
}

pub fn prepare_new_table_import_plan(
    artifact: &DatabaseBackupArtifact,
    backup_path: &str,
    target_connection_id: &str,
) -> DatabaseImportPlan {
    DatabaseImportPlan {
        backup_path: backup_path.into(),
        target_connection_id: target_connection_id.into(),
        mode: "new_table".into(),
        tables: artifact
            .tables
            .iter()
            .map(|table| DatabaseImportTablePlan {
                source_table: table.name.clone(),
                target_table: table.name.clone(),
                columns: table
                    .columns
                    .iter()
                    .map(|column| DatabaseImportColumnMapping {
                        source_column: column.name.clone(),
                        target_column: Some(column.name.clone()),
                        target_type: mysql_type_for_sqlite(&column.db_type),
                        required_without_default: false,
                    })
                    .collect(),
            })
            .collect(),
    }
}

pub fn prepare_existing_table_import_plan(
    artifact: &DatabaseBackupArtifact,
    backup_path: &str,
    target_connection_id: &str,
    target_schema: &[DatabaseTableSchema],
) -> DatabaseImportPlan {
    DatabaseImportPlan {
        backup_path: backup_path.into(),
        target_connection_id: target_connection_id.into(),
        mode: "existing_table".into(),
        tables: artifact
            .tables
            .iter()
            .map(|source_table| {
                let target_table = target_schema
                    .iter()
                    .find(|table| table.name.eq_ignore_ascii_case(&source_table.name));
                let mut mappings = source_table
                    .columns
                    .iter()
                    .map(|source_column| {
                        let target_column = target_table
                            .and_then(|table| {
                                table
                                    .columns
                                    .iter()
                                    .find(|column| {
                                        column.name.eq_ignore_ascii_case(&source_column.name)
                                    })
                                    .map(|column| column.name.clone())
                            })
                            .or_else(|| Some(source_column.name.clone()));
                        DatabaseImportColumnMapping {
                            source_column: source_column.name.clone(),
                            target_column,
                            target_type: mysql_type_for_sqlite(&source_column.db_type),
                            required_without_default: false,
                        }
                    })
                    .collect::<Vec<_>>();

                if let Some(target_table) = target_table {
                    for target_column in &target_table.columns {
                        let mapped = mappings.iter().any(|mapping| {
                            mapping
                                .target_column
                                .as_deref()
                                .is_some_and(|name| name.eq_ignore_ascii_case(&target_column.name))
                        });
                        let required_without_default = !target_column.nullable
                            && target_column.default_value.is_none()
                            && !target_column.auto_generated;
                        if required_without_default && !mapped {
                            mappings.push(DatabaseImportColumnMapping {
                                source_column: String::new(),
                                target_column: Some(target_column.name.clone()),
                                target_type: target_column.db_type.clone(),
                                required_without_default: true,
                            });
                        }
                    }
                }

                DatabaseImportTablePlan {
                    source_table: source_table.name.clone(),
                    target_table: target_table
                        .map(|table| table.name.clone())
                        .unwrap_or_else(|| source_table.name.clone()),
                    columns: mappings,
                }
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::models::{
        DatabaseBackupArtifact, DatabaseImportColumnMapping, DatabaseImportTablePlan,
    };

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

    #[test]
    fn rejects_mapped_source_column_missing_from_backup_table() {
        let artifact = DatabaseBackupArtifact::single_table_for_test(
            "source_table",
            vec![("id", "INTEGER")],
            vec![vec![("id", Some("1"))]],
        );
        let plan = DatabaseImportPlan::single_table_for_test(
            "source_table",
            "target_table",
            vec![("missing_column", "name")],
        );

        let err =
            validate_mysql_import_sources(&plan, &artifact).expect_err("invalid source mapping");
        assert!(err.to_string().contains("source_table"));
        assert!(err.to_string().contains("missing_column"));
    }

    #[test]
    fn existing_table_plan_includes_unmatched_source_tables() {
        let artifact = DatabaseBackupArtifact::single_table_for_test(
            "legacy_users",
            vec![("id", "INTEGER"), ("system", "TEXT")],
            vec![vec![("id", Some("1")), ("system", Some("prod"))]],
        );
        let plan =
            prepare_existing_table_import_plan(&artifact, "/tmp/source.json", "mysql-1", &[]);

        assert_eq!(plan.tables.len(), 1);
        assert_eq!(plan.tables[0].source_table, "legacy_users");
        assert_eq!(plan.tables[0].target_table, "legacy_users");
        assert_eq!(
            plan.tables[0].columns[0].target_column.as_deref(),
            Some("id")
        );
    }
}
