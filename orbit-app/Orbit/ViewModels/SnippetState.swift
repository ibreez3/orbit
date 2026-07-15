import Foundation

final class SnippetState: ObservableObject {
    @Published var snippets: [CommandSnippet] = []
    @Published var snippetEditorOpen = false
    @Published var editingSnippet: CommandSnippet?
}
