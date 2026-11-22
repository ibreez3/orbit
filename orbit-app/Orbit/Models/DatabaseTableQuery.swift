import Foundation

struct DatabaseTableQuery {
    static let pageSize = 500

    let engine: String
    let table: DatabaseTableSchema

    func ident(_ name: String) -> String {
        DatabaseQueryPolicy.quoteIdentifier(name, engine: engine)
    }

    var source: String {
        switch engine {
        case "postgres": return DatabaseTableSchema.qualified(table.namespace ?? "public", table.name)
        case "remote_sqlite": return "main." + ident(table.name)
        default: return ident(table.name)
        }
    }

    let keys: [Int]
    let columns: [DatabaseColumnSchema]

    init(engine: String, table: DatabaseTableSchema) {
        self.engine = engine
        self.table = table
        columns = table.columns
        keys = table.columns.indices.filter { table.columns[$0].primary_key }
    }

    private func projection(_ column: DatabaseColumnSchema) -> String {
        let name = ident(column.name)
        switch engine {
        case "postgres": return "CAST(\(name) AS text)"
        case "remote_sqlite": return "typeof(\(name)) || ':' || hex(CASE WHEN typeof(\(name)) = 'real' THEN printf('%!.26g', \(name)) ELSE \(name) END)"
        default:
            if isBinary(column) { return "HEX(\(name))" }
            return "CAST(\(name) AS CHAR CHARACTER SET utf8mb4)"
        }
    }

    private func isBinary(_ column: DatabaseColumnSchema) -> Bool {
        let type = column.db_type.lowercased()
        return ["blob", "binary", "bytea", "bit(", "geometry"].contains { type.contains($0) }
    }

    enum FilterMode { case exact, contains }

    struct Filter: Equatable {
        let column: Int
        let text: String
        var mode: FilterMode = .contains
    }

    private func matching(_ filter: Filter?) -> String? {
        guard let filter, columns.indices.contains(filter.column) else { return nil }
        let field = columns[filter.column]
        let column = ident(field.name)
        let needle = literal(filter.text)
        if filter.mode == .exact {
            if engine == "mysql" {
                guard let rhs = mysqlOperand(filter.text, field) else { return "1 = 0" }
                return "\(column) = \(rhs)"
            }
            if engine == "postgres", field.db_type == "json" { return "CAST(\(column) AS text) = \(needle)" }
            return engine == "remote_sqlite" ? "\(column) = +\(needle)" : "\(column) = \(needle)"
        }
        if engine == "postgres" { return "strpos(CAST(\(column) AS text), \(needle)) > 0" }
        return "instr(\(column), \(needle)) > 0"
    }

    private func orderFields(_ sorting: Int?, _ descending: Bool) -> [(index: Int, desc: Bool)] {
        var fields = keys.map { (index: $0, desc: false) }
        if let sorting, columns.indices.contains(sorting) {
            fields.removeAll { $0.index == sorting }
            fields.insert((sorting, descending), at: 0)
        }
        return fields
    }

    private func selectPage(filter: Filter?, sorting: Int?, descending: Bool, backwards: Bool,
                            ranges: [String] = [], limit: Int, offset: Int = 0) -> String {
        let fields = columns.enumerated().map { "\(projection($0.element)) AS \(ident("c\($0.offset)"))" }
        var order = orderFields(sorting, descending).map { field in
            source + "." + ident(columns[field.index].name) + (field.desc != backwards ? " DESC" : " ASC")
        }
        if keys.isEmpty {
            order += columns.map { projection($0) + (backwards ? " DESC" : " ASC") }
        }
        let orderSQL = order.joined(separator: ", ")
        func branch(_ projection: [String], _ range: String?) -> String {
            let conditions = [matching(filter), range].compactMap { $0 }
            let predicate = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
            return "SELECT \(projection.joined(separator: ", ")) FROM \(source)\(predicate) ORDER BY \(orderSQL) LIMIT \(limit)"
        }
        if ranges.count <= 1 {
            return branch(fields, ranges.first) + (offset == 0 ? "" : " OFFSET \(offset)")
        }
        let sortFields = orderFields(sorting, descending)
        let sortValues = sortFields.map { ident(columns[$0.index].name) + " AS " + ident("k\($0.index)") }
        let legs = ranges.map { "SELECT * FROM (" + branch(fields + sortValues, $0) + ") AS leg" }
        let aliases = columns.indices.map { ident("c\($0)") }.joined(separator: ", ")
        let mergeOrder = sortFields.map { ident("k\($0.index)") + ($0.desc != backwards ? " DESC" : " ASC") }
        return "SELECT \(aliases) FROM (\(legs.joined(separator: " UNION ALL "))) AS candidates ORDER BY \(mergeOrder.joined(separator: ", ")) LIMIT \(limit)"
    }

