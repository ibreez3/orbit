import SwiftUI

struct ServerDialog: View {
    @Environment(AppState.self) var appState
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
    @State private var isCreatingGroup = false
    @State private var newGroupName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            formContent
            footer
        }
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let server = appState.editingServer {
                form = ServerInput(
                    name: server.name, host: server.host, port: server.port,
                    group_name: server.group_name.isEmpty ? nil : server.group_name,
                    auth_type: server.auth_type, username: server.username,
                    password: server.password.isEmpty ? nil : server.password,
                    private_key: server.private_key.isEmpty ? nil : server.private_key,
                    key_source: server.key_source.isEmpty ? "content" : server.key_source,
                    key_file_path: server.key_file_path.isEmpty ? nil : server.key_file_path,
                    key_passphrase: server.key_passphrase.isEmpty ? nil : server.key_passphrase,
                    credential_group_id: server.credential_group_id.isEmpty ? nil : server.credential_group_id,
                    jump_server_id: server.jump_server_id.isEmpty ? nil : server.jump_server_id
                )
            } else if let defaults = appState.dialogDefaults {
                form = defaults
            }
        }
    }

    private var header: some View {
        HStack {
            Text(appState.editingServer != nil ? "编辑服务器" : "添加服务器")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                nameAndGroup
                hostAndPort
                jumpServer
                credentialSource
                if !useCg {
                    usernameField
                    authType
                    authFields
                }
                if let result = testResult {
                    testResultView(result)
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack {
            Button(action: handleTest) {
                HStack(spacing: 4) {
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

            Spacer()

            if appState.editingServer != nil {
                Button("删除", role: .destructive) {
                    if let server = appState.editingServer {
                        appState.deleteServer(server.id)
                        dismiss()
                    }
                }
            }

            Button("取消") { dismiss() }
            Button("保存") { handleSave() }
                .buttonStyle(.borderedProminent)
                .disabled(saving || form.name.isEmpty || form.host.isEmpty || (!useCg && form.username.isEmpty))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var nameAndGroup: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("名称 *").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("My Server", text: $form.name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("分组").font(.system(size: 11)).foregroundStyle(.secondary)
                if isCreatingGroup {
                    TextField("输入新分组名称", text: $newGroupName, onCommit: {
                        if !newGroupName.trimmingCharacters(in: .whitespaces).isEmpty {
                            form.group_name = newGroupName
                        } else {
                            isCreatingGroup = false
                            form.group_name = nil
                        }
                    })
                    .textFieldStyle(.roundedBorder)
                } else {
                    Picker(selection: Binding(
                        get: { form.group_name ?? "" },
                        set: { v in
                            if v == "__new__" {
                                isCreatingGroup = true
                                newGroupName = ""
                            } else {
                                form.group_name = v.isEmpty ? nil : v
                            }
                        }
                    )) {
                        Text("默认分组").tag("")
                        ForEach(existingGroups, id: \.self) { g in
                            Text(g).tag(g)
                        }
                        Text("+ 新建分组").tag("__new__")
                    } label: { EmptyView() }
                }
            }
        }
    }

    private var hostAndPort: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("主机地址 *").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("192.168.1.1", text: $form.host)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("端口").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("22", value: Binding(
                    get: { form.port ?? 22 },
                    set: { form.port = $0 }
                ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
        }
    }

    private var jumpServer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("跳板机").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("直连") {
                    form.jump_server_id = nil
                }
                .buttonStyle(toggleButtonStyle(isActive: form.jump_server_id == nil))
                Button(action: {
                    if form.jump_server_id == nil, !appState.servers.isEmpty {
                        form.jump_server_id = appState.servers[0].id
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text("通过跳板机")
                    }
                }
                .buttonStyle(toggleButtonStyle(isActive: form.jump_server_id != nil))
            }
            if form.jump_server_id != nil {
                Picker(selection: Binding(
                    get: { form.jump_server_id ?? "" },
                    set: { form.jump_server_id = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(appState.servers) { s in
                        Text("\(s.name) (\(s.host):\(s.port))").tag(s.id)
                    }
                } label: { EmptyView() }
            }
        }
    }

    private var credentialSource: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("认证来源").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("自定义凭据") {
                    form.credential_group_id = nil
                }
                .buttonStyle(toggleButtonStyle(isActive: !useCg))
                Button(action: {
                    if !useCg, !appState.credentialGroups.isEmpty {
                        form.credential_group_id = appState.credentialGroups[0].id
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "key.round")
                        Text("凭据分组")
                    }
                }
                .buttonStyle(toggleButtonStyle(isActive: useCg))
            }
            if useCg {
                Picker(selection: Binding(
                    get: { form.credential_group_id ?? "" },
                    set: { form.credential_group_id = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(appState.credentialGroups) { g in
                        Text("\(g.name) (\(g.username))").tag(g.id)
                    }
                } label: { EmptyView() }
                if let cg = selectedCg {
                    Text("\(cg.auth_type == "password" ? "密码认证" : "密钥认证") · \(cg.username)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    private var usernameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("用户名 *").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("root", text: $form.username)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var authType: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("认证方式").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("密码认证") { form.auth_type = "password" }
                    .buttonStyle(toggleButtonStyle(isActive: form.auth_type == "password"))
                Button("密钥认证") { form.auth_type = "key" }
                    .buttonStyle(toggleButtonStyle(isActive: form.auth_type == "key"))
            }
        }
    }

    @ViewBuilder
    private var authFields: some View {
        if form.auth_type == "password" {
            VStack(alignment: .leading, spacing: 4) {
                Text("密码").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    if showPassword {
                        TextField("密码", text: Binding(
                            get: { form.password ?? "" },
                            set: { form.password = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("密码", text: Binding(
                            get: { form.password ?? "" },
                            set: { form.password = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            keyAuthFields
        }
    }

    private var keyAuthFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: { form.key_source = "content" }) {
                    HStack(spacing: 4) { Image(systemName: "doc.on.clipboard"); Text("粘贴内容") }
                }
                .buttonStyle(toggleButtonStyle(isActive: form.key_source != "file"))
                Button(action: { form.key_source = "file" }) {
                    HStack(spacing: 4) { Image(systemName: "key"); Text("本地文件") }
                }
                .buttonStyle(toggleButtonStyle(isActive: form.key_source == "file"))
            }

            if form.key_source == "file" {
                HStack(spacing: 8) {
                    TextField("~/.ssh/id_rsa", text: Binding(
                        get: { form.key_file_path ?? "" },
                        set: { form.key_file_path = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("选择") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            form.key_file_path = url.path
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("私钥内容").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { form.private_key ?? "" },
                        set: { form.private_key = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                }
            }

            HStack {
                if showKeyPass {
                    TextField("密钥密码（可选）", text: Binding(
                        get: { form.key_passphrase ?? "" },
                        set: { form.key_passphrase = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("密钥密码（可选）", text: Binding(
                        get: { form.key_passphrase ?? "" },
                        set: { form.key_passphrase = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                Button(action: { showKeyPass.toggle() }) {
                    Image(systemName: showKeyPass ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func testResultView(_ result: String) -> some View {
        let isSuccess = result == "success"
        return Text(isSuccess ? "连接成功" : "连接失败: \(result)")
            .font(.system(size: 12))
            .foregroundStyle(isSuccess ? .green : .red)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((isSuccess ? Color.green : Color.red).opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var useCg: Bool { form.credential_group_id != nil }
    private var selectedCg: CredentialGroup? {
        guard let id = form.credential_group_id else { return nil }
        return appState.credentialGroups.first(where: { $0.id == id })
    }

    private var existingGroups: [String] {
        let set = Set(appState.servers.compactMap { $0.group_name.isEmpty ? nil : $0.group_name })
        return set.sorted()
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
        Task {
            if let server = appState.editingServer {
                appState.updateServer(id: server.id, input: form)
            } else {
                appState.addServer(form)
            }
            await MainActor.run {
                saving = false
                dismiss()
            }
        }
    }

    private func toggleButtonStyle(isActive: Bool) -> some ButtonStyle {
        ToggleButtonStyle(isActive: isActive)
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
