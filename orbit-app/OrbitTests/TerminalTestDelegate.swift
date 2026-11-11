import AppKit
import SwiftTerm

@MainActor
final class TerminalTestDelegate: NSObject, TerminalViewDelegate {
    var sizes: [(Int, Int)] = []
    var sent = Data()

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { sizes.append((newCols, newRows)) }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func bell(source: SwiftTerm.TerminalView) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
}