    func page(_ index: Int, filter: Filter? = nil, sorting: Int? = nil, descending: Bool = false) -> String {
        selectPage(filter: filter, sorting: sorting, descending: descending, backwards: false,
                   limit: Self.pageSize + 1, offset: index * Self.pageSize)
    }

    func tailPage(count: Int, filter: Filter?, sorting: Int?, descending: Bool) -> String {
        selectPage(filter: filter, sorting: sorting, descending: descending, backwards: true,
                   limit: count == 0 ? 0 : (count - 1) % Self.pageSize + 1)
    }

    func adjacentPage(from row: [String?], backwards: Bool, filter: Filter? = nil,
                      sorting: Int? = nil, descending: Bool = false, includingBoundary: Bool = false) -> String? {
        guard !keys.isEmpty, row.count == columns.count,
              keys.allSatisfy({ value(row[$0]) != nil }) else { return nil }
        var terms: [String] = []
        var equal: [String] = []
        for field in orderFields(sorting, descending) {
            let column = columns[field.index]
            let name = ident(column.name)
            let asc = field.desc == backwards
            let nullsFirst = engine == "postgres" ? !asc : asc
            var beyond: [String] = []
            let same: String
            if let raw = row[field.index], !(engine == "remote_sqlite" && raw == "null:") {
                guard let rhs = operand(raw, column) else { return nil }
                if engine == "mysql", ["enum(", "set("].contains(where: { column.db_type.lowercased().hasPrefix($0) }) { return nil }
                let cmp = name + (asc ? " > " : " < ") + rhs
                beyond.append(cmp)
                if !nullsFirst && column.nullable { beyond.append("\(name) IS NULL") }
                same = "\(name) = \(rhs)"
            } else {
                if nullsFirst { beyond.append("\(name) IS NOT NULL") }
                same = "\(name) IS NULL"
            }
            terms += beyond.map { (equal + [$0]).joined(separator: " AND ") }
            equal.append(same)
        }
        if includingBoundary { terms.append(equal.joined(separator: " AND ")) }
        guard !terms.isEmpty else { return nil }
        return selectPage(filter: filter, sorting: sorting, descending: descending, backwards: backwards,
                          ranges: terms, limit: Self.pageSize + 1)
    }

    var selectSummary: String { "SELECT … FROM " + source }

    func count(_ filter: Filter?) -> String {
        "SELECT COUNT(*) FROM " + source + (matching(filter).map { " WHERE " + $0 } ?? "")
    }

