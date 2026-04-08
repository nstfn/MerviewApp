import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct MerviewWebView: NSViewRepresentable {
    @ObservedObject var viewModel: MerviewViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Register custom scheme handler so fetch() works for local files
        let schemeHandler = LocalFileSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "app")

        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "nativeApp")
        config.userContentController = userController

        let webView = DropTargetWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.onFileDrop = { url in
            DispatchQueue.main.async {
                if url.hasDirectoryPath {
                    context.coordinator.viewModel.loadFolder(url)
                } else {
                    context.coordinator.viewModel.loadFile(url)
                }
            }
        }
        context.coordinator.webView = webView

        // Load via custom scheme so fetch() calls work
        let baseURL = URL(string: "app://local/index.html")!
        webView.load(URLRequest(url: baseURL))

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if let (content, filename) = viewModel.pendingContent {
            viewModel.pendingContent = nil
            context.coordinator.injectContent(content, filename: filename)
        }
        if let fileList = viewModel.pendingFileList {
            viewModel.pendingFileList = nil
            context.coordinator.injectFileList(fileList)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var viewModel: MerviewViewModel
        var webView: WKWebView?
        var isReady = false
        var pendingActions: [() -> Void] = []

        init(viewModel: MerviewViewModel) {
            self.viewModel = viewModel
            super.init()

            viewModel.onWebViewReady = { [weak self] in
                guard let self = self else { return }
                if let (content, filename) = self.viewModel.pendingContent {
                    self.viewModel.pendingContent = nil
                    self.injectContent(content, filename: filename)
                }
                if let fileList = self.viewModel.pendingFileList {
                    self.viewModel.pendingFileList = nil
                    self.injectFileList(fileList)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { return }
                self.isReady = true
                for action in self.pendingActions {
                    action()
                }
                self.pendingActions.removeAll()
            }
        }

        // Handle window.confirm() dialogs
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        // Handle window.alert() dialogs
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completionHandler()
        }

        func injectContent(_ content: String, filename: String) {
            let action = { [weak self] in
                guard let webView = self?.webView else { return }
                // Use base64 to avoid all escaping issues
                let b64 = Data(content.utf8).base64EncodedString()
                let js = """
                (function() {
                    var content = atob('\(b64)');
                    window.nativeBridge.loadContent(content, '\(filename.replacingOccurrences(of: "'", with: "\\'"))');
                })();
                """
                webView.evaluateJavaScript(js) { _, error in
                    if let error = error {
                        print("JS injection error: \(error)")
                    }
                }
            }

            if isReady {
                action()
            } else {
                pendingActions.append(action)
            }
        }

        func injectFileList(_ files: [String]) {
            let action = { [weak self] in
                guard let webView = self?.webView else { return }
                guard let jsonData = try? JSONSerialization.data(withJSONObject: files),
                      let jsonString = String(data: jsonData, encoding: .utf8) else { return }
                let b64 = Data(jsonString.utf8).base64EncodedString()
                let js = "window.nativeBridge.showFileList(atob('\(b64)'));"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }

            if isReady {
                action()
            } else {
                pendingActions.append(action)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = json["action"] as? String else { return }

            switch action {
            case "openFile":
                if let path = json["path"] as? String {
                    DispatchQueue.main.async { [weak self] in
                        self?.viewModel.loadFileByRelativePath(path)
                    }
                }
            case "save":
                if let content = json["content"] as? String, let filename = json["filename"] as? String {
                    nativeSave(content: content, filename: filename)
                }
            case "savePDF":
                nativeSavePDF()
            default:
                break
            }
        }

        private func nativeSave(content: String, filename: String) {
            DispatchQueue.main.async {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = filename.isEmpty ? "untitled.md" : filename
                panel.allowedContentTypes = [UTType(filenameExtension: "md")!, UTType.plainText]
                if panel.runModal() == .OK, let url = panel.url {
                    try? content.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }

        private func nativeSavePDF() {
            DispatchQueue.main.async { [weak self] in
                guard let webView = self?.webView else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "document.pdf"
                panel.allowedContentTypes = [UTType.pdf]
                if panel.runModal() == .OK, let url = panel.url {
                    webView.createPDF { result in
                        if case .success(let data) = result {
                            try? data.write(to: url)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Custom URL Scheme Handler

class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    private let webRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent("web")

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let path = url.host == "local" ? String(url.path.dropFirst()) : url.path.isEmpty ? nil : String(url.path.dropFirst()) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let filePath = path.isEmpty ? "index.html" : path

        guard let data = readBundledFileData(path: filePath) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType = mimeTypeForPath(filePath)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*"
            ]
        )!

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    func readBundledFile(path: String) -> String? {
        guard let data = readBundledFileData(path: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func readBundledFileData(path: String) -> Data? {
        guard let webRoot = webRoot else { return nil }
        let fileURL = webRoot.appendingPathComponent(path)
        return try? Data(contentsOf: fileURL)
    }

    private func mimeTypeForPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js":   return "application/javascript; charset=utf-8"
        case "mjs":  return "application/javascript; charset=utf-8"
        case "css":  return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg":  return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf":  return "font/ttf"
        default:     return "application/octet-stream"
        }
    }
}

// MARK: - Drag-and-drop WKWebView subclass

class DropTargetWebView: WKWebView {
    var onFileDrop: ((URL) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if hasMarkdownFiles(sender) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if hasMarkdownFiles(sender) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }

        for url in urls {
            let ext = url.pathExtension.lowercased()
            if url.hasDirectoryPath || ["md", "markdown", "mmd", "mermaid", "txt"].contains(ext) {
                onFileDrop?(url)
                return true
            }
        }
        return false
    }

    private func hasMarkdownFiles(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        return urls.contains { url in
            let ext = url.pathExtension.lowercased()
            return url.hasDirectoryPath || ["md", "markdown", "mmd", "mermaid", "txt"].contains(ext)
        }
    }
}
