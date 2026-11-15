import BookSources
import SwiftUI

struct SourceSubscriptionsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var edit: SubscriptionDraft?
    @State private var pendingRemoval: BookSourceSubscription?
    @State private var errorMessage: String?
    @State private var query = ""

    private var visibleSubscriptions: [BookSourceSubscription] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.sourceSubscriptions.filter {
            term.isEmpty || $0.name.localizedCaseInsensitiveContains(term)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        Group {
            if library.sourceSubscriptions.isEmpty {
                ContentUnavailableView {
                    Label("还没有书源订阅", systemImage: "link.badge.plus")
                } description: {
                    Text("保存书源 JSON 链接后，可随时检查和导入更新。")
                } actions: {
                    Button("添加订阅") { edit = SubscriptionDraft() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(visibleSubscriptions) { subscription in
                        NavigationLink {
                            SourceSubscriptionPreview(request: .subscription(subscription))
                        } label: {
                            subscriptionRow(subscription)
                        }
                        .swipeActions {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                pendingRemoval = subscription
                            }
                            Button("编辑", systemImage: "pencil") {
                                edit = SubscriptionDraft(subscription: subscription)
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button("编辑订阅", systemImage: "pencil") {
                                edit = SubscriptionDraft(subscription: subscription)
                            }
                            Button("删除订阅", systemImage: "trash", role: .destructive) {
                                pendingRemoval = subscription
                            }
                        }
                    }
                }
                .searchable(text: $query, prompt: "查找订阅")
                .overlay {
                    if visibleSubscriptions.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
        .navigationTitle("书源订阅")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加订阅", systemImage: "plus") { edit = SubscriptionDraft() }
            }
        }
        .sheet(item: $edit) { draft in
            SourceSubscriptionEditor(draft: draft)
        }
        .confirmationDialog("删除订阅", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { subscription in
            Button("删除「\(subscription.name)」", role: .destructive) {
                do {
                    try library.removeSourceSubscription(subscription.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: { _ in
            Text("从这个地址导入的书源会继续保留在书源管理中。")
        }
        .alert("无法删除订阅", isPresented: showingError($errorMessage)) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func subscriptionRow(_ subscription: BookSourceSubscription) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(subscription.name).font(.headline)
            Text(subscription.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let date = subscription.lastRefreshedAt {
                Text("上次检查 \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if subscription.autoUpdate {
                Text("每隔 \(subscription.updateIntervalHours) 小时检查")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if library.subscriptionsWithUpdates.contains(subscription.id) {
                Label("有更新待查看", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 3)
    }
}

struct SourceAddressImportView: View {
    let onComplete: () -> Void

    @State private var address = ""
    @State private var previewURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                SourceAddressField(address: $address)
            } header: {
                Text("书源地址")
            } footer: {
                Text("粘贴书源 JSON、源仓库详情网址或阅读的一键导入链接。")
            }

            Button("预览书源", systemImage: "doc.text.magnifyingglass") {
                do {
                    previewURL = try BookSourceSubscription.address(from: address)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationTitle("网络导入书源")
        .navigationDestination(item: $previewURL) { url in
            SourceSubscriptionPreview(request: .address(url), onImportComplete: onComplete)
        }
        .alert("无效的书源地址", isPresented: showingError($errorMessage)) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

struct SourceMarketplaceView: View {
    @Environment(\.openURL) private var openURL
    @State private var category: BookSourceMarketplaceCategory = .sources
    @State private var libraryEntries: [BookSourceMarketplaceEntry] = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: String?
    @State private var retry = 0
    @State private var loadID = UUID()
    @State private var completedRequest: MarketplaceRequest?
    @State private var nextPage: Int?
    @State private var loadingMore = false
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var pageFailure: String?

    private var keyword: String? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? nil : term
    }

    var body: some View {
        let request = MarketplaceRequest(category: category, keyword: keyword, retry: retry)
        List {
            Section {
                Picker("分类", selection: $category) {
                    ForEach(BookSourceMarketplaceCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)
            }

            if loading {
                ProgressView("正在读取源仓库")
            } else if let failure {
                ContentUnavailableView {
                    Label("暂时无法读取源仓库", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("重试") { retry += 1 }
                    Button("打开地址发布页") { openURL(BookSourceMarketplaceClient.siteURL) }
                }
            } else if libraryEntries.isEmpty {
                if let keyword { ContentUnavailableView.search(text: keyword) }
                else { ContentUnavailableView("暂无条目", systemImage: "tray") }
            } else {
                Section {
                    ForEach(libraryEntries) { entry in
                        NavigationLink {
                            SourceSubscriptionPreview(request: .marketplace(entry))
                        } label: {
                            Label(entry.title, systemImage: category == .collections ? "books.vertical" : "book")
                                .padding(.vertical, 3)
                        }
                    }
                    if let page = nextPage {
                        if loadingMore {
                            ProgressView("正在加载更多")
                        } else {
                            if let pageFailure {
                                Text(pageFailure).font(.footnote).foregroundStyle(.secondary)
                            }
                            Button(pageFailure == nil ? "加载更多" : "重试加载更多") {
                                loadMoreTask = Task { await loadMore(page, for: request) }
                            }
                        }
                    }
                } header: {
                    Text("源仓库 · \(category.title)")
                }
            }
        }
        .navigationTitle("书源广场")
        .searchable(text: $query, prompt: "搜索当前分类")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Link("在浏览器打开当前分类", destination: category.webURL)
                    Link("地址发布页", destination: BookSourceMarketplaceClient.siteURL)
                } label: {
                    Label("源仓库网站", systemImage: "safari")
                }
            }
        }
        .task(id: request) {
            if completedRequest != request {
                await load(request, debounce: request.keyword != nil)
            }
        }
        .refreshable { await load(request) }
        .onDisappear { loadMoreTask?.cancel() }
    }

    @MainActor
    private func load(_ request: MarketplaceRequest, debounce: Bool = false) async {
        guard !Task.isCancelled, isCurrent(request) else { return }
        let id = UUID()
        loadID = id
        loadMoreTask?.cancel()
        loadMoreTask = nil
        loading = true
        loadingMore = false
        libraryEntries = []
        failure = nil
        pageFailure = nil
        nextPage = nil
        do {
            if debounce { try await Task.sleep(for: .milliseconds(300)) }
            let results = try await BookSourceMarketplaceClient().entries(in: request.category, keyword: request.keyword)
            try Task.checkCancellation()
            guard isCurrent(request), loadID == id else { return }
            libraryEntries = results
            nextPage = results.isEmpty ? nil : 2
        } catch {
            guard !Task.isCancelled, isCurrent(request), loadID == id else { return }
            failure = error.localizedDescription
        }
        completedRequest = request
        loading = false
    }

    @MainActor
    private func loadMore(_ page: Int, for request: MarketplaceRequest) async {
        guard isCurrent(request), nextPage == page, !loading, !loadingMore else { return }
        let id = loadID
        loadingMore = true
        pageFailure = nil
        defer {
            if loadID == id {
                loadingMore = false
                loadMoreTask = nil
            }
        }
        do {
            let results = try await BookSourceMarketplaceClient().entries(
                in: request.category, page: page, keyword: request.keyword
            )
            try Task.checkCancellation()
            guard isCurrent(request), loadID == id else { return }
            var seen = Set(libraryEntries.map(\.detailURL.path))
            let additions = results.filter { seen.insert($0.detailURL.path).inserted }
            libraryEntries.append(contentsOf: additions)
            nextPage = additions.isEmpty ? nil : page + 1
        } catch {
            guard !Task.isCancelled, isCurrent(request), loadID == id else { return }
            pageFailure = error.localizedDescription
        }
    }

    private func isCurrent(_ request: MarketplaceRequest) -> Bool {
        request.category == category && request.keyword == keyword && request.retry == retry
    }

    private struct MarketplaceRequest: Equatable {
        let category: BookSourceMarketplaceCategory
        let keyword: String?
        let retry: Int
    }
}

private struct SourceSubscriptionEditor: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: SubscriptionDraft
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称（选填）", text: $draft.name)
                    SourceAddressField(address: $draft.address)
                }
                Section {
                    Toggle("自动检查", isOn: $draft.autoUpdate)
                    if draft.autoUpdate {
                        Stepper(
                            "检查间隔 \(draft.intervalHours) 小时",
                            value: $draft.intervalHours,
                            in: 1...720
                        )
                        Toggle("静默导入更新", isOn: $draft.silentUpdate)
                    }
                } header: {
                    Text("更新")
                } footer: {
                    if draft.autoUpdate {
                        Text("打开应用后检查到期订阅。静默更新适用于此前从该订阅导入、且未自行修改的书源。")
                    }
                }
            }
            .navigationTitle(draft.original == nil ? "添加书源订阅" : "编辑书源订阅")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert("无法保存订阅", isPresented: showingError($errorMessage)) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        do {
            let url = try BookSourceSubscription.address(from: draft.address)
            let title = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try library.saveSourceSubscription(BookSourceSubscription(
                id: draft.id,
                name: title.isEmpty ? (url.host ?? url.absoluteString) : title,
                url: url,
                autoUpdate: draft.autoUpdate,
                updateIntervalHours: draft.intervalHours,
                silentUpdate: draft.autoUpdate && draft.silentUpdate,
                lastRefreshedAt: draft.original?.url == url ? draft.original?.lastRefreshedAt : nil
            ))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SubscriptionDraft: Identifiable {
    let id: UUID
    let original: BookSourceSubscription?
    var name: String
    var address: String
    var autoUpdate: Bool
    var intervalHours: Int
    var silentUpdate: Bool

    init(subscription: BookSourceSubscription? = nil, name: String = "", url: URL? = nil) {
        id = subscription?.id ?? UUID()
        original = subscription
        self.name = subscription?.name ?? name
        address = subscription?.url.absoluteString ?? url?.absoluteString ?? ""
        autoUpdate = subscription?.autoUpdate ?? false
        intervalHours = min(720, max(1, subscription?.updateIntervalHours ?? 24))
        silentUpdate = subscription?.silentUpdate ?? false
    }
}

private struct SourceAddressField: View {
    @Binding var address: String

    var body: some View {
        HStack(spacing: 12) {
            TextField("书源 JSON 或一键导入链接", text: $address)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .accessibilityLabel("书源地址")

            PasteButton(payloadType: String.self) { values in
                if let first = values.first { address = first }
            }
            .labelStyle(.iconOnly)
        }
    }
}

private struct SourceSubscriptionPreview: View {
    enum Request {
        case subscription(BookSourceSubscription)
        case address(URL)
        case marketplace(BookSourceMarketplaceEntry)

        var title: String {
            switch self {
            case .subscription(let subscription): subscription.name
            case .address: "书源预览"
            case .marketplace(let entry): entry.title
            }
        }

        var subscriptionID: UUID? {
            guard case .subscription(let subscription) = self else { return nil }
            return subscription.id
        }

        var webPage: URL? {
            guard case .marketplace(let entry) = self else { return nil }
            return entry.detailURL
        }

        func directURL() async throws -> URL {
            switch self {
            case .subscription(let subscription): subscription.url
            case .address(let url): url
            case .marketplace(let entry):
                try await BookSourceMarketplaceClient().downloadURL(for: entry)
            }
        }
    }

    let request: Request
    let onImportComplete: (() -> Void)?

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var result: Result<Preview, Error>?
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var retry = 0
    @State private var draft: SubscriptionDraft?
    @State private var errorMessage: String?
    @State private var imported: ImportSummary?

    init(request: Request, onImportComplete: (() -> Void)? = nil) {
        self.request = request
        self.onImportComplete = onImportComplete
    }

    var body: some View {
        Group {
            switch result {
            case .none:
                ProgressView("正在获取书源")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let error):
                ContentUnavailableView {
                    Label("无法读取书源", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("重试") { retry += 1 }
                    if let webPage = request.webPage {
                        Link("在浏览器打开详情", destination: webPage)
                    }
                }
            case .success(let preview):
                previewList(preview)
            }
        }
        .navigationTitle(request.title)
        .toolbar { actions }
        .task(id: retry) { await loadPreview() }
        .sheet(item: $draft) { draft in
            SourceSubscriptionEditor(draft: draft)
        }
        .alert("无法完成操作", isPresented: showingError($errorMessage)) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("已导入书源", isPresented: Binding(
            get: { imported != nil },
            set: { if !$0 { imported = nil } }
        ), presenting: imported) { _ in
            Button("完成") {
                if let onImportComplete { onImportComplete() }
                else { dismiss() }
            }
        } message: { summary in
            Text("已导入 \(summary.count) 个书源，可在书源管理中查看。")
        }
    }

    @ToolbarContentBuilder
    private var actions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if case .success(let preview) = result {
                if request.subscriptionID == nil,
                   !library.sourceSubscriptions.contains(where: { $0.url == preview.url }) {
                    Button("添加为订阅", systemImage: "link.badge.plus") {
                        draft = SubscriptionDraft(name: request.webPage == nil ? "" : request.title, url: preview.url)
                    }
                }
                Button("导入 \(selected.count) 个") {
                    importSources(preview)
                }
                .fontWeight(.semibold)
                .disabled(selected.isEmpty)
            }
        }
    }

    private func previewList(_ preview: Preview) -> some View {
        let visible = filteredSources(preview.sources)
        let existingByID = Dictionary(library.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return List {
            Section {
                LabeledContent("已读取", value: "\(preview.sources.count) 个书源")
                LabeledContent("已选择", value: "\(selected.count) 个")
                if !visible.isEmpty {
                    Button(visible.allSatisfy { selected.contains($0.id) } ? "取消可见选择" : "全选可见书源") {
                        toggleSelection(of: visible)
                    }
                }
            } footer: {
                Text("已导入的书源默认不勾选，选择后会更新其规则。")
            }
            Section("书源") {
                ForEach(visible) { source in
                    sourceRow(source, existing: existingByID[source.id])
                }
            }
        }
        .searchable(text: $query, prompt: "按名称、分组或域名筛选")
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func sourceRow(_ source: BookSource, existing: BookSource?) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(source.id) },
            set: { isSelected in
                if isSelected { selected.insert(source.id) } else { selected.remove(source.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name).font(.headline)
                Text([source.baseURL.host, source.group].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let existing {
                    Text(sourceStatus(source, comparedWith: existing))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func sourceStatus(_ source: BookSource, comparedWith existing: BookSource) -> String {
        var candidate = source
        var current = existing
        candidate.isEnabled = true
        current.isEnabled = true
        candidate.simplifiesTitles = false
        current.simplifiesTitles = false
        return candidate == current ? "已导入" : "规则与本机不同"
    }

    private func filteredSources(_ sources: [BookSource]) -> [BookSource] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return sources }
        return sources.filter {
            $0.name.localizedCaseInsensitiveContains(term)
                || $0.group?.localizedCaseInsensitiveContains(term) == true
                || $0.id.localizedCaseInsensitiveContains(term)
        }
    }

    private func toggleSelection(of sources: [BookSource]) {
        let visibleIDs = Set(sources.map(\.id))
        if visibleIDs.isSubset(of: selected) {
            selected.subtract(visibleIDs)
        } else {
            selected.formUnion(visibleIDs)
        }
    }

    @MainActor
    private func loadPreview() async {
        result = nil
        selected = []
        do {
            let url = try await request.directURL()
            let sources = try await library.previewSourceSubscription(url)
            try Task.checkCancellation()
            let existingIDs = Set(library.sources.map(\.id))
            selected = Set(sources.lazy.map(\.id).filter { !existingIDs.contains($0) })
            result = .success(Preview(sources: sources, url: url))
            if let subscriptionID = request.subscriptionID {
                do {
                    try library.markSourceSubscriptionRefreshed(subscriptionID, expecting: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            result = .failure(error)
        }
    }

    private func importSources(_ preview: Preview) {
        do {
            let sources = preview.sources.filter { selected.contains($0.id) }
            let count = try library.importSubscribedSources(
                sources, subscriptionID: request.subscriptionID, expecting: preview.url
            )
            imported = ImportSummary(count: count)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private struct Preview {
        let sources: [BookSource]
        let url: URL
    }

    private struct ImportSummary {
        let count: Int
    }
}

private func showingError(_ message: Binding<String?>) -> Binding<Bool> {
    Binding(
        get: { message.wrappedValue != nil },
        set: { if !$0 { message.wrappedValue = nil } }
    )
}
