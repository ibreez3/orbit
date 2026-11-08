import SwiftUI

struct ServerQuickConnectView: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var uiState: UIState
    @EnvironmentObject private var inventoryState: InventoryState
    @FocusState private var inputFocused: Bool
    @State private var selectedResultIndex = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(
                "搜索服务器或输入 user@host:port",
                text: $uiState.serverQuickConnectQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($inputFocused)
            .accessibilityIdentifier("serverQuickConnectInput")
            .onSubmit(activateSelectedResult)
            .onMoveCommand(perform: moveSelection)

            if !uiState.serverQuickConnectQuery.isEmpty {
                Button {
                    uiState.serverQuickConnectQuery = ""
                    uiState.serverQuickConnectResultsVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除服务器搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(inputFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08))
        )
        .overlay(alignment: .topLeading) {
            overlayContent
                .offset(y: 32)
        }
        .onChange(of: inputFocused) { focused in
            uiState.serverQuickConnectInputFocused = focused
            if focused, !uiState.serverQuickConnectQuery.isEmpty,
               uiState.temporaryConnectionDraft == nil {
                uiState.serverQuickConnectResultsVisible = true
            } else if !focused, uiState.temporaryConnectionDraft == nil {
                uiState.serverQuickConnectResultsVisible = false
            }
        }
        .onChange(of: uiState.serverQuickConnectInputFocused) { focused in
            if inputFocused != focused {
                inputFocused = focused
            }
        }
        .onChange(of: uiState.serverQuickConnectQuery) { query in
            selectedResultIndex = 0
            uiState.serverQuickConnectResultsVisible = inputFocused
                && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && uiState.temporaryConnectionDraft == nil
        }
        .zIndex(20)
    }

    @ViewBuilder
    private var overlayContent: some View {
        if uiState.temporaryConnectionDraft != nil {
            TemporaryConnectionPanel(appState: appState)
                .frame(width: 540)
        } else if uiState.serverQuickConnectResultsVisible, !results.isEmpty {
            resultList
                .frame(maxWidth: 500)
        }
    }

    private var resultList: some View {
        VStack(spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                Button {
                    activate(result)
                } label: {
                    resultRow(result)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            index == selectedResultIndex
                                ? Color.accentColor.opacity(0.13)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.1))
        )
        .shadow(color: .black.opacity(0.2), radius: 14, y: 7)
    }

    @ViewBuilder
    private func resultRow(_ result: ServerSearchResult) -> some View {
        switch result {
        case .saved(let match):
            HStack(spacing: 9) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.blue)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.server.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(savedServerDetail(match))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(match.server.host):\(match.server.port)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        case .temporary(let address):
            HStack(spacing: 9) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.orange)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("临时连接")
                        .font(.system(size: 12, weight: .medium))
                    Text(formatted(address))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("补充认证信息")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        case .newServer(let query):
            HStack(spacing: 9) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.green)
                    .frame(width: 16)
                Text("新建服务器")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if !query.isEmpty {
                    Text(query)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var results: [ServerSearchResult] {
        let query = uiState.serverQuickConnectQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var values = ServerSearchIndex(
            servers: inventoryState.servers,
            organization: appState.serverOrganization
        )
        .search(query)
        .prefix(8)
        .map(ServerSearchResult.saved)

        if case .success(let address) = ServerAddressParser.parse(query) {
            values.append(.temporary(address))
        }
        values.append(.newServer(query: query))
        return values
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard uiState.serverQuickConnectResultsVisible, !results.isEmpty else { return }
        switch direction {
        case .up:
            selectedResultIndex = max(0, selectedResultIndex - 1)
        case .down:
            selectedResultIndex = min(results.count - 1, selectedResultIndex + 1)
        default:
            break
        }
    }

    private func activateSelectedResult() {
        guard !results.isEmpty else { return }
        activate(results[min(selectedResultIndex, results.count - 1)])
    }

    private func activate(_ result: ServerSearchResult) {
        switch result {
        case .saved(let match):
            appState.addTab(server: match.server, type: .terminal)
            appState.closeServerQuickConnect()
        case .temporary(let address):
            appState.presentTemporaryConnectionPanel(address: address)
        case .newServer(let query):
            let parsed = try? ServerAddressParser.parse(query).get()
            let defaults = ServerInput(
                name: "",
                host: parsed?.host ?? query,
                port: parsed?.port ?? 22,
                group_name: nil,
                auth_type: "password",
                username: parsed?.username ?? "",
                password: nil,
                private_key: nil,
                key_source: "content",
                key_file_path: nil,
                key_passphrase: nil,
                credential_group_id: nil,
                jump_server_id: nil
            )
            appState.closeServerQuickConnect()
            appState.openDialog(defaults: defaults)
        }
    }

    private func savedServerDetail(_ match: ServerSearchMatch) -> String {
        let details = [match.folderPath, match.tags.isEmpty ? nil : match.tags.joined(separator: ", ")]
            .compactMap { $0 }
        return details.isEmpty ? "已保存服务器" : details.joined(separator: " · ")
    }

    private func formatted(_ address: ParsedServerAddress) -> String {
        let host = address.host.contains(":") ? "[\(address.host)]" : address.host
        let username = address.username.map { "\($0)@" } ?? ""
        return "\(username)\(host):\(address.port)"
    }
}
