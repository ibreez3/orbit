import SwiftUI

struct CredentialGroupDialog: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss

    @State private var form = CredentialGroupInput(
        name: "", auth_type: "password", username: "",
        password: nil, private_key: nil, key_source: "content",
        key_file_path: nil, key_passphrase: nil
    )
    @State private var showPassword = false
    @State private var showKeyPass = false
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    groupName
                    usernameField
                    authType
                    authFields
                    hint
                }
                .padding(16)
            }
            footer
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let cg = appState.editingCg {
                form = CredentialGroupInput(
                    name: cg.name, auth_type: cg.auth_type, username: cg.username,
                    password: cg.password.isEmpty ? nil : cg.password,
                    private_key: cg.private_key.isEmpty ? nil : cg.private_key,
                    key_source: cg.key_source.isEmpty ? "content" : cg.key_source,
                    key_file_path: cg.key_file_path.isEmpty ? nil : cg.key_file_path,
                    key_passphrase: cg.key_passphrase.isEmpty ? nil : cg.key_passphrase
                )
            }
        }
    }

    private var header: some View {
        HStack {
            Text(appState.editingCg != nil ? "编辑凭据分组" : "新建凭据分组")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var groupName: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("分组名称 *").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("生产环境密钥", text: $form.name)
                .textFieldStyle(.roundedBorder)
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
                    .buttonStyle(ToggleButtonStyle(isActive: form.auth_type == "password"))
                Button("密钥认证") { form.auth_type = "key" }
                    .buttonStyle(ToggleButtonStyle(isActive: form.auth_type == "key"))
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
                .buttonStyle(ToggleButtonStyle(isActive: form.key_source != "file"))
                Button(action: { form.key_source = "file" }) {
                    HStack(spacing: 4) { Image(systemName: "key"); Text("本地文件") }
                }
                .buttonStyle(ToggleButtonStyle(isActive: form.key_source == "file"))
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
                    .frame(height: 80)
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

    private var hint: some View {
        Text("关联此分组的服务器将使用该分组的凭据进行连接，无需单独配置密码或密钥。")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
            Button("保存") { handleSave() }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(saving || form.name.isEmpty || form.username.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func handleSave() {
        guard !form.name.isEmpty, !form.username.isEmpty else { return }
        saving = true
        Task {
            if let cg = appState.editingCg {
                appState.updateCg(id: cg.id, input: form)
            } else {
                appState.addCg(form)
            }
            await MainActor.run {
                saving = false
                dismiss()
            }
        }
    }
}
