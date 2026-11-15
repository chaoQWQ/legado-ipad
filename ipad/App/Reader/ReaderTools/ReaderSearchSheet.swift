import SwiftUI

struct ReaderSearchMatch: Identifiable {
    struct ID: Hashable {
        let chapterIndex: Int
        let utf16Offset: Int
    }

    let chapterIndex: Int
    let utf16Offset: Int
    let utf16Length: Int
    let before: String
    let highlighted: String
    let after: String

    var id: ID { ID(chapterIndex: chapterIndex, utf16Offset: utf16Offset) }

    static func matches(
        in text: String, chapterIndex: Int, query: String, limit: Int,
        originalOffset: (Int) -> Int = { $0 }
    ) -> [Self] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let body = text as NSString
        var cursor = 0
        var results: [Self] = []
        while cursor < body.length, results.count < limit {
            let range = body.range(
                of: query, options: [.caseInsensitive],
                range: NSRange(location: cursor, length: body.length - cursor)
            )
            guard range.location != NSNotFound, range.length > 0 else { break }
            let end = NSMaxRange(range)
            let startOfContext = max(0, range.location - 32)
            let endOfContext = min(body.length, end + 45)
            let context = body.rangeOfComposedCharacterSequences(for: NSRange(
                location: startOfContext, length: endOfContext - startOfContext
            ))

            let before = body.substring(with: NSRange(
                location: context.location, length: range.location - context.location
            ))
            let after = body.substring(with: NSRange(
                location: end, length: NSMaxRange(context) - end
            ))
            let start = originalOffset(range.location)
            let length = max(1, originalOffset(end) - start)
            results.append(Self(
                chapterIndex: chapterIndex, utf16Offset: start, utf16Length: length,
                before: (context.location > 0 ? "…" : "") + singleLine(before),
                highlighted: singleLine(body.substring(with: range)),
                after: singleLine(after) + (NSMaxRange(context) < body.length ? "…" : "")
            ))
            cursor = end
        }
        return results
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

struct ReaderSearchSheet: View {
    let chapters: [ReaderChapter]
    let loadChapter: (Int) async throws -> String?
    let jumpTo: (ReaderSearchMatch) -> Void
    var script: ReaderScript = .off
    var queryScript: ReaderScript = .off
    var titleScript: ReaderScript = .off

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ReaderSearchMatch] = []
    @State private var progress = 0
    @State private var unavailable = 0
    @State private var isScanning = false
    @State private var hasMoreResults = false
    @FocusState private var isSearchFocused: Bool

    private let resultLimit = 200

    var body: some View {
        NavigationStack {
            List {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("搜索正文", text: $query)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Label("清空搜索", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if isScanning {
                    ProgressView(value: Double(progress), total: Double(max(1, chapters.count))) {
                        Text("正在搜索章节")
                    }
                }
                if results.isEmpty, !isScanning {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("搜索本书中已下载的正文。")
                            .foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                if !results.isEmpty {
                    Section {
                        ForEach(results) { match in
                            Button {
                                jumpTo(match)
                                dismiss()
                            } label: {
                                matchRow(match)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(hasMoreResults ? "前 \(resultLimit) 条结果" : "\(results.count) 条结果")
                    }
                }
                if unavailable > 0, !isScanning {
                    Text("\(unavailable) 章暂无可搜索的已下载正文")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("搜索本书")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .defaultFocus($isSearchFocused, true)
        }
        .task(id: query) {
            await search(query)
        }
    }

    private func matchRow(_ match: ReaderSearchMatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleScript.convert(chapters[match.chapterIndex].title))
                .font(.subheadline.weight(.semibold))
            (Text(match.before) + Text(match.highlighted).bold().foregroundColor(.accentColor) + Text(match.after))
                .font(.footnote)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @MainActor
    private func search(_ input: String) async {
        guard !Task.isCancelled else { return }
        let term = queryScript.convert(input.trimmingCharacters(in: .whitespacesAndNewlines))
        results = []
        progress = 0
        unavailable = 0
        hasMoreResults = false
        isScanning = !term.isEmpty
        guard isScanning else { return }
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }

        for index in chapters.indices {
            let chapter = try? await loadChapter(index)
            guard !Task.isCancelled, input == query else { return }
            if let chapter {
                let remaining = resultLimit - results.count
                let conversion = ReaderTextTransform(original: chapter, rules: [], script: script)
                let matches = ReaderSearchMatch.matches(
                    in: conversion.text, chapterIndex: index, query: term, limit: remaining + 1,
                    originalOffset: conversion.originalOffset(forDisplay:)
                )
                results.append(contentsOf: matches.prefix(remaining))
                hasMoreResults = matches.count > remaining
            } else {
                unavailable += 1
            }
            progress = index + 1
            if hasMoreResults { break }
        }
        isScanning = false
    }
}
