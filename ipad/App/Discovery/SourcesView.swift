import BookSources
import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var pendingRemoval: BookSource?
    let importSources: () -> Void
    let showError: (Error) -> Void

    var body: some View {
        Group {
            if library.sources.isEmpty {
                ContentUnavailableView {
                    Label("还没有书源", systemImage: "text.badge.checkmark")
                } description: {
                    Text("在 Android 阅读的书源管理中导出 JSON，再从「文件」导入。")
                } actions: {
                    Button("导入书源 JSON", action: importSources)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        ForEach(library.sources) { source in
                            Toggle(isOn: enabled(for: source)) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(source.name).font(.headline)
                                    Text(source.baseURL.host ?? source.baseURL.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !source.canSearch {
                                        Text("此书源缺少文字搜书配置")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    pendingRemoval = source
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingRemoval = source
                                } label: {
                                    Label("删除书源", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("已导入 \(library.sources.count) 个书源")
                    } footer: {
                        Text("搜书使用已启用的书源。")
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .confirmationDialog("删除书源", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { source in
            Button("删除「\(source.name)」", role: .destructive) {
                do { try library.removeSource(source.id) } catch { showError(error) }
            }
        } message: { _ in
            Text("该书源的书籍和已缓存章节会保留在书架，加载其他章节需要重新导入书源。")
        }
    }

    private func enabled(for source: BookSource) -> Binding<Bool> {
        Binding {
            library.sources.first(where: { $0.id == source.id })?.isEnabled ?? false
        } set: { enabled in
            do { try library.setEnabled(enabled, for: source.id) } catch { showError(error) }
        }
    }
}
