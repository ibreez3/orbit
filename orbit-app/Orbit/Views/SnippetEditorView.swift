import SwiftUI

struct SnippetEditorView: View {
    @EnvironmentObject var snippetState: SnippetState
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var description: String = ""
    @State private var tagsText: String = ""

    private var isEditing: Bool { snippetState.editingSnippet != nil }

    private var input: CommandSnippetInput {
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return CommandSnippetInput(
            name: name, command: command, description: description,
            tags: tags, serverId: snippetState.editingSnippet?.serverId
        )
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(isEditing ? "编辑命令片段" : "新建命令片段")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Form
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("名称").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField("例如：查看磁盘空间", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("命令").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextEditor(text: $command)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        .scrollContentBackground(.hidden)

                    HStack(spacing: 8) {
                        Text("可用变量:")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        ForEach(Self.availableVariables, id: \.0) { placeholder, label in
                            Button(action: { insertVariable(placeholder) }) {
                                Text("{{\(label)}}")
                                    .font(.system(size: 10, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.06))
                                    .cornerRadius(3)
                            }
                            .buttonStyle(.plain)
                            .help("插入 \(label) 变量")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("描述（可选）").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField("简要描述这个命令的用途", text: $description)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("标签（逗号分隔）").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField("例如：docker, 日志, 磁盘", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }
            }
            .padding(.horizontal, 20)

            // Bottom buttons
            HStack {
                if isEditing {
                    Button("删除片段") {
                        if let snippet = snippetState.editingSnippet {
                            appState.deleteSnippet(snippet.id)
                        }
                        appState.closeSnippetEditor()
                        dismiss()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("取消") { appState.closeSnippetEditor(); dismiss() }
                    .font(.system(size: 12))
                Button("保存") {
                    if let snippet = snippetState.editingSnippet {
                        appState.updateSnippet(id: snippet.id, input: input)
                    } else {
                        appState.addSnippet(input)
                    }
                    appState.closeSnippetEditor()
                    dismiss()
                }
                .disabled(!isValid)
                .font(.system(size: 12, weight: .semibold))
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 460, height: 360)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if let snippet = snippetState.editingSnippet {
                name = snippet.name
                command = snippet.command
                description = snippet.description
                tagsText = snippet.tags.joined(separator: ", ")
            }
        }
    }

    static let availableVariables: [(String, String)] = [
        ("{{host}}", "host"),
        ("{{user}}", "user"),
        ("{{port}}", "port"),
        ("{{server_name}}", "server_name"),
        ("{{group}}", "group"),
    ]

    private func insertVariable(_ placeholder: String) {
        command += placeholder
    }
}
