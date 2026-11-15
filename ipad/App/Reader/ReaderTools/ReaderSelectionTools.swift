import SwiftUI

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
