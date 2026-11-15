import ImageIO
import SwiftUI

struct ReaderImageGalleryView: View {
    @ObservedObject private var gallery = ReaderImageGalleryStore.shared
    @State private var filter = Filter.all
    @State private var query = ""

    var body: some View {
        Group {
            if let error = gallery.loadError, gallery.entries.isEmpty {
                ContentUnavailableView {
                    Label("无法读取图库", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await gallery.load() } }
                }
            } else if images.isEmpty {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        filter == .all ? "暂无生成图片" : "暂无收藏图片",
                        systemImage: filter == .all ? "photo.on.rectangle" : "heart"
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 14)], spacing: 14) {
                        ForEach(images) { entry in
                            NavigationLink {
                                ReaderImageGalleryDetailView(imageID: entry.id)
                            } label: {
                                tile(entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("AI 图库")
        .searchable(text: $query, prompt: "搜索提示词、书名或模型")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("图片筛选", selection: $filter) {
                    ForEach(Filter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .task { await gallery.load() }
    }

    private var images: [ReaderImageGalleryEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return gallery.entries.filter { entry in
            if filter == .favorite && !entry.isFavorite { return false }
            return term.isEmpty || [
                entry.prompt, entry.model, entry.context.bookTitle, entry.context.chapterTitle
            ].contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    private func tile(_ entry: ReaderImageGalleryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ReaderGalleryPicture(url: gallery.fileURL(for: entry), maxDimension: 420)
                .frame(height: 144)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if entry.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.55), in: .circle)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
            Text(entry.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if !entry.context.bookTitle.isEmpty {
                Text(entry.context.bookTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(entry.isFavorite ? .isSelected : [])
    }

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", favorite = "收藏"
        var id: Self { self }
    }
}

struct ReaderImageGalleryDetailView: View {
    let imageID: UUID

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gallery = ReaderImageGalleryStore.shared
    @State private var confirmsRemoval = false
    @State private var errorMessage: String?

    private var entry: ReaderImageGalleryEntry? { gallery.entries.first { $0.id == imageID } }

    var body: some View {
        Group {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ReaderGalleryPicture(url: gallery.fileURL(for: entry), maxDimension: 1800)
                            .frame(maxWidth: .infinity)
                        if !entry.context.bookTitle.isEmpty {
                            LabeledContent("来源") {
                                Text([entry.context.bookTitle, entry.context.chapterTitle]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                            }
                        }
                        LabeledContent("服务", value: entry.provider)
                        LabeledContent("模型", value: entry.model)
                        LabeledContent("生成时间", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Divider()
                        Text("提示词").font(.headline)
                        Text(entry.prompt).textSelection(.enabled)
                    }
                    .frame(maxWidth: 720)
                    .padding(18)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("图片已移除", systemImage: "photo")
            }
        }
        .navigationTitle("阅读插图")
        .toolbar {
            if let entry {
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: gallery.fileURL(for: entry)) {
                        Label("分享或保存", systemImage: "square.and.arrow.up")
                    }
                    Menu {
                        Button(entry.isFavorite ? "取消收藏" : "收藏", systemImage: entry.isFavorite ? "heart.slash" : "heart") {
                            run { try await gallery.setFavorite(!entry.isFavorite, for: entry.id) }
                        }
                        if entry.isInserted {
                            Button("从正文移除", systemImage: "text.badge.minus") {
                                run { try await gallery.setInserted(false, for: entry.id) }
                            }
                        }
                        Button("删除图片", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("删除这张图片？", isPresented: $confirmsRemoval) {
            Button("取消", role: .cancel) {}
            Button("删除图片", role: .destructive) {
                run {
                    try await gallery.delete(imageID)
                    dismiss()
                }
            }
        } message: {
            if entry?.isInserted == true { Text("对应的正文插图也会移除。") }
        }
        .alert("图库", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct ReaderGalleryPicture: View {
    let url: URL
    let maxDimension: Int
    @State private var rendered: CGImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let rendered {
                Image(rendered, scale: 1, label: Text("生成的图片"))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if didLoad {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("无法预览图片")
            } else {
                ProgressView().accessibilityLabel("正在读取图片")
            }
        }
        .task(id: url) {
            didLoad = false
            rendered = nil
            let dimension = maxDimension
            let result = await Task.detached(priority: .utility) { Self.thumbnail(at: url, maxDimension: dimension) }.value
            if !Task.isCancelled {
                rendered = result
                didLoad = true
            }
        }
    }

    static nonisolated func thumbnail(at url: URL, maxDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceShouldCacheImmediately as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: maxDimension
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