    func value(_ raw: String?) -> String? {
        guard engine == "remote_sqlite", let raw else { return raw }
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] != "null" else { return nil }
        let hex = parts[1]
        if parts[0] == "blob" { return "0x" + hex }
        var bytes = [UInt8]()
        var start = hex.startIndex
        while start < hex.endIndex {
            let end = hex.index(start, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[start..<end], radix: 16) else { return raw }
            bytes.append(byte)
            start = end
        }
        return String(bytes: bytes, encoding: .utf8) ?? "0x" + hex
    }

    func canEdit(_ index: Int, row: [String?]) -> Bool {
        let fields = columns
        guard fields.indices.contains(index), row.count == fields.count, !keys.isEmpty,
              keys.allSatisfy({ value(row[$0]) != nil }) else { return false }
        let field = fields[index]
        return !field.primary_key && field.auto_generated != true && !isBinary(field)
            && !(engine == "remote_sqlite" && row[index]?.hasPrefix("blob:") == true)
    }

    func literal(_ value: String) -> String {
        if engine == "postgres" {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "''")
            return "E'\(escaped)'"
        }
        let digits = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(value.utf8.count * 2)
        for byte in value.utf8 {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 15)])
        }
        let hex = String(decoding: bytes, as: UTF8.self)
        return engine == "mysql" ? "CONVERT(X'\(hex)' USING utf8mb4)" : "CAST(X'\(hex)' AS TEXT)"
    }

    private func mysqlOperand(_ text: String, _ field: DatabaseColumnSchema) -> String? {
        let type = field.db_type.lowercased().prefix { $0 != "(" && $0 != " " }
        if ["bigint", "int", "integer", "tinyint", "smallint", "mediumint", "decimal", "numeric", "float", "double", "real", "year"].contains(String(type)) {
            guard text.range(of: #"\A[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil else { return nil }
            return text
        }
        if isBinary(field) {
            guard text.utf8.count.isMultiple(of: 2), text.utf8.allSatisfy(Self.hexDigit) else { return nil }
            return "X'\(text)'"
        }
        return literal(text)
    }

    private static func hexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private func operand(_ raw: String, _ field: DatabaseColumnSchema) -> String? {
        if engine == "mysql" { return mysqlOperand(raw, field) }
        if engine == "postgres" { return literal(raw) }
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].utf8.count.isMultiple(of: 2), parts[1].utf8.allSatisfy(Self.hexDigit) else { return nil }
        let bytes = "X'\(parts[1])'"
        let text = "CAST(\(bytes) AS TEXT)"
        switch parts[0] {
        case "blob": return bytes
        case "text": return "+" + text
        case "integer": return "+CAST(\(text) AS INTEGER)"
        case "real":
            if value(raw) == "Inf" { return "9e999" }
            if value(raw) == "-Inf" { return "-9e999" }
            return "+CAST(\(text) AS REAL)"
        default: return nil
        }
    }

    func update(_ index: Int, row: [String?], newValue: String?) -> String? {
        guard canEdit(index, row: row), newValue != nil || columns[index].nullable else { return nil }
        return "UPDATE \(source) SET \(ident(columns[index].name)) = \(newValue.map(literal) ?? "NULL") WHERE \(matchingRow(keys + [index], row))"
    }

    private func matchingRow(_ indices: [Int], _ row: [String?]) -> String {
        let identity = keys.compactMap { i -> String? in
            guard let raw = row[i], let rhs = operand(raw, columns[i]) else { return nil }
            return ident(columns[i].name) + " = " + rhs
        }
        let original = indices.map { i in
            let expr = projection(columns[i])
            guard let raw = row[i] else { return "\(expr) IS NULL" }
            return (engine == "mysql" ? "BINARY " : "") + expr + " = " + literal(raw)
        }
        return (identity + original).joined(separator: " AND ")
    }

    func delete(_ row: [String?]) -> String? {
        guard row.count == columns.count, !keys.isEmpty, keys.allSatisfy({ value(row[$0]) != nil }) else { return nil }
        return "DELETE FROM \(source) WHERE \(matchingRow(Array(columns.indices), row))"
    }

    func insert(_ supplied: [Int: String?]) -> String {
        let indices = supplied.keys.sorted()
        if indices.isEmpty { return "INSERT INTO \(source) " + (engine == "mysql" ? "() VALUES ()" : "DEFAULT VALUES") }
        let names = indices.map { ident(columns[$0].name) }.joined(separator: ", ")
        let values = indices.map { supplied[$0, default: nil].map(literal) ?? "NULL" }.joined(separator: ", ")
        return "INSERT INTO \(source) (\(names)) VALUES (\(values))"
    }

    static func relationships(_ engine: String) -> String {
        switch engine {
        case "mysql":
            return """
            SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
            FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = DATABASE()
            AND REFERENCED_TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
            """
        case "postgres":
            return """
            SELECT s.relname::text, a.attname::text, t.relname::text, b.attname::text, sn.nspname::text, tn.nspname::text
            FROM pg_constraint c JOIN pg_class s ON s.oid=c.conrelid JOIN pg_class t ON t.oid=c.confrelid
            JOIN pg_namespace sn ON sn.oid=s.relnamespace JOIN pg_namespace tn ON tn.oid=t.relnamespace
            CROSS JOIN LATERAL unnest(c.conkey,c.confkey) AS k(src,dst)
            JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.src
            JOIN pg_attribute b ON b.attrelid=c.confrelid AND b.attnum=k.dst
            WHERE c.contype='f' AND sn.nspname !~ '^pg_' AND tn.nspname !~ '^pg_'
            """
        default:
            return """
            SELECT m.name AS src, child.name AS col, parent.name AS dst, target.name AS target
            FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) f
            JOIN pragma_table_info(m.name) child ON child.name=f."from" COLLATE NOCASE
            JOIN sqlite_master parent ON parent.name=f."table" COLLATE NOCASE AND parent.type='table'
            JOIN pragma_table_info(parent.name) target ON target.name=f."to" COLLATE NOCASE
                OR (f."to" IS NULL AND target.pk=f.seq+1)
            WHERE m.type='table'
            """
        }
    }
}
