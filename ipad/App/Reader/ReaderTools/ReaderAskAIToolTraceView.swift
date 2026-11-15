import SwiftUI

struct ReaderAskAIToolTraceView: View {
    let trace: ReaderAskAIToolTrace

    var body: some View {
        if let latest = trace.steps.last {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    if trace.count > trace.steps.count {
                        Text("显示最近 \(trace.steps.count) 步")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(trace.steps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            status(for: step.status)
                                .frame(width: 18, height: 18)
                            details(for: step)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 12)
            } label: {
                HStack(spacing: 10) {
                    Text("\(trace.count) 步")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                    details(for: latest, argumentLines: 1)
                }
                .accessibilityLabel("工具调用，\(trace.count) 步，\(latest.name)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private func details(for step: ReaderAskAIToolTrace.Step, argumentLines: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: step.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let arguments = step.argumentsPreview {
                Text(verbatim: arguments)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(argumentLines)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func status(for status: ReaderAskAIToolTrace.Step.Status) -> some View {
        switch status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("调用中")
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("已完成")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
                .accessibilityLabel("调用失败")
        case .interrupted:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("已中断")
        }
    }
}
