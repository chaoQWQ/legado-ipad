import Foundation
import WebKit

@MainActor
final class ReaderAIImageScript: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private let provider: ReaderAIImageProvider
    private let timeout: TimeInterval
    private let session: URLSession
    private var webView: WKWebView?
    private var completion: CheckedContinuation<Data, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var input: [String: Any] = [:]

    init(provider: ReaderAIImageProvider, timeout: TimeInterval) {
        self.provider = provider
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    func run(prompt: String) async throws -> Data {
        let source = (provider.script ?? "").aiTrimmed
        guard !source.isEmpty else { throw ReaderAIError.provider("请填写生图脚本。") }
        let scriptProvider: [String: Any] = [
            "id": provider.id, "name": provider.name, "baseUrl": provider.address,
            "model": provider.model, "type": "js", "parameters": try provider.parameters(),
            "defaultParamsJson": provider.parametersJSON, "stylePrompt": provider.stylePrompt, "headers": provider.headers
        ]
        input = ["source": [provider.scriptLibrary ?? "", source].joined(separator: "\n"),
                 "prompt": prompt, "provider": scriptProvider]
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.userContentController.addScriptMessageHandler(self, contentWorld: .defaultClient, name: "legadoImageRequest")
                let view = WKWebView(frame: .zero, configuration: configuration)
                webView = view
                view.navigationDelegate = self
                view.loadHTMLString("<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-eval'\">", baseURL: nil)
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(self?.timeout ?? 120))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(ReaderAIError.provider("生图脚本运行超时。")))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript(Self.wrapper, arguments: input, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                guard let json = value as? String, json.utf8.count <= 48 * 1024 * 1024 else {
                    self.finish(.failure(ReaderAIError.emptyResponse))
                    return
                }
                self.finish(.success(Data(json.utf8)))
            case .failure:
                self.finish(.failure(ReaderAIError.provider("生图脚本执行失败。请检查语法、接口和返回的图片格式。")))
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(ReaderAIError.provider("生图脚本运行被中断。")))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(ReaderAIError.provider("无法启动生图脚本。")))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.scheme == "about" ? .allow : .cancel
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame, let fields = message.body as? [String: Any],
              let rawAddress = fields["url"] as? String else {
            replyHandler(nil, "无效的生图脚本请求。")
            return
        }
        Task {
            do {
                replyHandler(try await request(address: rawAddress, fields: fields), nil)
            } catch let error as ReaderAIError {
                replyHandler(nil, error.localizedDescription)
            } catch {
                replyHandler(nil, "生图脚本请求失败。")
            }
        }
    }

    private func request(address: String, fields: [String: Any]) async throws -> [String: Any] {
        let base = URL(string: provider.address.aiTrimmed)
        guard let url = URL(string: address, relativeTo: base)?.absoluteURL, ReaderAIEndpoint.isAllowed(url) else {
            throw ReaderAIError.invalidAddress
        }
        let method = (fields["method"] as? String ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else {
            throw ReaderAIError.provider("生图脚本请求支持 GET 或 POST。")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if method == "POST", let body = fields["body"] as? String {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var headers: [String: String] = [:]
        if let base, ReaderAIEndpoint.sameOrigin(base, url) {
            let key = provider.key.aiTrimmed
            if !key.isEmpty {
                guard !key.contains(where: \.isNewline), !key.utf8.contains(0) else { throw ReaderAIError.invalidHeaders }
                headers["authorization"] = "Bearer \(key)"
            }
            for (name, value) in try ReaderAIHeaders.parse(provider.headers) { headers[name] = value }
        }
        let supplied = fields["headers"] as? [String: String] ?? [:]
        if !supplied.isEmpty {
            let serialized = try JSONSerialization.data(withJSONObject: supplied)
            for (name, value) in try ReaderAIHeaders.parse(String(decoding: serialized, as: UTF8.self)) {
                headers[name] = value
            }
        }
        for (name, value) in headers where !["host", "content-length", "connection", "transfer-encoding"].contains(name) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let limit = 48 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw ReaderAIError.oversizedResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ReaderAIError.oversizedResponse }
            data.append(byte)
        }
        guard let response = response as? HTTPURLResponse else { throw ReaderAIError.emptyResponse }
        return ["status": response.statusCode, "body": String(decoding: data, as: UTF8.self)]
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let completion else { return }
        self.completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        session.invalidateAndCancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "legadoImageRequest", contentWorld: .defaultClient)
        webView?.stopLoading()
        webView = nil
        input = [:]
        completion.resume(with: result)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let from = response.url, let to = request.url, ReaderAIEndpoint.sameOrigin(from, to) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private static let wrapper = #"""
    const request = (url, method = 'GET', body = null, headers = {}) => window.webkit.messageHandlers.legadoImageRequest.postMessage({url, method, body, headers});
    const checked = async (...args) => {
        const response = await request(...args);
        if (response.status < 200 || response.status >= 300) throw new Error(`HTTP ${response.status}`);
        return response.body;
    };
    const java = {
        ajax: (url) => checked(url),
        get: (url, headers = {}) => checked(url, 'GET', null, headers),
        post: (url, body, headers = {}) => checked(url, 'POST', typeof body === 'string' ? body : JSON.stringify(body), headers)
    };
    const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
    const program = new AsyncFunction('prompt', 'provider', 'java', 'source', 'baseUrl', 'key', 'result', `${source}\n
        if (typeof generate === 'function') return await generate(prompt, provider);
        if (typeof run === 'function') return await run(prompt, provider);
        return result;
    `);
    return JSON.stringify(await program(prompt, provider, java, java, provider.baseUrl, prompt, prompt));
    """#
}
