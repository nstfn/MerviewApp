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

        // Use a persistent data store so localStorage survives across launches
        config.websiteDataStore = .default()

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

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Allow our custom app:// scheme (local bundled content)
            if url.scheme == "app" {
                decisionHandler(.allow)
                return
            }

            // Allow fragment-only navigations (anchor links within the document)
            if url.scheme == "about" || url.absoluteString.hasPrefix("about:") {
                decisionHandler(.allow)
                return
            }

            // External link (http, https, mailto, etc.) → open in system browser
            if let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
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
                    var bytes = Uint8Array.from(atob('\(b64)'), function(c) { return c.charCodeAt(0); });
                    var content = new TextDecoder('utf-8').decode(bytes);
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
                let js = """
                (function() {
                    var bytes = Uint8Array.from(atob('\(b64)'), function(c) { return c.charCodeAt(0); });
                    var json = new TextDecoder('utf-8').decode(bytes);
                    window.nativeBridge.showFileList(json);
                })();
                """
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
                guard panel.runModal() == .OK, let url = panel.url else { return }

                // A4 in points (72 DPI): 595.28 × 841.89
                let a4Width: CGFloat = 595.28
                let a4Height: CGFloat = 841.89

                // 1) Force-render all pending mermaid diagrams before capture
                let renderMermaid = """
                    if (typeof forceRenderAllMermaidDiagrams === 'function') {
                        await forceRenderAllMermaidDiagrams();
                    }
                """

                webView.callAsyncJavaScript(renderMermaid, arguments: [:], in: nil, in: .page) { _ in
                    DispatchQueue.main.async {
                        // 2) Inject print-layout CSS (createPDF ignores @media print)
                        //    At 72 DPI: 1 CSS px = 1 PDF pt. Padding 56px ≈ 2cm (A4 standard).
                        //    Font 11px = 11pt (standard print size).
                        let applyPrintCSS = """
                        (function() {
                            var s = document.createElement('style');
                            s.id = '_pdf_export_styles';
                            s.textContent = '\\
                                .toolbar, .editor-panel, .panel-header, .resize-handle, .status, .lint-panel, .native-sidebar { display: none !important; } \\
                                .container { display: block !important; height: auto !important; } \\
                                .preview-panel { border: none !important; width: 100% !important; } \\
                                #preview { overflow: visible !important; background: white !important; padding: 0 !important; margin: 0 !important; max-width: none !important; } \\
                                #wrapper { display: block !important; padding: 56px !important; max-width: none !important; margin: 0 !important; font-size: 11px !important; line-height: 1.5 !important; } \\
                                #wrapper h1 { font-size: 22px !important; } \\
                                #wrapper h2 { font-size: 18px !important; } \\
                                #wrapper h3 { font-size: 15px !important; } \\
                                #wrapper h4, #wrapper h5, #wrapper h6 { font-size: 13px !important; } \\
                                #wrapper table { table-layout: fixed !important; width: 100% !important; word-wrap: break-word !important; overflow-wrap: break-word !important; } \\
                                #wrapper pre, #wrapper pre code, #wrapper pre code.hljs, #wrapper .hljs { white-space: pre-wrap !important; word-break: break-all !important; overflow-wrap: break-word !important; overflow: hidden !important; max-width: 100% !important; } \\
                                #wrapper code { word-break: break-all !important; overflow-wrap: break-word !important; } \\
                                #wrapper .mermaid-container, #wrapper .mermaid { max-width: 100% !important; overflow: hidden !important; } \\
                                #wrapper .mermaid svg { max-width: 100% !important; height: auto !important; } \\
                                .mermaid, img, svg, table, blockquote, pre { page-break-inside: avoid; break-inside: avoid; } \\
                                img, svg { max-width: 100% !important; height: auto !important; } \\
                                #wrapper h1, #wrapper h2, #wrapper h3, #wrapper h4, #wrapper h5, #wrapper h6 { page-break-after: avoid; break-after: avoid; } \\
                            ';
                            document.head.appendChild(s);
                        })();
                        """

                        let removePrintCSS = """
                        (function() {
                            var s = document.getElementById('_pdf_export_styles');
                            if (s) s.remove();
                        })();
                        """

                        webView.evaluateJavaScript(applyPrintCSS) { _, _ in
                            DispatchQueue.main.async {
                                // 3) Temporarily resize web view to A4 so createPDF
                                //    produces A4-sized pages
                                let originalFrame = webView.frame
                                webView.translatesAutoresizingMaskIntoConstraints = true
                                webView.frame = NSRect(
                                    x: originalFrame.origin.x,
                                    y: originalFrame.origin.y,
                                    width: a4Width,
                                    height: a4Height
                                )

                                // 4) Allow layout to settle at A4 width, then capture
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    webView.createPDF { result in
                                        DispatchQueue.main.async {
                                            // Restore original layout
                                            webView.frame = originalFrame
                                            webView.translatesAutoresizingMaskIntoConstraints = false
                                            webView.evaluateJavaScript(removePrintCSS, completionHandler: nil)
                                        }
                                        if case .success(let data) = result {
                                            try? data.write(to: url)
                                        }
                                    }
                                }
                            }
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
