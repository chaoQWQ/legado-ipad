import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ReaderAISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ReaderAISettings()
    @State private var errorMessage: String?

    var body: some View {
        Form {
            providerSection("问 AI", provider: $settings.question)
            providerSection("生图", provider: $settings.image)
        }
        .navigationTitle("AI 设置")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do {
                        try settings.save()
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        .task {
            do {
                settings = try ReaderAISettings.load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("AI 设置", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func providerSection(_ title: String, provider: Binding<ReaderAIProvider>) -> some View {
        Section(title) {
            TextField("HTTPS 接口地址", text: provider.address)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            TextField("模型", text: provider.model)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField("API 密钥", text: provider.key)
        }
    }
}

struct ReaderAISheet: View {
    let kind: ReaderAIKind
    let excerpt: String

    @Environment(\.dismiss) private var dismiss
    @State private var provider: ReaderAIProvider?
    @State private var prompt: String
    @State private var answer: String?
    @State private var picture: Image?
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?

    init(kind: ReaderAIKind, excerpt: String) {
        self.kind = kind
        self.excerpt = excerpt
        _prompt = State(initialValue: kind == .question ? "请解释这段文字。" : excerpt)
    }

    var body: some View {
        NavigationStack {
            Form {
                if kind == .question {
                    Section("选中文本") {
                        Text(excerpt)
                            .textSelection(.enabled)
                    }
                }
                Section(kind == .question ? "问题" : "图片提示词") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 72)
                        .accessibilityLabel(kind == .question ? "问题" : "图片提示词")
                        .disabled(operation != nil)
                }
                if let provider, provider.canSend,
                   let destination = try? provider.endpoint(for: kind).host {
                    Section {
                        if operation != nil {
                            ProgressView(kind == .question ? "正在获取回答" : "正在生图")
                            Button("取消请求", role: .cancel) { operation?.cancel() }
                        } else {
                            Button(kind == .question ? "发送问题" : "生成图片") { send(provider) }
                                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } footer: {
                        Text("请求会发送到 \(destination)。")
                    }
                } else {
                    Section {
                        NavigationLink("配置 AI 服务") { ReaderAISettingsView() }
                    } footer: {
                        Text(ReaderAIError.missingSettings.localizedDescription)
                    }
                }
                if let answer {
                    Section("回答") { Text(answer).textSelection(.enabled) }
                }
                if let picture {
                    Section("生成结果") {
                        picture.resizable().scaledToFit()
                            .accessibilityLabel("生成的图片")
                        ShareLink(item: picture, preview: SharePreview("阅读生图", image: picture)) {
                            Label("分享或保存", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(kind.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .onAppear {
                do {
                    provider = try ReaderAISettings.load()[kind]
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .onDisappear { operation?.cancel() }
    }

    private func send(_ provider: ReaderAIProvider) {
        guard operation == nil else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        errorMessage = nil
        answer = nil
        picture = nil
        operation = Task {
            defer { operation = nil }
            do {
                switch kind {
                case .question:
                    let response = try await ReaderAIClient.answer(question: text, excerpt: excerpt, provider: provider)
                    try Task.checkCancellation()
                    answer = response
                case .image:
                    let data = try await ReaderAIClient.generateImage(prompt: text, provider: provider)
                    try Task.checkCancellation()
                    picture = try makeImage(data)
                }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private func makeImage(_ data: Data) throws -> Image {
        #if os(iOS)
        if let image = UIImage(data: data) { return Image(uiImage: image) }
        #elseif os(macOS)
        if let image = NSImage(data: data) { return Image(nsImage: image) }
        #endif
        throw ReaderAIError.emptyResponse
    }
}

struct ReaderWebSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var engine = Engine.bing
    @State private var destination: Destination?

    init(query: String) {
        _query = State(initialValue: query)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("搜索关键词", text: $query, axis: .vertical)
                    .lineLimit(1...4)
                Picker("搜索引擎", selection: $engine) {
                    ForEach(Engine.allCases) { engine in Text(engine.rawValue).tag(engine) }
                }
                if let url = engine.url(for: query) {
                    #if os(iOS)
                    Button("搜索") { destination = Destination(url: url) }
                    #else
                    Link("搜索", destination: url)
                    #endif
                }
            }
            .navigationTitle("网页搜索")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            #if os(iOS)
            .sheet(item: $destination) { page in
                SubscriptionBrowser(url: page.url)
                    .ignoresSafeArea()
            }
            #endif
        }
    }

    private struct Destination: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private enum Engine: String, CaseIterable, Identifiable {
        case bing = "Bing"
        case baidu = "百度"
        case google = "Google"

        var id: Self { self }

        func url(for text: String) -> URL? {
            let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            var url = URLComponents()
            url.scheme = "https"
            let parameter: String
            switch self {
            case .bing:
                url.host = "www.bing.com"
                url.path = "/search"
                parameter = "q"
            case .baidu:
                url.host = "www.baidu.com"
                url.path = "/s"
                parameter = "wd"
            case .google:
                url.host = "www.google.com"
                url.path = "/search"
                parameter = "q"
            }
            url.queryItems = [URLQueryItem(name: parameter, value: term)]
            return url.url
        }
    }
}
