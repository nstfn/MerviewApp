import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = MerviewViewModel()

    var body: some View {
        MerviewWebView(viewModel: viewModel)
            .onReceive(NotificationCenter.default.publisher(for: .openFile)) { _ in
                openFilePanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
                openFolderPanel()
            }
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md")!,
            UTType(filenameExtension: "markdown")!,
            UTType.plainText
        ]
        panel.message = "Select a Markdown file to preview"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.loadFile(url)
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Select a folder containing Markdown files"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.loadFolder(url)
        }
    }
}
