import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system
    case day
    case paper
    case green
    case night

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "系统"
        case .day: "亮色"
        case .paper: "米纸"
        case .green: "绿纸"
        case .night: "暗色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .day, .paper, .green: .light
        case .night: .dark
        }
    }

    func palette(for system: ColorScheme) -> ReadingPalette {
        switch self {
        case .system: system == .dark ? .night : .day
        case .day: .day
        case .paper: .paper
        case .green: .green
        case .night: .night
        }
    }
}

enum ReadingPalette {
    case day
    case paper
    case green
    case night

    var background: Color {
        switch self {
        case .day: Color(red: 0.984, green: 0.976, blue: 0.953)
        case .paper: Color(red: 0.953, green: 0.902, blue: 0.816)
        case .green: Color(red: 0.875, green: 0.925, blue: 0.855)
        case .night: Color(red: 0.09, green: 0.106, blue: 0.125)
        }
    }

    var foreground: Color {
        switch self {
        case .day: Color(red: 0.157, green: 0.153, blue: 0.141)
        case .paper: Color(red: 0.22, green: 0.169, blue: 0.129)
        case .green: Color(red: 0.14, green: 0.20, blue: 0.15)
        case .night: Color(red: 0.925, green: 0.914, blue: 0.89)
        }
    }

    var accent: Color {
        switch self {
        case .day: Color(red: 0.22, green: 0.353, blue: 0.298)
        case .paper: Color(red: 0.427, green: 0.306, blue: 0.224)
        case .green: Color(red: 0.20, green: 0.36, blue: 0.24)
        case .night: Color(red: 0.761, green: 0.855, blue: 0.788)
        }
    }

    var panel: Color {
        switch self {
        case .day, .green: Color(red: 0.958, green: 0.944, blue: 0.924)
        case .paper: Color(red: 0.929, green: 0.865, blue: 0.768)
        case .night: Color(red: 0.125, green: 0.141, blue: 0.16)
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
    var paragraphSpacing: Double = 8
    var indentParagraphs = false
}

enum ReaderColumnWidth: String, CaseIterable, Identifiable {
    case narrow
    case standard
    case wide

    var id: Self { self }
    var title: String {
        switch self {
        case .narrow: "窄"
        case .standard: "适中"
        case .wide: "宽"
        }
    }
    var maxWidth: CGFloat {
        switch self {
        case .narrow: 570
        case .standard: 740
        case .wide: 950
        }
    }
}

struct ReaderSettingsView: View {
    enum SectionKind { case appearance, layout }

    @Environment(\.dismiss) private var dismiss
    let kind: SectionKind
    @Binding var theme: ReaderTheme
    @Binding var font: ReaderFont
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var paragraphSpacing: Double
    @Binding var indentParagraphs: Bool
    @Binding var columnWidth: ReaderColumnWidth
    @Binding var automaticSpeed: Double

    var body: some View {
        NavigationStack {
            Form {
                if kind == .appearance {
                    Section("主题") {
                        Picker("主题", selection: $theme) {
                            ForEach(ReaderTheme.allCases) { theme in
                                Text(theme.title).tag(theme)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Section("正文") {
                        Picker("字体", selection: $font) {
                            ForEach(ReaderFont.allCases) { font in
                                Text(font.title).tag(font)
                            }
                        }

                        numberSlider("字号", value: $fontSize, range: 14...42)
                        Picker("正文宽度", selection: $columnWidth) {
                            ForEach(ReaderColumnWidth.allCases) { width in
                                Text(width.title).tag(width)
                            }
                        }
                    }
                } else {
                    Section("排版") {
                        numberSlider("行距", value: $lineSpacing, range: 0...20)
                        numberSlider("段距", value: $paragraphSpacing, range: 0...32)
                        Toggle("首行缩进", isOn: $indentParagraphs)
                    }
                    Section("自动滚动") {
                        numberSlider("滚动速度", value: $automaticSpeed, range: 12...110)
                    }
                }
            }
            .navigationTitle(kind == .appearance ? "阅读界面" : "阅读设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func numberSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title, value: value.wrappedValue.formatted())
            Slider(value: value, in: range, step: 1) {
                Text(title)
            }
        }
        .padding(.vertical, 6)
    }
}
