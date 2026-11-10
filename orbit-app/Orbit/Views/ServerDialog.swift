import AgentKit
import SwiftUI

struct ServerDialog: View {
    @EnvironmentObject var inventoryState: InventoryState
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var form = ServerInput(
        name: "", host: "", port: 22, group_name: nil, auth_type: "password",
        username: "", password: nil, private_key: nil, key_source: "content",
        key_file_path: nil, key_passphrase: nil, credential_group_id: nil,
        jump_server_id: nil
    )
    @State private var showPassword = false
    @State private var showKeyPass = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var saving = false
    @State private var selectedTagIds: Set<String> = []
    @State private var persistence = ServerDialogPersistence()
    @State private var newTagName = ""
    @State private var saveError: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    basicSection
                    sectionDivider
                    connectionSection
                    sectionDivider
                    authenticationSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            if let result = testResult {
                connectionResultBanner(result)
            }
            if let saveError {
                errorBanner(saveError)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: sheetHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.18), value: sheetHeight)
        .onAppear {
            if let server = inventoryState.editingServer {
                persistence.bind(
                    serverId: server.id,
                    servers: inventoryState.servers,
                    snapshot: appState.serverOrganization
                )
                applyAuthoritativeServer(server)
                selectedTagIds = persistence.selectedTagIds
            } else if let defaults = inventoryState.dialogDefaults {
                form = defaults
                form.group_name = nil
            }
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(targetServerId != nil ? "编辑服务器" : "添加服务器")
                    .font(.system(size: 15, weight: .semibold))
                Text(targetServerId != nil ? "修改连接与认证信息" : "填写 SSH 连接与认证信息")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityIdentifier("serverDialogCloseButton")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: handleTest) {
                HStack(spacing: 6) {
                    if testing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Text("测试连接")
                }
            }
            .disabled(testing || form.host.isEmpty || (!useCg && form.username.isEmpty))
            .accessibilityIdentifier("serverTestButton")

            if let serverId = targetServerId {
                Divider().frame(height: 20)
                Button("删除", role: .destructive) {
                    appState.deleteServer(serverId)
                    dismiss()
                }
                .accessibilityIdentifier("serverDeleteButton")
            }

            Spacer()

            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("serverCancelButton")
            Button("保存") { handleSave() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || form.name.isEmpty || form.host.isEmpty || (!useCg && form.username.isEmpty))
                .accessibilityIdentifier("serverSaveButton")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Sections

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("基本信息")
            HStack(spacing: 10) {
                formLabel("名称", required: true)
                TextField("My Server", text: $form.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .accessibilityIdentifier("serverNameField")
                formLabel("目录", compact: true)
                Picker(selection: folderBinding) {
                    Text("未分类").tag("")
                    ForEach(sortedFolders) { folder in
                        Text(folderPath(folder)).tag(folder.id)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .frame(width: 170)
                .accessibilityIdentifier("serverFolderPicker")
            }
            HStack(alignment: .top, spacing: 10) {
                formLabel("标签")
                tagsContent
            }
            if let serverId = targetServerId {
                HStack(spacing: 10) {
                    formLabel("AI 访问")
                    Toggle("允许 AI Agent 使用此服务器", isOn: Binding(
                        get: { AgentExposureStore.shared.isEnabled(serverId: serverId) },
                        set: { enabled in
                            AgentExposureStore.shared.setEnabled(enabled, serverId: serverId)
                            AgentGateway.shared.applyServerExposureChange(
                                serverId: serverId,
                                enabled: enabled
                            )
                        }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("连接")
            HStack(spacing: 10) {
                formLabel("主机地址", required: true)
                TextField("192.168.1.1", text: $form.host)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("serverHostField")
                formLabel("端口", compact: true)
                TextField("22", value: Binding(
                    get: { form.port ?? 22 },
                    set: { form.port = $0 }
                ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 84)
                    .accessibilityIdentifier("serverPortField")
            }
            HStack(spacing: 10) {
                formLabel("跳板机")
                if inventoryState.servers.isEmpty {
                    Text("直连（暂无可用跳板机）")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(selection: jumpBinding) {
                        Text("直连").tag(false)
                        Text("通过跳板机").tag(true)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)

                    if jumpBinding.wrappedValue {
                        Picker(selection: jumpServerIdBinding) {
                            ForEach(inventoryState.servers) { server in
                                Text("\(server.name) (\(server.host):\(server.port))").tag(server.id)
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                    }
                }
            }
        }
    }

    private var authenticationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("认证")
            HStack(spacing: 10) {
                formLabel("认证来源")
                if inventoryState.credentialGroups.isEmpty {
                    Text("自定义凭据（暂无凭据分组）")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(selection: credentialSourceBinding) {
                        Text("自定义凭据").tag(false)
                        Text("凭据分组").tag(true)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)

                    if useCg {
                        Picker(selection: credentialGroupIdBinding) {
                            ForEach(inventoryState.credentialGroups) { group in
                                Text("\(group.name) (\(group.username))").tag(group.id)
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                    }
                }
            }

            if useCg {
                if let group = selectedCg {
                    credentialSummary(group)
                }
            } else {
                HStack(spacing: 10) {
                    formLabel("用户名", required: true)
                    TextField("root", text: $form.username)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("serverUsernameField")
                }

                HStack(spacing: 10) {
                    formLabel("认证方式")
                    Picker(selection: authTypeBinding) {
                        Text("密码认证").tag("password")
                        Text("密钥认证").tag("key")
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                    .accessibilityIdentifier("serverAuthTypePicker")
                }

                if (form.auth_type ?? "password") == "password" {
                    passwordRow
                } else {
                    keyAuthRows
                }
            }
        }
    }

    private var passwordRow: some View {
        HStack(spacing: 10) {
            formLabel("密码")
            Group {
                if showPassword {
                    TextField("密码", text: passwordBinding)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("serverPasswordField")
                } else {
                    SecureField("密码", text: passwordBinding)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("serverPasswordField")
                }
            }
            Button(action: { showPassword.toggle() }) {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(showPassword ? "隐藏密码" : "显示密码")
        }
    }

    private var keyAuthRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                formLabel("密钥来源")
                Picker(selection: keySourceBinding) {
                    Text("粘贴内容").tag("content")
                    Text("本地文件").tag("file")
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }

            if (form.key_source ?? "content") == "file" {
                HStack(spacing: 10) {
                    formLabel("私钥文件")
                    TextField("~/.ssh/id_rsa", text: keyFilePathBinding)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("serverKeyPathField")
                    Button("选择…") { selectKeyFile() }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    formLabel("私钥内容")
                    TextEditor(text: privateKeyBinding)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 96)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                        .accessibilityIdentifier("serverPrivateKeyEditor")
                }
            }

            HStack(spacing: 10) {
                formLabel("密钥密码")
                Group {
                    if showKeyPass {
                        TextField("可选", text: keyPassphraseBinding)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("serverKeyPassphraseField")
                    } else {
                        SecureField("可选", text: keyPassphraseBinding)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("serverKeyPassphraseField")
                    }
                }
                Button(action: { showKeyPass.toggle() }) {
                    Image(systemName: showKeyPass ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(showKeyPass ? "隐藏密钥密码" : "显示密钥密码")
            }
        }
    }

    private var tagsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sortedTags.isEmpty {
                Text("暂无标签")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 92), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(sortedTags) { tag in
                        tagChip(tag)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("新建标签", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit { createTag() }
                    .accessibilityIdentifier("serverNewTagField")
                Button("添加") { createTag() }
                    .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("serverCreateTagButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tagChip(_ tag: ServerTag) -> some View {
        let selected = selectedTagIds.contains(tag.id)
        return Button {
            if selected {
                selectedTagIds.remove(tag.id)
            } else {
                selectedTagIds.insert(tag.id)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(tag.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func credentialSummary(_ group: CredentialGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.round")
                .foregroundStyle(.secondary)
            Text("\(group.name) · \(group.username) · \(group.auth_type == "password" ? "密码认证" : "密钥认证")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Shared pieces

    private var sectionDivider: some View {
        Divider().opacity(0.7)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func formLabel(_ text: String, required: Bool = false, compact: Bool = false) -> some View {
        HStack(spacing: 2) {
            Text(text)
            if required {
                Text("*").foregroundStyle(.red)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: compact ? 52 : 78, alignment: .trailing)
    }

    private func connectionResultBanner(_ result: String) -> some View {
        let success = result == "success"
        let message = success
            ? "连接成功"
            : "连接失败：\(result.hasPrefix("error:") ? String(result.dropFirst(6)) : result)"
        return HStack(spacing: 6) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
            Text(message)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(success ? Color.green : Color.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background((success ? Color.green : Color.red).opacity(0.1))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Bindings

    private var folderBinding: Binding<String> {
        Binding(
            get: { form.folder_id ?? "" },
            set: { form.folder_id = $0.isEmpty ? nil : $0 }
        )
    }

    private var jumpBinding: Binding<Bool> {
        Binding(
            get: { form.jump_server_id != nil },
            set: { enabled in
                if enabled {
                    if form.jump_server_id == nil {
                        form.jump_server_id = inventoryState.servers.first?.id
                    }
                } else {
                    form.jump_server_id = nil
                }
            }
        )
    }

    private var jumpServerIdBinding: Binding<String> {
        Binding(
            get: { form.jump_server_id ?? "" },
            set: { form.jump_server_id = $0.isEmpty ? nil : $0 }
        )
    }

    private var credentialSourceBinding: Binding<Bool> {
        Binding(
            get: { useCg },
            set: { useGroup in
                if useGroup {
                    if form.credential_group_id == nil {
                        form.credential_group_id = inventoryState.credentialGroups.first?.id
                    }
                } else {
                    form.credential_group_id = nil
                }
            }
        )
    }

    private var credentialGroupIdBinding: Binding<String> {
        Binding(
            get: { form.credential_group_id ?? "" },
            set: { form.credential_group_id = $0.isEmpty ? nil : $0 }
        )
    }

    private var authTypeBinding: Binding<String> {
        Binding(
            get: { form.auth_type ?? "password" },
            set: { form.auth_type = $0 }
        )
    }

    private var keySourceBinding: Binding<String> {
        Binding(
            get: { form.key_source ?? "content" },
            set: { form.key_source = $0 }
        )
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { form.password ?? "" },
            set: { form.password = $0.isEmpty ? nil : $0 }
        )
    }

    private var privateKeyBinding: Binding<String> {
        Binding(
            get: { form.private_key ?? "" },
            set: { form.private_key = $0.isEmpty ? nil : $0 }
        )
    }

    private var keyFilePathBinding: Binding<String> {
        Binding(
            get: { form.key_file_path ?? "" },
            set: { form.key_file_path = $0.isEmpty ? nil : $0 }
        )
    }

    private var keyPassphraseBinding: Binding<String> {
        Binding(
            get: { form.key_passphrase ?? "" },
            set: { form.key_passphrase = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Actions and helpers

    /// Key authentication needs room for the private-key editor and passphrase.
    private var sheetHeight: CGFloat {
        if !useCg && (form.auth_type ?? "password") == "key" {
            return 720
        }
        return 600
    }

    private var useCg: Bool { form.credential_group_id != nil }
    private var targetServerId: String? {
        persistence.targetServerId(fallback: inventoryState.editingServer?.id)
    }
    private var selectedCg: CredentialGroup? {
        guard let id = form.credential_group_id else { return nil }
        return inventoryState.credentialGroups.first(where: { $0.id == id })
    }

    private var sortedFolders: [ServerFolder] {
        appState.serverOrganization.folders.sorted {
            folderPath($0).localizedCaseInsensitiveCompare(folderPath($1)) == .orderedAscending
        }
    }

    private var sortedTags: [ServerTag] {
        appState.serverOrganization.tags.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func folderPath(_ folder: ServerFolder) -> String {
        let projection = ServerTreeProjection(
            snapshot: appState.serverOrganization,
            servers: inventoryState.servers
        )
        return projection.path(forFolderId: folder.id) ?? folder.name
    }

    private func selectKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            form.key_file_path = url.path
        }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        saveError = nil
        Task {
            do {
                let tag = try await appState.createServerTag(name: name)
                await MainActor.run {
                    selectedTagIds.insert(tag.id)
                    newTagName = ""
                }
            } catch {
                await MainActor.run { saveError = "创建标签失败：\(error.localizedDescription)" }
            }
        }
    }

    private func handleTest() {
        testing = true
        testResult = nil
        Task {
            do {
                let ok = try appState.bridge.testConnection(input: form)
                testResult = ok ? "success" : "fail"
            } catch {
                testResult = "error:\(error)"
            }
            testing = false
        }
    }

    private func handleSave() {
        guard !form.name.isEmpty, !form.host.isEmpty else { return }
        if !useCg && form.username.isEmpty { return }
        saving = true
        saveError = nil
        form.group_name = nil
        Task {
            do {
                _ = try await appState.saveServer(
                    form,
                    tagIds: selectedTagIds.sorted(),
                    editingId: targetServerId
                )
                await MainActor.run {
                    saving = false
                    dismiss()
                }
            } catch let failure as ServerSaveFailure {
                await MainActor.run {
                    persistence.bind(
                        serverId: failure.serverId,
                        servers: appState.servers,
                        snapshot: appState.serverOrganization
                    )
                    if let savedServer = persistence.savedServer {
                        applyAuthoritativeServer(savedServer)
                    }
                    selectedTagIds = persistence.selectedTagIds
                    saving = false
                    saveError = "保存服务器失败：\(failure.localizedDescription)"
                }
            } catch {
                await MainActor.run {
                    saving = false
                    saveError = "保存服务器失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func applyAuthoritativeServer(_ server: Server) {
        form = ServerInput(
            name: server.name,
            host: server.host,
            port: server.port,
            group_name: nil,
            auth_type: server.auth_type,
            username: server.username,
            password: server.password.isEmpty ? nil : server.password,
            private_key: server.private_key.isEmpty ? nil : server.private_key,
            key_source: server.key_source.isEmpty ? "content" : server.key_source,
            key_file_path: server.key_file_path.isEmpty ? nil : server.key_file_path,
            key_passphrase: server.key_passphrase.isEmpty ? nil : server.key_passphrase,
            credential_group_id: server.credential_group_id.isEmpty ? nil : server.credential_group_id,
            jump_server_id: server.jump_server_id.isEmpty ? nil : server.jump_server_id,
            folder_id: server.folder_id
        )
    }
}

struct ToggleButtonStyle: ButtonStyle {
    let isActive: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor))
            )
    }
}
