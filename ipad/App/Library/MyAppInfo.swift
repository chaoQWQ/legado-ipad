import SwiftUI

struct MyAboutView: View {
    private static let projectURL = URL(string: "https://github.com/chaoQWQ/legado-ipad")!
    private static let usageURL = projectURL.appending(path: "blob/ipad-native/ipad/README.md")
    private static let licenseURL = projectURL.appending(path: "blob/ipad-native/LICENSE")

    var body: some View {
        List {
            Section {
                VStack(spacing: 11) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 31, weight: .medium))
                        .foregroundStyle(ReaderPalette.accent)
                        .frame(width: 65, height: 65)
                        .background(ReaderPalette.accent.opacity(0.12), in: .rect(cornerRadius: 17))
                        .accessibilityHidden(true)
                    Text("阅读 Archive").font(.system(.title2, design: .serif, weight: .semibold))
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                            Text("版本 \(version)（\(build)）").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("版本 \(version)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            Section("项目") {
                Link(destination: Self.usageURL) { Label("使用指南", systemImage: "questionmark.circle") }
                Link(destination: Self.projectURL) { Label("源代码", systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: Self.licenseURL) { Label("GPL-3.0 许可证", systemImage: "doc.text") }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("关于阅读")
    }
}

struct MyStorageView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var usage: MyStorageUsage?
    @State private var attempts = 0

    var body: some View {
        List {
            Section {
                if let usage {
                    LabeledContent("本地书籍", value: Self.byteCount(usage.localBytes))
                    LabeledContent("在线章节", value: Self.byteCount(usage.onlineBytes))
                } else {
                    ProgressView("正在统计正文文件…")
                }
            } header: {
                Text("正文文件")
            } footer: {
                Text("统计当前书架中导入的正文和已缓存的在线章节。")
            }
            Section("书架与书源") {
                LabeledContent("书籍", value: library.books.count.formatted())
                LabeledContent("书源", value: library.sources.count.formatted())
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("存储用量")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("重新统计", systemImage: "arrow.clockwise") { attempts += 1 }
            }
        }
        .task(id: attempts) { await measure() }
    }

    private func measure() async {
        usage = nil
        let books = library.books.map { MyStorageUsage.BookFolder(id: $0.id, isOnline: $0.sourceID != nil) }
        let result = await MyStorageScanner().measure(books, in: library.bookStorageDirectory)
        if !Task.isCancelled { usage = result }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct MyStorageUsage: Sendable {
    struct BookFolder: Sendable {
        let id: UUID
        let isOnline: Bool
    }

    var localBytes: Int64 = 0
    var onlineBytes: Int64 = 0
}

private actor MyStorageScanner {
    func measure(_ books: [MyStorageUsage.BookFolder], in root: URL) -> MyStorageUsage {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        var total = MyStorageUsage()
        for book in books {
            if Task.isCancelled { break }
            let directory = root.appending(path: book.id.uuidString, directoryHint: .isDirectory)
            guard let files = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files {
                if Task.isCancelled { break }
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      values.isSymbolicLink != true, let size = values.fileSize else { continue }
                if book.isOnline { total.onlineBytes += Int64(size) }
                else { total.localBytes += Int64(size) }
            }
        }
        return total
    }
}
