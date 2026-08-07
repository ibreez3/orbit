import AppKit
import SwiftUI

struct TemporaryConnectionPanel: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var uiState: UIState
    @EnvironmentObject private var inventoryState: InventoryState
    @FocusState private var focusedField: Field?

    private enum Field {
        case username
        case password
        case privateKey
        case keyFile
    }

    var body: some View {
        if uiState.temporaryConnectionDraft != nil {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        addressFields
                        credentialFields
                        jumpServerField
                        saveFields
                        errorMessage
                    }
                    .padding(14)
                }
                .frame(maxHeight: 500)
                footer
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.1))
            )
            .shadow(color: .black.opacity(0.24), radius: 18, y: 9)
            .onAppear(perform: restoreEditingFocus)
            .onChange(of: draft.wrappedValue.connectionError) { error in
                if error != nil { restoreEditingFocus() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("临时 SSH 连接")
                    .font(.system(size: 13, weight: .semibold))
                Text("认证信息仅保存在当前会话内")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appState.dismissTemporaryConnectionPanel()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭临时连接面板")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.035))
    }

    private var addressFields: some View {
        HStack(spacing: 10) {
            labeled("主机") {
                TextField("host", text: draft.host)
                    .textFieldStyle(.roundedBorder)
            }
            labeled("端口") {
                TextField("22", value: draft.port, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
            }
            labeled("用户名") {
                TextField("用户名", text: draft.username)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .username)
            }
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                labeled("认证来源") {
                    Picker("", selection: credentialSource) {
                        Text("直接输入").tag("")
                        ForEach(inventoryState.credentialGroups) { group in
                            Text(group.name).tag(group.id)
                        }
                    }
                    .labelsHidden()
                }

                if draft.wrappedValue.credentialGroupId == nil {
                    labeled("认证方式") {
                        Picker("", selection: draft.authType) {
                            Text("密码").tag("password")
                            Text("密钥").tag("key")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
            }

            if draft.wrappedValue.credentialGroupId == nil {
                if draft.wrappedValue.authType == "password" {
                    labeled("密码") {
                        SecureField("密码", text: draft.password)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .password)
                    }
                } else {
                    keyFields
                }
            } else if let group = selectedCredentialGroup {
                Text("\(group.auth_type == "key" ? "密钥认证" : "密码认证") · \(group.username)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var keyFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("密钥来源", selection: draft.keySource) {
                Text("粘贴内容").tag("content")
                Text("本地文件").tag("file")
            }
            .pickerStyle(.segmented)

            if draft.wrappedValue.keySource == "file" {
                HStack(spacing: 8) {
                    TextField("~/.ssh/id_ed25519", text: draft.keyFilePath)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .keyFile)
                    Button("选择") { chooseKeyFile() }
                }
            } else {
                TextEditor(text: draft.privateKey)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .focused($focusedField, equals: .privateKey)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.primary.opacity(0.12))
                    )
            }

            SecureField("密钥口令（可选）", text: draft.keyPassphrase)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var jumpServerField: some View {
        labeled("跳板机") {
            Picker("", selection: optionalSelection(draft.jumpServerId)) {
                Text("直连").tag("")
                ForEach(inventoryState.servers) { server in
                    Text("\(server.name) (\(server.host):\(server.port))").tag(server.id)
                }
            }
            .labelsHidden()
        }
    }

    private var saveFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("保存到资产", isOn: draft.saveToAssets)
                .toggleStyle(.switch)

            if draft.wrappedValue.saveToAssets {
                HStack(spacing: 10) {
                    labeled("服务器名称") {
                        TextField("服务器名称", text: draft.displayName)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled("目录") {
                        Picker("", selection: optionalSelection(draft.folderId)) {
                            Text("未分类").tag("")
                            ForEach(sortedFolders) { folder in
                                Text(folderPath(folder.id)).tag(folder.id)
                            }
                        }
                        .labelsHidden()
                    }
                }

                if !appState.serverOrganization.tags.isEmpty {
                    labeled("标签") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], alignment: .leading) {
                            ForEach(appState.serverOrganization.tags) { tag in
                                Toggle(tag.name, isOn: tagSelection(tag.id))
                                    .toggleStyle(.button)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let message = draft.wrappedValue.validationError ?? draft.wrappedValue.connectionError {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(draft.wrappedValue.saveToAssets ? "连接成功后保存" : "仅本次连接")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") {
                appState.dismissTemporaryConnectionPanel()
            }
            Button {
                appState.submitTemporaryConnection()
            } label: {
                HStack(spacing: 5) {
                    if draft.wrappedValue.isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(draft.wrappedValue.isConnecting ? "连接中" : "连接")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.wrappedValue.isConnecting)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.035))
    }

    private var draft: Binding<TemporaryConnectionDraft> {
        Binding(
            get: { uiState.temporaryConnectionDraft! },
            set: { uiState.temporaryConnectionDraft = $0 }
        )
    }

    private var credentialSource: Binding<String> {
        Binding(
            get: { draft.wrappedValue.credentialGroupId ?? "" },
            set: { value in
                var valueDraft = draft.wrappedValue
                valueDraft.credentialGroupId = value.isEmpty ? nil : value
                valueDraft.clearSecrets()
                if let group = inventoryState.credentialGroups.first(where: { $0.id == value }) {
                    valueDraft.authType = group.auth_type
                    if valueDraft.username.isEmpty {
                        valueDraft.username = group.username
                    }
                }
                draft.wrappedValue = valueDraft
            }
        )
    }

    private var selectedCredentialGroup: CredentialGroup? {
        guard let id = draft.wrappedValue.credentialGroupId else { return nil }
        return inventoryState.credentialGroups.first { $0.id == id }
    }

    private var sortedFolders: [ServerFolder] {
        appState.serverOrganization.folders.sorted {
            folderPath($0.id).lowercased() < folderPath($1.id).lowercased()
        }
    }

    private func labeled<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func optionalSelection(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private func tagSelection(_ tagId: String) -> Binding<Bool> {
        Binding(
            get: { draft.wrappedValue.tagIds.contains(tagId) },
            set: { selected in
                var ids = draft.wrappedValue.tagIds
                if selected {
                    if !ids.contains(tagId) { ids.append(tagId) }
                } else {
                    ids.removeAll { $0 == tagId }
                }
                draft.wrappedValue.tagIds = ids
            }
        )
    }

    private func folderPath(_ folderId: String) -> String {
        let byId = Dictionary(uniqueKeysWithValues: appState.serverOrganization.folders.map { ($0.id, $0) })
        var currentId: String? = folderId
        var names: [String] = []
        var visited: Set<String> = []
        while let id = currentId,
              let folder = byId[id],
              visited.insert(id).inserted {
            names.append(folder.name)
            currentId = folder.parent_id
        }
        return names.reversed().joined(separator: "/")
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.wrappedValue.keyFilePath = url.path
        }
    }

    private func restoreEditingFocus() {
        if draft.wrappedValue.username.isEmpty {
            focusedField = .username
        } else if draft.wrappedValue.credentialGroupId != nil {
            focusedField = .username
        } else if draft.wrappedValue.authType == "key" {
            focusedField = draft.wrappedValue.keySource == "file" ? .keyFile : .privateKey
        } else {
            focusedField = .password
        }
    }
}
