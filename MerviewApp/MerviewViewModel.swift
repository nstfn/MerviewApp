import Foundation
import Combine

class MerviewViewModel: ObservableObject {
    @Published var currentFile: URL?
    @Published var folderFiles: [URL] = []
    @Published var folderRoot: URL?

    /// Pending content to inject once the web view is ready
    var pendingContent: (String, String)?
    /// Pending file list to show in sidebar
    var pendingFileList: [String]?

    /// Called by the web view when it's ready
    var onWebViewReady: (() -> Void)?

    /// File watcher for live reload
    private var fileWatcherSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    func loadFile(_ url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        currentFile = url
        let filename = url.lastPathComponent
        pendingContent = (content, filename)
        onWebViewReady?()
        watchFile(url)
    }

    func loadFolder(_ url: URL) {
        folderRoot = url
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var mdFiles: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            if ["md", "markdown", "mmd", "mermaid"].contains(ext) {
                mdFiles.append(fileURL)
            }
        }

        mdFiles.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        folderFiles = mdFiles

        let basePath = url.path
        let relativePaths = mdFiles.map { fileURL -> String in
            let full = fileURL.path
            if full.hasPrefix(basePath) {
                return String(full.dropFirst(basePath.count + 1))
            }
            return fileURL.lastPathComponent
        }

        pendingFileList = relativePaths
        onWebViewReady?()

        if let first = mdFiles.first {
            loadFile(first)
        }
    }

    func loadFileByRelativePath(_ relativePath: String) {
        guard let root = folderRoot else { return }
        let fileURL = root.appendingPathComponent(relativePath)
        loadFile(fileURL)
    }

    // MARK: - File watching

    private func watchFile(_ url: URL) {
        stopWatching()

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self = self, let currentFile = self.currentFile else { return }
            // Small delay to let the write finish (editors do atomic saves)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // Re-read and re-inject
                guard let content = try? String(contentsOf: currentFile, encoding: .utf8) else {
                    // File was renamed/moved (atomic save) — re-watch the path
                    self.watchFile(currentFile)
                    if let content = try? String(contentsOf: currentFile, encoding: .utf8) {
                        self.pendingContent = (content, currentFile.lastPathComponent)
                        self.onWebViewReady?()
                    }
                    return
                }
                self.pendingContent = (content, currentFile.lastPathComponent)
                self.onWebViewReady?()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        source.resume()
        fileWatcherSource = source
    }

    private func stopWatching() {
        fileWatcherSource?.cancel()
        fileWatcherSource = nil
    }

    deinit {
        stopWatching()
    }
}
