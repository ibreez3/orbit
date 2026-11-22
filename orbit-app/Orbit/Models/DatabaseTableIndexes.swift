import Foundation

struct DatabaseIndex: Identifiable {
    let name: String
    let kind: String
    let definition: String
    let protected: Bool

    var id: String { name }
}

extension DatabaseTableQuery {
    var indexListSQL: String {
        let tableName = literal(table.name)
        switch engine {
        case "mysql":
            return "SHOW INDEX FROM " + source
        case "postgres":
            return """
            SELECT i.relname::text, CASE WHEN x.indisprimary THEN '主键' WHEN x.indisunique THEN '唯一' ELSE am.amname::text END,
                   pg_get_indexdef(i.oid), CASE WHEN i.relispartition OR EXISTS
                   (SELECT 1 FROM pg_constraint c WHERE c.conindid=i.oid AND c.conrelid=t.oid AND c.contype IN ('p','u','x')) THEN '1' ELSE '0' END
            FROM pg_index x JOIN pg_class i ON i.oid=x.indexrelid JOIN pg_class t ON t.oid=x.indrelid
            JOIN pg_namespace n ON n.oid=t.relnamespace JOIN pg_am am ON am.oid=i.relam
            WHERE t.relname=\(tableName) AND n.nspname=\(literal(table.namespace ?? "public")) ORDER BY i.relname
            """
        default:
            return """
            SELECT l.name, CASE WHEN l.origin='pk' THEN '主键' WHEN l."unique"=1 THEN '唯一' ELSE '普通' END,
                   COALESCE(replace(replace(s.sql,char(10),' '),char(13),' '),
                   (SELECT group_concat(name, ', ') FROM (SELECT name FROM pragma_index_info(l.name) ORDER BY seqno))),
                   CASE WHEN l.origin='c' THEN '0' ELSE '1' END
            FROM pragma_index_list(\(tableName)) l LEFT JOIN sqlite_master s ON s.type='index' AND s.name=l.name ORDER BY l.name
            """
        }
    }

    func indexes(_ result: DatabaseQueryResult) -> [DatabaseIndex] {
        if engine != "mysql" {
            return result.rows.compactMap { row in
                guard row.count == 4, let name = row[0] else { return nil }
                return DatabaseIndex(name: name, kind: row[1] ?? "", definition: row[2] ?? "", protected: row[3] == "1")
            }
        }
        let positions = result.columns.map { $0.lowercased() }
        func field(_ row: [String?], _ key: String) -> String? {
            guard let i = positions.firstIndex(of: key), i < row.count else { return nil }
            return row[i]
        }
        return Dictionary(grouping: result.rows) { field($0, "key_name") ?? "" }.sorted { $0.key < $1.key }.map { name, rows in
            let parts = rows.sorted { (Int(field($0, "seq_in_index") ?? "") ?? 0) < (Int(field($1, "seq_in_index") ?? "") ?? 0) }
            let definition = parts.map { row in
                (field(row, "column_name") ?? field(row, "expression") ?? "")
                    + (field(row, "sub_part").map { "(\($0))" } ?? "")
                    + (field(row, "collation") == "D" ? " DESC" : "")
            }.joined(separator: ", ")
            let kind = name == "PRIMARY" ? "主键" : field(parts[0], "non_unique") == "0" ? "唯一" : field(parts[0], "index_type") ?? "普通"
            return DatabaseIndex(name: name, kind: kind, definition: definition, protected: name == "PRIMARY")
        }
    }

    func createIndex(_ name: String, fields: [String], unique: Bool) -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.contains("\0"),
              !fields.isEmpty, Set(fields).count == fields.count, fields.allSatisfy(columns.map(\.name).contains) else { return nil }
        let target = engine == "remote_sqlite" ? ident(table.name) : source
        return "CREATE " + (unique ? "UNIQUE " : "") + "INDEX " + ident(name) + " ON " + target + " (" + fields.map(ident).joined(separator: ", ") + ")"
    }

    func dropIndex(_ index: DatabaseIndex) -> String? {
        guard !index.protected else { return nil }
        if engine == "mysql" { return "DROP INDEX " + ident(index.name) + " ON " + source }
        return "DROP INDEX " + (engine == "postgres" ? ident(table.namespace ?? "public") : "main") + "." + ident(index.name)
    }
}
