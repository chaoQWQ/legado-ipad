import BookSources
import SwiftUI
#if os(iOS)
import SafariServices
#endif

struct SubscriptionsHomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var editFeed: FeedEditorTarget?
    @State private var pendingRemoval: FeedSubscription?
    @State private var removalError: String?
    @State private var website: SubscriptionWebsite?

    var body: some View {
        List {
            Section("书源广场") {
                ForEach(BookSourceMarketplaceProvider.allCases) { provider in
                    NavigationLink {
                        SourceMarketplaceView(provider: provider)
                    } label: {
                        Label(provider.title, systemImage: "square.grid.2x2")
                    }
                }
            }
            Section("内置订阅") {
                ForEach(SubscriptionWebsite.presets) { website in
                    #if os(iOS)
                    Button {
                        self.website = website
                    } label: {
                        Label(website.title, systemImage: website.icon)
                    }
                    #else
                    Link(destination: website.url) {
                        Label(website.title, systemImage: website.icon)
                    }
                    #endif
                }
            }
            Section {
                NavigationLink {
                    SourceSubscriptionsView()
                } label: {
                    HStack {
                        Label("规则订阅", systemImage: "list.bullet.rectangle")
                        Spacer()
                        if !library.subscriptionsWithUpdates.isEmpty {
                            Text("\(library.subscriptionsWithUpdates.count) 项有更新")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("RSS / Atom") {
                ForEach(library.feeds) { feed in
                    NavigationLink {
                        FeedArticlesView(subscription: feed)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feed.name)
                            Text(feed.url.host ?? feed.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("编辑订阅", systemImage: "pencil") { editFeed = FeedEditorTarget(feed: feed) }
                        Button("取消订阅", systemImage: "trash", role: .destructive) { pendingRemoval = feed }
                    }
                    .swipeActions {
                        Button("取消订阅", systemImage: "trash", role: .destructive) { pendingRemoval = feed }
                    }
                }
                Button("添加 RSS / Atom", systemImage: "plus") { editFeed = FeedEditorTarget(feed: nil) }
            }
        }
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .sheet(item: $website) { website in
            SubscriptionBrowser(url: website.url)
                .ignoresSafeArea()
        }
        #endif
        .sheet(item: $editFeed) { target in
            NavigationStack { FeedEditorView(subscription: target.feed) }
        }
        .confirmationDialog("取消订阅", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { feed in
            Button("移除「\(feed.name)」", role: .destructive) {
                do { try library.removeFeed(feed.id) }
                catch { removalError = error.localizedDescription }
            }
        }
        .alert("无法移除订阅", isPresented: Binding(
            get: { removalError != nil },
            set: { if !$0 { removalError = nil } }
        )) {
            Button("好", role: .cancel) { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }

    private struct FeedEditorTarget: Identifiable {
        let id = UUID()
        let feed: FeedSubscription?
    }
}

private struct SubscriptionWebsite: Identifiable {
    let title: String
    let icon: String
    let url: URL

    var id: URL { url }

    static let presets = [
        Self(title: "使用说明", icon: "book.closed", url: URL(string: "https://www.yuque.com/legado")!),
        Self(title: "导入", icon: "square.and.arrow.down", url: URL(string: "https://lyc.ydz6.com/b/daoru")!),
        Self(title: "Meow云", icon: "cloud", url: URL(string: "https://pan.miaogongzi.net/")!)
    ]
}

#if os(iOS)
struct SubscriptionBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif

private struct FeedEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var name: String
    @State private var address: String
    @State private var isValidating = false
    @State private var validation: Task<Void, Never>?
    @State private var errorMessage: String?
    let subscription: FeedSubscription?

    init(subscription: FeedSubscription?) {
        self.subscription = subscription
        _name = State(initialValue: subscription?.name ?? "")
        _address = State(initialValue: subscription?.url.absoluteString ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("名称（选填）", text: $name)
                TextField("RSS 或 Atom 地址", text: $address)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }
            if isValidating { ProgressView("正在读取订阅…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle(subscription == nil ? "添加订阅" : "编辑订阅")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(isValidating || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onDisappear { validation?.cancel() }
    }

    private func save() {
        isValidating = true
        errorMessage = nil
        let input = address
        let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        validation = Task {
            defer { isValidating = false }
            do {
                let url = try FeedSubscription.address(from: input)
                let feedTitle: String
                if subscription?.url == url, !requestedName.isEmpty { feedTitle = requestedName }
                else { feedTitle = try await SubscriptionFeedClient().load(url).title }
                try Task.checkCancellation()
                let title = !requestedName.isEmpty ? requestedName : (feedTitle.isEmpty ? (url.host ?? url.absoluteString) : feedTitle)
                try library.saveFeed(.init(id: subscription?.id ?? UUID(), name: title, url: url))
                dismiss()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct FeedArticlesView: View {
    let subscription: FeedSubscription
    @State private var feed: SubscriptionFeed?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let feed, !feed.articles.isEmpty {
                List(feed.articles) { article in
                    NavigationLink {
                        articleDetail(article)
                    } label: {
                        articleRow(article)
                    }
                }
                .refreshable { await load() }
                .scrollContentBackground(.hidden)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("无法载入订阅", systemImage: "exclamationmark.circle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { attempt += 1 }
                }
            } else if feed != nil {
                ContentUnavailableView("暂无文章", systemImage: "tray")
            } else {
                ProgressView("正在读取订阅…")
            }
        }
        .navigationTitle(subscription.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") { attempt += 1 }
                    .disabled(isLoading)
            }
        }
        .task(id: attempt) { await load() }
        .alert("刷新失败", isPresented: Binding(
            get: { errorMessage != nil && feed?.articles.isEmpty == false },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func articleRow(_ article: SubscriptionFeed.Article) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.title).font(.headline)
            if let date = article.publishedAt {
                Text(date, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !article.summary.isEmpty {
                Text(article.summary)
                    .lineLimit(2)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func articleDetail(_ article: SubscriptionFeed.Article) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(article.title).font(.title2.weight(.semibold))
                if !article.summary.isEmpty { Text(article.summary).textSelection(.enabled) }
                if let link = article.url { Link("打开原文", destination: link).buttonStyle(.bordered) }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("文章")
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let updated = try await SubscriptionFeedClient().load(subscription.url)
            try Task.checkCancellation()
            feed = updated
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}
