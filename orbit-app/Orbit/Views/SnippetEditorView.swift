import SwiftUI

struct SnippetEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var description: String = ""
    @State private var tagsText: String = ""

    private var isEditing: Bool { appState.editingSnippet != nil }

    private var input: CommandSnippetInput {
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return CommandSnippetInput(
            name: name, command: command, description: description,
            tags: tags, serverId: appState.editingSnippet?.serverId
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
                        if let snippet = appState.editingSnippet {
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
                    if let snippet = appState.editingSnippet {
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
        .frame(width: 460, height: 340)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if let snippet = appState.editingSnippet {
                name = snippet.name
                command = snippet.command
                description = snippet.description
                tagsText = snippet.tags.joined(separator: ", ")
            }
        }
    }
}
