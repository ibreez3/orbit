import SwiftUI
import AppKit

class TextEditorState: ObservableObject {
    @Published var content: String = ""
    @Published var originalContent: String = ""
    @Published var loading = true
    @Published var saving = false
    @Published var errorMessage: String?

    let serverId: String
    let filePath: String
    let fileName: String
    let onClose: () -> Void
    let onSaved: () -> Void

    private let maxFileSize: UInt64 = 2 * 1024 * 1024

    init(serverId: String, filePath: String, fileName: String,
         onClose: @escaping () -> Void, onSaved: @escaping () -> Void) {
        self.serverId = serverId
        self.filePath = filePath
        self.fileName = fileName
        self.onClose = onClose
        self.onSaved = onSaved
    }

    func loadContent() {
        let serverId = serverId
        let filePath = filePath
        let maxSize = maxFileSize
        print("[TextEditorState] loadContent 开始 serverId=\(serverId) path=\(filePath)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let text = try OrbitBridge.shared.sftpReadTextFile(
                    serverId: serverId,
                    path: filePath,
                    maxSize: maxSize
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    print("[TextEditorState] loadContent OK path=\(filePath) contentLen=\(text.count)")
                    self.content = text
                    self.originalContent = text
                    self.loading = false
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    print("[TextEditorState] loadContent FAILED path=\(filePath) error=\(error.localizedDescription)")
                    self.errorMessage = error.localizedDescription
                    self.loading = false
                }
            }
        }
    }

    func saveContent() {
        saving = true
        let serverId = serverId
        let filePath = filePath
        let newContent = content
        print("[TextEditorState] saveContent 开始 path=\(filePath) contentLen=\(newContent.count)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try OrbitBridge.shared.sftpWriteTextFile(
                    serverId: serverId,
                    path: filePath,
                    content: newContent
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    print("[TextEditorState] saveContent OK path=\(filePath)")
                    self.originalContent = newContent
                    self.saving = false
                    self.onSaved()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    print("[TextEditorState] saveContent FAILED path=\(filePath) error=\(error.localizedDescription)")
                    self.saving = false
                    let alert = NSAlert()
                    alert.messageText = "保存失败"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "确定")
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}

class TextEditorWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    deinit {
        if let win = window {
            win.delegate = nil
            win.close()
        }
    }

    func open(serverId: String, filePath: String, fileName: String) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let contentView = TextEditorView(
            serverId: serverId,
            filePath: filePath,
            fileName: fileName,
            onClose: { [weak self] in
                self?.window?.performClose(nil)
            },
            onSaved: { [weak self] in
                guard let self, let win = self.window else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    win.performClose(nil)
                }
            }
        )
        let hosting = NSHostingController(rootView: contentView)
        let win = NSWindow(contentViewController: hosting)
        win.title = "编辑: \(fileName)"
        win.setContentSize(NSSize(width: 700, height: 500))
        win.minSize = NSSize(width: 500, height: 300)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct TextEditorView: View {
    @StateObject private var state: TextEditorState

    init(serverId: String, filePath: String, fileName: String,
         onClose: @escaping () -> Void, onSaved: @escaping () -> Void) {
        _state = StateObject(wrappedValue: TextEditorState(
            serverId: serverId,
            filePath: filePath,
            fileName: fileName,
            onClose: onClose,
            onSaved: onSaved
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.loading {
                ProgressView("加载文件内容...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = state.errorMessage {
                errorView(error)
            } else {
                editor
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { state.loadContent() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(state.filePath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !state.loading && state.errorMessage == nil {
                Button("保存") {
                    print("[TextEditorView] 点击保存: \(state.filePath)")
                    state.saveContent()
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.saving || state.content == state.originalContent)
                .keyboardShortcut("s", modifiers: .command)
            }
            Button("关闭") {
                print("[TextEditorView] 点击关闭: \(state.filePath)")
                state.onClose()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("关闭") { state.onClose() }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $state.content)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if state.content.isEmpty {
                Text("文件为空")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
    }
}
