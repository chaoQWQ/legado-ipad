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
