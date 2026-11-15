import SwiftUI

struct MyReaderSettingsSheet: View {
    enum Kind: String, Identifiable {
        case appearance, behavior
        var id: Self { self }
    }

    let kind: Kind

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("reader.theme") private var theme: ReaderTheme = .system
    @AppStorage("reader.lastLightTheme") private var lastLightTheme: ReaderTheme = .system
    @AppStorage("reader.layoutProfiles") private var layoutData = Data()
    @AppStorage("reader.behavior") private var behaviorData = Data()
    @AppStorage("reader.information") private var informationData = Data()
    @AppStorage("reader.script") private var script: ReaderScript = .off

    private var layoutTheme: ReaderTheme {
        theme == .system ? (colorScheme == .dark ? .night : .day) : theme
    }

    private var profiles: ReaderLayoutProfiles {
        (try? JSONDecoder().decode(ReaderLayoutProfiles.self, from: layoutData))
            ?? .init(shared: ReaderLayoutPreferences.legacy(from: .standard))
    }

    private var behavior: ReaderBehavior {
        if let stored = try? JSONDecoder().decode(ReaderBehavior.self, from: behaviorData) { return stored }
        var defaults = ReaderBehavior()
        defaults.automaticSpeed = UserDefaults.standard.object(forKey: "reader.automaticSpeed") as? Double ?? defaults.automaticSpeed
        return defaults
    }

    private var layoutBinding: Binding<ReaderLayoutPreferences> {
        Binding(get: { profiles[layoutTheme] }, set: { updated in
            var current = profiles
            current[layoutTheme] = updated
            saveReaderPreference(current, into: &layoutData)
        })
    }

    private var sharedLayoutBinding: Binding<Bool> {
        Binding(get: { profiles.isShared }, set: { updated in
            var current = profiles
            current.isShared = updated
            saveReaderPreference(current, into: &layoutData)
        })
    }

    private var informationBinding: Binding<ReaderInformationPreferences> {
        Binding(get: {
            (try? JSONDecoder().decode(ReaderInformationPreferences.self, from: informationData)) ?? .init()
        }, set: { saveReaderPreference($0, into: &informationData) })
    }

    var body: some View {
        let palette = theme.palette(for: colorScheme)
        Group {
            switch kind {
            case .appearance:
                ReaderAppearanceConfigurationView(
                    palette: palette, layout: layoutBinding, theme: $theme, sharesLayout: sharedLayoutBinding,
                    script: $script, information: informationBinding
                )
            case .behavior:
                ReaderBehaviorConfigurationView(
                    palette: palette,
                    behavior: Binding(get: { behavior }, set: { saveReaderPreference($0, into: &behaviorData) })
                )
            }
        }
        .environment(\.colorScheme, theme.colorScheme ?? colorScheme)
        #if os(iOS)
        .presentationDetents([.large])
        #endif
        .onChange(of: theme) { _, updated in
            if updated != .night { lastLightTheme = updated }
        }
    }
}

struct MyReadingRecordsView: View {
    @EnvironmentObject private var library: LibraryStore
    let open: (LibraryBook) -> Void

    var body: some View {
        let started = library.books.filter { library.hasPosition(for: $0.id) }
        Group {
            if started.isEmpty {
                ContentUnavailableView(
                    "暂无阅读记录", systemImage: "clock",
                    description: Text("从书架打开书籍后，阅读进度会显示在这里。")
                )
            } else {
                List(started) { book in
                    let position = library.position(for: book.id)
                    Button { open(book) } label: {
                        bookProgress(book, index: position.chapterIndex)
                    }
                    .buttonStyle(.plain)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("阅读记录")
    }

    private func bookProgress(_ book: LibraryBook, index: Int) -> some View {
        let title = library.displayTitle(book.title, sourceID: book.sourceID)
        let chapter = book.chapters.indices.contains(index) ? book.chapters[index].title : ""
        return HStack(spacing: 12) {
            BookCover(title: title, author: book.author, url: book.coverURL)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if !chapter.isEmpty {
                    Text(library.displayTitle(chapter, sourceID: book.sourceID))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("第 \(max(1, min(index + 1, book.chapters.count))) / \(book.chapters.count) 章")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct MyBookmarksView: View {
    @EnvironmentObject private var library: LibraryStore
    let open: (LibraryBook, ReaderPosition) -> Void

    private var booksWithBookmarks: [BookBookmarks] {
        library.books.compactMap { book in
            let data = UserDefaults.standard.data(forKey: book.readerBookmarkKey) ?? Data()
            let matches = ReaderBookmarks.decode(data).filter { book.chapters.indices.contains($0.position.chapterIndex) }
            return matches.isEmpty ? nil : BookBookmarks(book: book, bookmarks: matches)
        }
    }

    var body: some View {
        let entries = booksWithBookmarks
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "暂无书签", systemImage: "bookmark",
                    description: Text("可以在阅读页将当前位置添加为书签。")
                )
            } else {
                List {
                    ForEach(entries) { entry in
                        Section(library.displayTitle(entry.book.title, sourceID: entry.book.sourceID)) {
                            ForEach(entry.bookmarks) { bookmark in
                                Button { open(entry.book, bookmark.position) } label: {
                                    bookmarkLabel(bookmark, in: entry.book)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("书签")
    }

    private func bookmarkLabel(_ bookmark: ReaderBookmark, in book: LibraryBook) -> some View {
        let raw = book.chapters[bookmark.position.chapterIndex].title
        let title = library.displayTitle(raw, sourceID: book.sourceID)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if !bookmark.excerpt.isEmpty {
                Text(bookmark.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("本章 \(bookmark.fraction, format: .percent.precision(.fractionLength(0)))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private struct BookBookmarks: Identifiable {
        let book: LibraryBook
        let bookmarks: [ReaderBookmark]
        var id: UUID { book.id }
    }
}

struct MyReplacementBooksView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var selected: LibraryBook?

    var body: some View {
        Group {
            if library.books.isEmpty {
                ContentUnavailableView(
                    "书架中暂无书籍", systemImage: "books.vertical",
                    description: Text("加入书架后，可以为每本书设置替换规则。")
                )
            } else {
                List(library.books) { book in
                    Button {
                        selected = book
                    } label: {
                        HStack {
                            Text(library.displayTitle(book.title, sourceID: book.sourceID))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("替换净化")
        .sheet(item: $selected) { book in
            MyBookReplacementSheet(bookID: book.id)
        }
    }
}

private struct MyBookReplacementSheet: View {
    @AppStorage private var ruleData: Data

    init(bookID: UUID) {
        _ruleData = AppStorage(wrappedValue: Data(), ReaderReplacementRule.storageKey(bookID: bookID))
    }

    var body: some View {
        ReaderReplaceSheet(rules: Binding(
            get: { ReaderReplacementRule.decode(ruleData) },
            set: { if let payload = ReaderReplacementRule.encode($0) { ruleData = payload } }
        ))
    }
}
