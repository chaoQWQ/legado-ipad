import SwiftUI

struct ReaderRecapSheet: View {
    let throughLabel: String
    let loadExcerpts: () async throws -> [ReaderRecapExcerpt]

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var attempt = 0

    private enum Phase {
        case loading, noReadText, noHighlights, highlights([ReaderRecapHighlight]), failure(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("截至 \(throughLabel) · 仅摘录已读原文")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("上次读到哪")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(CompactPresentation())
        .task(id: attempt) { await load() }
    }

    @ViewBuilder
    private var detail: some View {
        switch phase {
        case .loading:
            ProgressView("正在从已读正文中整理回顾…")
        case .noReadText:
            ContentUnavailableView(
                "暂无可用的已读正文", systemImage: "book",
                description: Text("继续读几段后再试。清理过的章节缓存需重新下载才能用于回顾。")
            )
        case .noHighlights:
            ContentUnavailableView(
                "暂无可回顾的片段", systemImage: "text.magnifyingglass",
                description: Text("现有的已读正文里没有找到合适的摘录。")
            )
        case .highlights(let items):
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: item.chapterLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(verbatim: item.text)
                                .font(.body)
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 15)
                        .accessibilityElement(children: .combine)
                        if item.id != items.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
        case .failure(let message):
            ContentUnavailableView {
                Label("暂时无法生成回顾", systemImage: "exclamationmark.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { attempt += 1 }
            }
        }
    }

    private func load() async {
        phase = .loading
        do {
            let excerpts = try await loadExcerpts()
            try Task.checkCancellation()
            guard excerpts.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                phase = .noReadText
                return
            }
            let items = try await ReaderRecap.makeHighlights(from: excerpts)
            try Task.checkCancellation()
            phase = items.isEmpty ? .noHighlights : .highlights(items)
        } catch let error as ReaderRecap.Failure {
            guard !Task.isCancelled else { return }
            phase = .failure(error.localizedDescription)
        } catch let error as ReaderAIError {
            guard !Task.isCancelled else { return }
            phase = .failure(Self.message(for: error))
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure("无法读取已读正文或完成 AI 请求，请稍后重试。")
        }
    }

    private static func message(for error: ReaderAIError) -> String {
        switch error {
        case .missingSettings, .keychain, .invalidAddress, .invalidHeaders, .emptyResponse, .oversizedResponse:
            error.localizedDescription
        case .http(let status, _):
            ReaderAIError.http(status, nil).localizedDescription
        case .connection:
            "无法连接 AI 供应商，请检查网络和接口设置。"
        default:
            "AI 供应商未完成请求，请检查接口设置或稍后重试。"
        }
    }

    private struct CompactPresentation: ViewModifier {
        func body(content: Content) -> some View {
            #if os(iOS)
            if #available(iOS 18.0, *) {
                content.presentationSizing(.form)
            } else {
                content.presentationDetents([.medium, .large])
            }
            #else
            content.frame(minWidth: 420, minHeight: 350)
            #endif
        }
    }
}
