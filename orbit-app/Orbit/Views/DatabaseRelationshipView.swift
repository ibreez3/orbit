import SwiftUI

struct DatabaseRelationshipView: View {
    let tables: [DatabaseTableSchema]
    let fetch: () async throws -> DatabaseQueryResult
    let openTable: (String) -> Void

    @State private var links: [[String]] = []
    @State private var selected = ""
    @State private var error: String?
    @State private var loading = true
    private let width: CGFloat = 222
    private let step: CGFloat = 284
    private let header: CGFloat = 30
    private let row: CGFloat = 22

    private var origins: [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        var y: CGFloat = 28
        var tallest: CGFloat = 0
        for (i, table) in tables.enumerated() {
            if i > 0 && i % 3 == 0 { y += tallest + 48; tallest = 0 }
            result[table.id] = CGPoint(x: 30 + CGFloat(i % 3) * step, y: y)
            tallest = max(tallest, header + CGFloat(table.columns.count) * row)
        }
        return result
    }

    var body: some View {
        let points = origins
        let height = tables.map { (points[$0.id]?.y ?? 0) + header + CGFloat($0.columns.count) * row }.max() ?? 0
        VStack(spacing: 0) {
            HStack {
                Text("数据库关系图").fontWeight(.semibold)
                Spacer()
                Picker("定位表", selection: $selected) {
                    Text("选择表").tag("")
                    ForEach(tables) { Text($0.displayName).tag($0.id) }
                }.fixedSize()
                DatabaseToolButton(symbol: "tablecells", title: "打开表数据") { openTable(selected) }.disabled(selected.isEmpty)
            }.font(.caption).padding(6).background(.ultraThinMaterial)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for link in links {
                                guard let from = point(link[0], link[1], points), let to = point(link[2], link[3], points),
                                      let origin = points[link[0]] else { continue }
                                var start = from
                                var end = CGPoint(x: to.x + width, y: to.y)
                                var path = Path()
                                if abs(to.x - from.x) == step && origin.y == points[link[2]]?.y {
                                    if to.x > from.x { start.x += width; end.x = to.x }
                                    let mid = (start.x + end.x) / 2
                                    path.move(to: start)
                                    path.addLine(to: CGPoint(x: mid, y: start.y))
                                    path.addLine(to: CGPoint(x: mid, y: end.y))
                                } else {
                                    let gutter = origin.y - 14
                                    path.move(to: start)
                                    path.addLine(to: CGPoint(x: start.x - 10, y: start.y))
                                    path.addLine(to: CGPoint(x: start.x - 10, y: gutter))
                                    path.addLine(to: CGPoint(x: end.x + 12, y: gutter))
                                    path.addLine(to: CGPoint(x: end.x + 12, y: end.y))
                                }
                                path.addLine(to: end)
                                let active = selected == link[0] || selected == link[2]
                                context.stroke(path, with: .color(active ? .accentColor : .secondary.opacity(0.6)), lineWidth: active ? 1.8 : 1)
                                context.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(.secondary))
                            }
                        }
                        ForEach(tables) { table in
                            VStack(spacing: 0) {
                                HStack {
                                    Image(systemName: "tablecells")
                                    Text(table.displayName).fontWeight(.semibold).lineLimit(1)
                                    Spacer()
                                }.padding(.horizontal, 8).frame(height: header).background(Color.primary.opacity(0.06))
                                ForEach(Array(table.columns.enumerated()), id: \.offset) { _, field in
                                    HStack(spacing: 4) {
                                        Text(field.primary_key ? "PK" : links.contains { $0[0] == table.id && $0[1] == field.name } ? "FK" : "")
                                            .foregroundStyle(.secondary).frame(width: 20)
                                        Text(field.name)
                                        Spacer()
                                        Text(field.db_type).foregroundStyle(.secondary)
                                    }.lineLimit(1).padding(.horizontal, 6).frame(height: row)
                                }
                            }.font(.system(size: 11, design: .monospaced)).frame(width: width)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected == table.id ? Color.accentColor : Color.secondary.opacity(0.45)))
                            .onTapGesture(count: 2) { openTable(table.id) }
                            .onTapGesture { selected = table.id }
                            .id(table.id)
                            .padding(.leading, points[table.id]?.x ?? 0)
                            .padding(.top, points[table.id]?.y ?? 0)
                        }
                    }.frame(width: CGFloat(min(tables.count, 3)) * step, height: height + 30, alignment: .topLeading)
                }.onChange(of: selected) { name in proxy.scrollTo(name, anchor: .center) }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            HStack {
                Text("\(tables.count) 张表")
                if loading { ProgressView().controlSize(.small) }
                else if error == nil { Text(links.isEmpty ? "未声明库内外键" : "\(links.count) 对关联字段") }
                Spacer()
                Text("PK 主键　FK 外键")
            }.font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .task {
            do {
                let result = try await fetch()
                links = result.rows.compactMap { row in
                    let values = row.compactMap { $0 }
                    if values.count == 6 {
                        return [DatabaseTableSchema.qualified(values[4], values[0]), values[1],
                                DatabaseTableSchema.qualified(values[5], values[2]), values[3]]
                    }
                    return values.count == 4 ? values : nil
                }
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func point(_ table: String, _ field: String, _ origins: [String: CGPoint]) -> CGPoint? {
        guard let origin = origins[table], let columns = tables.first(where: { $0.id == table })?.columns,
              let i = columns.firstIndex(where: { $0.name == field }) else { return nil }
        return CGPoint(x: origin.x, y: origin.y + header + (CGFloat(i) + 0.5) * row)
    }
}
