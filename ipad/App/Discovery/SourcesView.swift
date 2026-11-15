import BookSources
import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var pendingRemoval: BookSource?
    @State private var filter = ""
    let importSources: () -> Void
    let importFromAddress: () -> Void
    let createSource: () -> Void
    let editSource: (BookSource) -> Void
    let showError: (Error) -> Void

    private var displayedSources: [BookSource] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.sources }
        return library.sources.filter {
            $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query)
                || $0.group?.localizedStandardContains(query) == true
        }
    }

    var body: some View {
        Group {
            if library.sources.isEmpty {
                ContentUnavailableView {
                    Label("还没有书源", systemImage: "text.badge.checkmark")
                } description: {
                    Text("可导入阅读书源 JSON 文件，也可使用书源网址或一键导入链接。")
                } actions: {
                    Button("导入书源 JSON", action: importSources)
                        .buttonStyle(.borderedProminent)
                    Button("从网址导入", action: importFromAddress)
                    Button("新建书源", action: createSource)
                }
            } else if displayedSources.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                List {
                    Section {
                        ForEach(displayedSources) { source in
                            HStack(spacing: 16) {
                                Button {
                                    editSource(source)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(source.name).font(.headline)
                                            Text(source.baseURL.host ?? source.baseURL.absoluteString)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if let group = source.group {
                                                Text(group).font(.caption).foregroundStyle(.secondary)
                                            }
                                            if !source.canSearch {
                                                Text("此书源缺少文字搜书配置")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "pencil")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("编辑书源")
                                Toggle("启用\(source.name)", isOn: enabled(for: source))
                                    .labelsHidden()
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    pendingRemoval = source
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button("编辑书源", systemImage: "pencil") { editSource(source) }
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
        .searchable(text: $filter, prompt: "查找书源名、分组或地址")
        .alert("删除书源？", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { source in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                do { try library.removeSource(source.id) } catch { showError(error) }
            }
        } message: { source in
            Text("删除「\(source.name)」后，加载该书源的其他章节需重新导入书源。")
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
