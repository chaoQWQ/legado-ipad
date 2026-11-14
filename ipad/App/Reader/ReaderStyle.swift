import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system
    case day
    case paper
    case night

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "系统"
        case .day: "亮色"
        case .paper: "纸色"
        case .night: "暗色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .day, .paper: .light
        case .night: .dark
        }
    }

    func palette(for system: ColorScheme) -> ReadingPalette {
        switch self {
        case .system: system == .dark ? .night : .day
        case .day: .day
        case .paper: .paper
        case .night: .night
        }
    }
}

enum ReadingPalette {
    case day
    case paper
    case night

    var background: Color {
        switch self {
        case .day: Color(red: 0.984, green: 0.976, blue: 0.953)
        case .paper: Color(red: 0.953, green: 0.902, blue: 0.816)
        case .night: Color(red: 0.09, green: 0.106, blue: 0.125)
        }
    }

    var foreground: Color {
        switch self {
        case .day: Color(red: 0.157, green: 0.153, blue: 0.141)
        case .paper: Color(red: 0.22, green: 0.169, blue: 0.129)
        case .night: Color(red: 0.925, green: 0.914, blue: 0.89)
        }
    }

    var accent: Color {
        switch self {
        case .day: Color(red: 0.22, green: 0.353, blue: 0.298)
        case .paper: Color(red: 0.427, green: 0.306, blue: 0.224)
        case .night: Color(red: 0.761, green: 0.855, blue: 0.788)
        }
    }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case serif
    case sansSerif

    var id: Self { self }

    var title: String {
        switch self {
        case .serif: "宋体"
        case .sansSerif: "无衬线"
        }
    }
}

struct ReaderTypography: Equatable {
    let fontSize: Double
    let lineSpacing: Double
    let font: ReaderFont
    let palette: ReadingPalette
}

struct ReaderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var theme: ReaderTheme
    @Binding var font: ReaderFont
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double

    var body: some View {
        NavigationStack {
            Form {
                Section("主题") {
                    Picker("主题", selection: $theme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("排版") {
                    Picker("字体", selection: $font) {
                        ForEach(ReaderFont.allCases) { font in
                            Text(font.title).tag(font)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("字号", value: fontSize.formatted())
                        Slider(value: $fontSize, in: 14...42, step: 1) {
                            Text("字号")
                        }
                    }
                    .padding(.vertical, 6)

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("行距", value: lineSpacing.formatted())
                        Slider(value: $lineSpacing, in: 0...20, step: 1) {
                            Text("行距")
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("阅读设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
